// Wireline phone relay: forwards end-to-end encrypted frames between one Mac
// and its paired phones per room. Stores nothing. Standard library only.
package main

import (
	"bufio"
	"crypto/sha1"
	"crypto/subtle"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"regexp"
	"strconv"
	"sync"
	"time"
)

const (
	maxFrame        = 1 << 20
	framesPerSecond = 200
	bytesPerSecond  = 1 << 20
	pingInterval    = 25 * time.Second
	readTimeout     = 70 * time.Second
)

var (
	maxPhones = envInt("RELAY_MAX_PHONES", 4)
	maxRooms  = envInt("RELAY_MAX_ROOMS", 1000)
	token     = os.Getenv("RELAY_TOKEN")
	roomRe    = regexp.MustCompile(`^[A-Za-z0-9_-]{16,64}$`)
)

func envInt(key string, def int) int {
	if v, err := strconv.Atoi(os.Getenv(key)); err == nil && v > 0 {
		return v
	}
	return def
}

// ---- WebSocket (RFC 6455, server side, text frames) ----

type wsConn struct {
	c      net.Conn
	r      *bufio.Reader
	wmu    sync.Mutex
	tokens float64
	bytes  float64
	last   time.Time
}

func upgrade(w http.ResponseWriter, r *http.Request) (*wsConn, error) {
	if r.Header.Get("Upgrade") == "" || r.Header.Get("Sec-WebSocket-Version") != "13" {
		return nil, errors.New("not a websocket request")
	}
	key := r.Header.Get("Sec-WebSocket-Key")
	if key == "" {
		return nil, errors.New("missing key")
	}
	hj, ok := w.(http.Hijacker)
	if !ok {
		return nil, errors.New("no hijack")
	}
	c, rw, err := hj.Hijack()
	if err != nil {
		return nil, err
	}
	h := sha1.Sum([]byte(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
	fmt.Fprintf(rw, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n",
		base64.StdEncoding.EncodeToString(h[:]))
	if err := rw.Flush(); err != nil {
		c.Close()
		return nil, err
	}
	return &wsConn{c: c, r: rw.Reader, tokens: framesPerSecond, bytes: bytesPerSecond, last: time.Now()}, nil
}

// read returns the next text/binary message; answers pings, ends on close.
func (ws *wsConn) read() ([]byte, error) {
	var msg []byte
	for {
		ws.c.SetReadDeadline(time.Now().Add(readTimeout))
		var hdr [2]byte
		if _, err := io.ReadFull(ws.r, hdr[:]); err != nil {
			return nil, err
		}
		fin, op := hdr[0]&0x80 != 0, hdr[0]&0x0f
		masked := hdr[1]&0x80 != 0
		n := uint64(hdr[1] & 0x7f)
		switch n {
		case 126:
			var b [2]byte
			if _, err := io.ReadFull(ws.r, b[:]); err != nil {
				return nil, err
			}
			n = uint64(binary.BigEndian.Uint16(b[:]))
		case 127:
			var b [8]byte
			if _, err := io.ReadFull(ws.r, b[:]); err != nil {
				return nil, err
			}
			n = binary.BigEndian.Uint64(b[:])
		}
		if !masked {
			return nil, errors.New("unmasked client frame")
		}
		if n > maxFrame || uint64(len(msg))+n > maxFrame {
			return nil, errors.New("frame too large")
		}
		var mask [4]byte
		if _, err := io.ReadFull(ws.r, mask[:]); err != nil {
			return nil, err
		}
		payload := make([]byte, n)
		if _, err := io.ReadFull(ws.r, payload); err != nil {
			return nil, err
		}
		for i := range payload {
			payload[i] ^= mask[i%4]
		}
		switch op {
		case 0x8:
			ws.writeFrame(0x8, nil)
			return nil, io.EOF
		case 0x9:
			ws.writeFrame(0xA, payload)
			continue
		case 0xA:
			continue
		case 0x0, 0x1, 0x2:
			msg = append(msg, payload...)
			if !fin {
				continue
			}
			if !ws.allow(len(msg)) {
				return nil, errors.New("rate limited")
			}
			return msg, nil
		default:
			return nil, errors.New("bad opcode")
		}
	}
}

func (ws *wsConn) allow(n int) bool {
	now := time.Now()
	dt := now.Sub(ws.last).Seconds()
	ws.last = now
	ws.tokens = min(framesPerSecond, ws.tokens+dt*framesPerSecond) - 1
	ws.bytes = min(bytesPerSecond, ws.bytes+dt*bytesPerSecond) - float64(n)
	return ws.tokens >= 0 && ws.bytes >= 0
}

func (ws *wsConn) writeFrame(op byte, p []byte) error {
	ws.wmu.Lock()
	defer ws.wmu.Unlock()
	hdr := []byte{0x80 | op}
	switch n := len(p); {
	case n < 126:
		hdr = append(hdr, byte(n))
	case n < 1<<16:
		hdr = append(hdr, 126, byte(n>>8), byte(n))
	default:
		hdr = append(hdr, 127)
		hdr = binary.BigEndian.AppendUint64(hdr, uint64(n))
	}
	ws.c.SetWriteDeadline(time.Now().Add(10 * time.Second))
	if _, err := ws.c.Write(append(hdr, p...)); err != nil {
		ws.c.Close()
		return err
	}
	return nil
}

func (ws *wsConn) send(v any) error {
	b, _ := json.Marshal(v)
	return ws.writeFrame(0x1, b)
}

// ---- Rooms ----

type room struct {
	mac    *wsConn
	phones map[string]*wsConn
}

type hub struct {
	mu    sync.Mutex
	rooms map[string]*room
	seq   int
}

func (h *hub) get(id string) *room {
	r := h.rooms[id]
	if r == nil {
		if len(h.rooms) >= maxRooms {
			return nil
		}
		r = &room{phones: map[string]*wsConn{}}
		h.rooms[id] = r
	}
	return r
}

func (h *hub) drop(id string) {
	if r := h.rooms[id]; r != nil && r.mac == nil && len(r.phones) == 0 {
		delete(h.rooms, id)
	}
}

type envelope struct {
	T    string `json:"t,omitempty"`
	Peer string `json:"peer,omitempty"`
	To   string `json:"to,omitempty"`
	From string `json:"from,omitempty"`
	D    string `json:"d,omitempty"`
	Up   *bool  `json:"up,omitempty"`
}

func boolp(b bool) *bool { return &b }

func (h *hub) serveWS(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	id, role := q.Get("room"), q.Get("role")
	if !roomRe.MatchString(id) || (role != "mac" && role != "phone") {
		http.Error(w, "bad room or role", http.StatusBadRequest)
		return
	}
	if token != "" && subtle.ConstantTimeCompare([]byte(q.Get("token")), []byte(token)) != 1 {
		http.Error(w, "bad token", http.StatusForbidden)
		return
	}
	ws, err := upgrade(w, r)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	defer ws.c.Close()
	go func() {
		for range time.Tick(pingInterval) {
			if ws.writeFrame(0x9, nil) != nil {
				return
			}
		}
	}()
	if role == "mac" {
		h.serveMac(id, ws)
	} else {
		h.servePhone(id, ws)
	}
}

func (h *hub) serveMac(id string, ws *wsConn) {
	h.mu.Lock()
	rm := h.get(id)
	if rm == nil {
		h.mu.Unlock()
		ws.writeFrame(0x8, nil)
		return
	}
	if old := rm.mac; old != nil {
		old.c.Close()
	}
	rm.mac = ws
	for p, c := range rm.phones {
		ws.send(envelope{T: "join", Peer: p})
		c.send(envelope{T: "mac", Up: boolp(true)})
	}
	h.mu.Unlock()
	log.Printf("mac up room=%s…", id[:6])
	defer func() {
		h.mu.Lock()
		if rm.mac == ws {
			rm.mac = nil
			for _, c := range rm.phones {
				c.send(envelope{T: "mac", Up: boolp(false)})
			}
		}
		h.drop(id)
		h.mu.Unlock()
		log.Printf("mac down room=%s…", id[:6])
	}()
	for {
		b, err := ws.read()
		if err != nil {
			return
		}
		var e envelope
		if json.Unmarshal(b, &e) != nil {
			continue
		}
		h.mu.Lock()
		target := rm.phones[e.To]
		if e.T == "kick" {
			if c := rm.phones[e.Peer]; c != nil {
				c.c.Close()
			}
		}
		h.mu.Unlock()
		if e.T == "" && target != nil {
			target.send(envelope{D: e.D})
		}
	}
}

func (h *hub) servePhone(id string, ws *wsConn) {
	h.mu.Lock()
	rm := h.get(id)
	if rm == nil || len(rm.phones) >= maxPhones {
		h.mu.Unlock()
		ws.send(envelope{T: "full"})
		ws.writeFrame(0x8, nil)
		return
	}
	h.seq++
	peer := "p" + strconv.Itoa(h.seq)
	rm.phones[peer] = ws
	ws.send(envelope{T: "mac", Up: boolp(rm.mac != nil)})
	if rm.mac != nil {
		rm.mac.send(envelope{T: "join", Peer: peer})
	}
	h.mu.Unlock()
	defer func() {
		h.mu.Lock()
		delete(rm.phones, peer)
		if rm.mac != nil {
			rm.mac.send(envelope{T: "leave", Peer: peer})
		}
		h.drop(id)
		h.mu.Unlock()
	}()
	for {
		b, err := ws.read()
		if err != nil {
			return
		}
		var e envelope
		if json.Unmarshal(b, &e) != nil || e.D == "" {
			continue
		}
		h.mu.Lock()
		mac := rm.mac
		h.mu.Unlock()
		if mac != nil {
			mac.send(envelope{From: peer, D: e.D})
		}
	}
}

func main() {
	addr := flag.String("addr", envOr("RELAY_ADDR", ":8080"), "listen address")
	web := flag.String("web", envOr("RELAY_WEB", "web"), "directory with the phone web client")
	insecure := flag.Bool("insecure-no-token", false, "allow running without RELAY_TOKEN (local testing only)")
	flag.Parse()
	if token == "" && !*insecure {
		log.Fatal("RELAY_TOKEN is required (Macs and phones must present it); -insecure-no-token for local tests")
	}
	h := &hub{rooms: map[string]*room{}}
	mux := http.NewServeMux()
	mux.HandleFunc("/ws", h.serveWS)
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) { io.WriteString(w, "ok\n") })
	files := http.FileServer(http.Dir(*web))
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Security-Policy",
			"default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; base-uri 'none'; frame-ancestors 'none'")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("Cache-Control", "no-store")
		files.ServeHTTP(w, r)
	})
	log.Printf("wireline relay on %s (web: %s)", *addr, *web)
	srv := &http.Server{Addr: *addr, Handler: mux, ReadHeaderTimeout: 10 * time.Second}
	log.Fatal(srv.ListenAndServe())
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
