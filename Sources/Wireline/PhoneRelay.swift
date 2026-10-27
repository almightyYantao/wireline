import SwiftUI
import AppKit
import CryptoKit
import CoreImage.CIFilterBuiltins
import WirelineCore

/// A phone that completed pairing.
struct PairedPhone: Codable, Identifiable, Equatable {
    var publicKey: String
    var name: String
    var pairedAt: Date
    var lastSeen: Date?
    var id: String { publicKey }
}

/// Phone relay (docs/design/phone-relay.md): an outbound WebSocket to a
/// self-hosted relay; phones reach this Mac's sessions through it, end-to-end
/// encrypted. Off by default.
@Observable
@MainActor
final class PhoneRelay {
    static let shared = PhoneRelay()

    enum Status: Equatable { case off, connecting, online, failed(String) }

    var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "relay.enabled")
            if enabled != oldValue { restart() }
        }
    }
    var relayURL: String {
        didSet { UserDefaults.standard.set(relayURL, forKey: "relay.url") }
    }
    var token: String {
        didSet { try? keychain.setPassword(token, for: "token") }
    }
    private(set) var status: Status = .off
    private(set) var devices: [PairedPhone] = [] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(devices), forKey: "relay.devices") }
    }
    /// The open pairing window, while the QR code is showing.
    private(set) var pairing: PairingCode?
    var onlineCount: Int { peers.values.filter { $0.authed }.count }

    @ObservationIgnored private let keychain = KeychainService(service: "com.wireline.relay")
    @ObservationIgnored private weak var sessions: SessionStore?
    @ObservationIgnored private var task: URLSessionWebSocketTask?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var backoff: TimeInterval = 1
    @ObservationIgnored private var peers: [String: Peer] = [:]
    @ObservationIgnored private var history: [UUID: Data] = [:]
    @ObservationIgnored private var pending: [UUID: Data] = [:]
    @ObservationIgnored private var flushScheduled = false
    @ObservationIgnored private var lastList: [RelaySessionInfo] = []
    @ObservationIgnored private var listTimer: Timer?

    private static let historyLimit = 256 * 1024
    private static let handshakeTimeout: TimeInterval = 10

    private struct Peer {
        var phonePublicKey: Data?
        var channel: RelayChannel?
        var authed = false
        var watching: UUID?
        var limiter = RelayRateLimiter(rate: 30)
    }

    private init() {
        enabled = UserDefaults.standard.bool(forKey: "relay.enabled")
        relayURL = UserDefaults.standard.string(forKey: "relay.url") ?? ""
        token = (try? KeychainService(service: "com.wireline.relay").password(for: "token")) ?? ""
        if let d = UserDefaults.standard.data(forKey: "relay.devices"),
           let list = try? JSONDecoder().decode([PairedPhone].self, from: d) { devices = list }
    }

    // MARK: Keys

    @ObservationIgnored private lazy var macKey: Curve25519.KeyAgreement.PrivateKey = loadOrCreateKey()

    private func loadOrCreateKey() -> Curve25519.KeyAgreement.PrivateKey {
        if let s = try? keychain.password(for: "mac-key"), let raw = Data(base64Encoded: s),
           let k = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw) { return k }
        let k = Curve25519.KeyAgreement.PrivateKey()
        try? keychain.setPassword(k.rawRepresentation.base64EncodedString(), for: "mac-key")
        return k
    }

    private var macPublicKey: Data { macKey.publicKey.rawRepresentation }

    /// New key pair: every paired phone stops working (and the room changes).
    func resetKey() {
        let k = Curve25519.KeyAgreement.PrivateKey()
        try? keychain.setPassword(k.rawRepresentation.base64EncodedString(), for: "mac-key")
        macKey = k
        devices = []
        restart()
    }

    // MARK: Lifecycle

    func attach(sessions: SessionStore) {
        self.sessions = sessions
        restart()
    }

    func restart() {
        generation += 1
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        peers = [:]
        listTimer?.invalidate(); listTimer = nil
        guard enabled, sessions != nil else { status = .off; return }
        guard let base = URL(string: relayURL.trimmingCharacters(in: .whitespaces)), base.host != nil,
              let url = PairingLink.socketURL(relay: base, room: RelayCrypto.roomID(macPublicKey: macPublicKey),
                                              role: "mac", token: token) else {
            status = .failed(Localizer.shared.t("中继地址无效", "Invalid relay address"))
            return
        }
        status = .connecting
        let t = URLSession.shared.webSocketTask(with: url)
        t.maximumMessageSize = 1 << 20
        task = t
        t.resume()
        receive(t, generation)
        listTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pushSessionsIfChanged() }
        }
    }

    private func receive(_ t: URLSessionWebSocketTask, _ gen: Int) {
        t.receive { [weak self] result in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, gen == self.generation else { return }
                    switch result {
                    case .success(let msg):
                        if self.status != .online { self.status = .online; self.backoff = 1 }
                        switch msg {
                        case .string(let s): self.handleEnvelope(Data(s.utf8))
                        case .data(let d): self.handleEnvelope(d)
                        @unknown default: break
                        }
                        self.receive(t, gen)
                    case .failure(let e):
                        self.status = .failed(e.localizedDescription)
                        self.scheduleReconnect(gen)
                    }
                }
            }
        }
    }

    private func scheduleReconnect(_ gen: Int) {
        let delay = backoff
        backoff = min(backoff * 2, 60)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, gen == self.generation, self.enabled else { return }
                self.restart()
            }
        }
    }

    private func sendEnvelope(_ e: RelayEnvelope) {
        guard let task, let d = try? JSONEncoder().encode(e) else { return }
        task.send(.string(String(decoding: d, as: UTF8.self))) { _ in }
    }

    private func kick(_ peer: String) {
        peers[peer] = nil
        sendEnvelope(RelayEnvelope(t: "kick", peer: peer))
    }

    // MARK: Pairing

    /// Opens a 5-minute pairing window; the QR code carries this link.
    func startPairing() -> URL? {
        guard let base = URL(string: relayURL.trimmingCharacters(in: .whitespaces)), base.host != nil else { return nil }
        let code = PairingCode()
        pairing = code
        return PairingLink(relay: base, macPublicKey: macPublicKey, code: code.code, name: Foundation.Host.current().localizedName ?? "Mac").url
    }

    func stopPairing() { pairing = nil }

    func revoke(_ device: PairedPhone) {
        devices.removeAll { $0.publicKey == device.publicKey }
        for (id, p) in peers where p.phonePublicKey?.base64EncodedString() == device.publicKey { kick(id) }
    }

    private func isPaired(_ key: Data) -> Bool { devices.contains { $0.publicKey == key.base64EncodedString() } }

    // MARK: Incoming

    private func handleEnvelope(_ raw: Data) {
        guard let e = try? JSONDecoder().decode(RelayEnvelope.self, from: raw) else { return }
        switch e.t {
        case "join":
            guard let peer = e.peer else { return }
            peers[peer] = Peer()
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.handshakeTimeout) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let p = self.peers[peer], p.channel == nil else { return }
                    self.kick(peer)
                }
            }
        case "leave":
            if let peer = e.peer { peers[peer] = nil }
        case nil:
            guard let peer = e.from, let d = e.d, peers[peer] != nil else { return }
            guard let payload = try? RelayPayload(encoded: d) else { kick(peer); return }
            switch payload {
            case .handshake(let h): handshake(peer, h)
            case .sealed(let frame): sealed(peer, frame)
            }
        default: break
        }
    }

    private func handshake(_ peer: String, _ h: RelayHandshake) {
        guard peers[peer]?.channel == nil, h.t == "hello", h.v == 1,
              let pub = h.pub.flatMap({ Data(base64Encoded: $0) }), pub.count == 32,
              let nonce = h.nonce.flatMap({ Data(base64Encoded: $0) }), nonce.count == RelayCrypto.nonceSize else {
            kick(peer); return
        }
        guard isPaired(pub) || pairing?.isOpen() == true else {
            sendEnvelope(RelayEnvelope(to: peer, d: RelayPayload.handshake(.deny).encoded))
            kick(peer); return
        }
        let macNonce = RelayCrypto.randomNonce()
        guard let key = try? RelayCrypto.sessionKey(privateKey: macKey, peerPublicKey: pub, macPublicKey: macPublicKey,
                                                    phonePublicKey: pub, phoneNonce: nonce, macNonce: macNonce) else {
            kick(peer); return
        }
        peers[peer]?.phonePublicKey = pub
        peers[peer]?.channel = RelayChannel(key: key, side: .mac)
        peers[peer]?.authed = isPaired(pub)
        sendEnvelope(RelayEnvelope(to: peer, d: RelayPayload.handshake(.welcome(nonce: macNonce)).encoded))
        if isPaired(pub) { touch(pub) }
    }

    private func sealed(_ peer: String, _ frame: Data) {
        guard var p = peers[peer], var ch = p.channel, let plain = try? ch.open(frame),
              let msg = try? RelayMessage.decode(plain) else { kick(peer); return }
        p.channel = ch
        peers[peer] = p
        if !p.authed {
            guard msg.t == "pair", let code = msg.code, var window = pairing, let pub = p.phonePublicKey else {
                send(peer, .error("not paired")); return
            }
            let ok = window.redeem(code)
            pairing = window.isOpen() ? window : nil
            guard ok else { send(peer, .error(Localizer.shared.t("配对码无效", "Invalid pairing code"))); kick(peer); return }
            let name = String((msg.name ?? "Phone").prefix(40))
            devices.append(PairedPhone(publicKey: pub.base64EncodedString(), name: name, pairedAt: Date(), lastSeen: Date()))
            peers[peer]?.authed = true
            send(peer, RelayMessage(t: "paired", mac: Foundation.Host.current().localizedName ?? "Mac"))
            return
        }
        switch msg.t {
        case "list":
            send(peer, RelayMessage(t: "sessions", list: sessionList()))
        case "watch":
            guard let sid = msg.sid.flatMap(UUID.init(uuidString:)), sessions?.session(sid) != nil else {
                send(peer, .error("no such session")); return
            }
            peers[peer]?.watching = sid
            send(peer, .output(sid.uuidString, history[sid] ?? Data(), snapshot: true))
        case "input":
            guard peers[peer]?.limiter.allow() == true else { return }
            guard let sid = msg.sid.flatMap(UUID.init(uuidString:)), let s = sessions?.session(sid),
                  let text = msg.data, text.utf8.count <= RelayMessage.maxInput else { return }
            s.io.send(txt: text)
        default:
            send(peer, .error("unknown message"))
        }
    }

    private func touch(_ pub: Data) {
        let k = pub.base64EncodedString()
        if let i = devices.firstIndex(where: { $0.publicKey == k }) { devices[i].lastSeen = Date() }
    }

    private func send(_ peer: String, _ msg: RelayMessage) {
        guard var ch = peers[peer]?.channel, let body = try? msg.encoded(), let frame = try? ch.seal(body) else { return }
        peers[peer]?.channel = ch
        sendEnvelope(RelayEnvelope(to: peer, d: RelayPayload.sealed(frame).encoded))
    }

    // MARK: Sessions

    /// Raw output of every session: kept for snapshots, batched to watchers.
    func output(_ session: TerminalSession, _ bytes: ArraySlice<UInt8>) {
        guard enabled else { return }
        var h = history[session.id] ?? Data()
        h.append(contentsOf: bytes)
        if h.count > Self.historyLimit { h = Data(h.suffix(Self.historyLimit)) }
        history[session.id] = h
        guard peers.values.contains(where: { $0.watching == session.id }) else { return }
        pending[session.id, default: Data()].append(contentsOf: bytes)
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    private func flush() {
        flushScheduled = false
        let batch = pending
        pending = [:]
        for (sid, bytes) in batch {
            for (id, p) in peers where p.authed && p.watching == sid {
                send(id, .output(sid.uuidString, bytes))
            }
        }
    }

    private func sessionList() -> [RelaySessionInfo] {
        let live = sessions?.sessions ?? []
        let ids = Set(live.map(\.id))
        history = history.filter { ids.contains($0.key) }
        return live.map { s in
            var state: String?, note: String?
            switch s.agentState {
            case .idle?: state = "idle"
            case .working?: state = "working"
            case .needsYou(let m)?: state = "needsYou"; note = m
            case .done?: state = "done"
            case nil: break
            }
            return RelaySessionInfo(id: s.id.uuidString, title: s.title, agent: s.agentKind?.displayName,
                                    state: state, note: note, busy: s.isBusy)
        }
    }

    private func pushSessionsIfChanged() {
        guard peers.values.contains(where: \.authed) else { return }
        let list = sessionList()
        guard list != lastList else { return }
        lastList = list
        for (id, p) in peers where p.authed { send(id, RelayMessage(t: "sessions", list: list)) }
    }
}

// MARK: Settings

struct PhoneRelaySection: View {
    @Environment(Localizer.self) private var loc
    @State private var relay = PhoneRelay.shared
    @State private var pairURL: URL?

    var body: some View {
        WLFormSection(loc("手机中继", "Phone Relay"),
                      footer: loc("经自建中继在手机浏览器里看会话、回复 AI 的确认。Mac 只外连中继，不开端口；内容端到端加密，中继看不到。只有配对过的设备能输入。部署见 relay/README.md。",
                                  "View sessions and answer AI prompts from a phone browser through your own relay. This Mac only dials out; traffic is end-to-end encrypted and opaque to the relay. Only paired devices can type. See relay/README.md.")) {
            Toggle(isOn: $relay.enabled) {
                Text(loc("启用手机中继", "Enable phone relay")).font(WL.body).foregroundStyle(WL.textPrimary)
            }
            .toggleStyle(.wlSwitch).frame(minHeight: 38)
            WLFormDivider()
            WLFormRow(loc("中继地址", "Relay address"), detail: statusText) {
                TextField("", text: $relay.relayURL, prompt: Text("https://relay.example.com"))
                    .wlField().frame(width: 240)
                    .onSubmit { relay.restart() }
            }
            WLFormDivider()
            WLFormRow(loc("中继令牌", "Relay token"), detail: loc("中继设置了 RELAY_TOKEN 时填写", "If the relay sets RELAY_TOKEN")) {
                SecureField("", text: $relay.token).wlField().frame(width: 240)
                    .onSubmit { relay.restart() }
            }
            WLFormDivider()
            WLFormRow(loc("配对新设备", "Pair a device"),
                      detail: relay.pairing.map { loc("配对码 \($0.code)，5 分钟内有效", "Code \($0.code), valid for 5 minutes") }) {
                if pairURL != nil, relay.pairing != nil {
                    Button(loc("完成", "Done")) { relay.stopPairing(); pairURL = nil }.buttonStyle(.wlSecondary)
                } else {
                    Button(loc("显示二维码", "Show QR code")) { pairURL = relay.startPairing() }
                        .buttonStyle(.wlSecondary)
                        .disabled(!relay.enabled || relay.status != .online)
                }
            }
            if let pairURL, relay.pairing != nil, let image = Self.qr(pairURL.absoluteString) {
                HStack {
                    Spacer()
                    Image(nsImage: image).interpolation(.none).resizable().frame(width: 180, height: 180)
                        .padding(8).background(Color.white, in: RoundedRectangle(cornerRadius: WL.radius(8)))
                    Spacer()
                }
                .padding(.vertical, 8)
            }
            ForEach(relay.devices) { d in
                WLFormDivider()
                WLFormRow(d.name, detail: deviceDetail(d)) {
                    Button(loc("撤销", "Revoke")) { relay.revoke(d) }.buttonStyle(.wlSecondary)
                }
            }
            if !relay.devices.isEmpty {
                WLFormDivider()
                WLFormRow(loc("重置密钥", "Reset key"), detail: loc("所有已配对设备失效", "Unpairs every device")) {
                    Button(loc("重置", "Reset")) { relay.resetKey(); pairURL = nil }.buttonStyle(.wlSecondary)
                }
            }
        }
    }

    private var statusText: String {
        switch relay.status {
        case .off: loc("未启用", "Off")
        case .connecting: loc("连接中…", "Connecting…")
        case .online: loc("已连接，在线设备 \(relay.onlineCount)", "Connected, \(relay.onlineCount) device(s) online")
        case .failed(let m): loc("连接失败：", "Failed: ") + m
        }
    }

    private func deviceDetail(_ d: PairedPhone) -> String {
        let f = RelativeDateTimeFormatter()
        let seen = d.lastSeen.map { f.localizedString(for: $0, relativeTo: Date()) } ?? "—"
        return loc("上次在线 ", "Last seen ") + seen
    }

    private static func qr(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let out = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: out.extent.width, height: out.extent.height))
    }
}
