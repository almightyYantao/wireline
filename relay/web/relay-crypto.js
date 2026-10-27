// Phone side of the relay protocol (docs/design/phone-relay.md); mirrors
// Sources/WirelineCore/RelayProtocol.swift. Works in browsers and Node (WebCrypto).
(function (root) {
  const subtle = root.crypto.subtle;
  const enc = new TextEncoder(), dec = new TextDecoder();
  const LABEL = enc.encode('wireline-relay v2');

  const b64 = (u8) => { let s = ''; for (const b of u8) s += String.fromCharCode(b); return btoa(s); };
  const unb64 = (s) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
  const b64url = (u8) => b64(u8).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  const unb64url = (s) => unb64(s.replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((s.length + 3) % 4));
  const concat = (...parts) => {
    const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
    let o = 0; for (const p of parts) { out.set(p, o); o += p.length; }
    return out;
  };

  const VERSION = 2;

  // { privateKey: CryptoKey, publicRaw }. Static keys are made non-extractable.
  async function generateKeys(extractable = false) {
    const kp = await subtle.generateKey({ name: 'X25519' }, extractable, ['deriveBits']);
    return { privateKey: kp.privateKey, publicRaw: new Uint8Array(await subtle.exportKey('raw', kp.publicKey)) };
  }

  const importPrivate = (jwk) => subtle.importKey('jwk', jwk, { name: 'X25519' }, false, ['deriveBits']);

  async function roomID(macPub) {
    return b64url(new Uint8Array(await subtle.digest('SHA-256', macPub))).slice(0, 22);
  }

  async function dh(priv, pub) {
    const peer = await subtle.importKey('raw', pub, { name: 'X25519' }, false, []);
    return new Uint8Array(await subtle.deriveBits({ name: 'X25519', public: peer }, priv, 256));
  }

  // HKDF(ikm: X25519(eph, peerEph) || X25519(static, peerStatic), salt: phoneNonce || macNonce,
  // info: label || macStatic || phoneStatic || macEph || phoneEph). t holds the public values.
  async function sessionKey(staticKey, ephemeralKey, t, side) {
    const [peerStatic, peerEph] = side === 'mac' ? [t.phoneStatic, t.phoneEph] : [t.macStatic, t.macEph];
    const ikm = await subtle.importKey('raw', concat(await dh(ephemeralKey, peerEph), await dh(staticKey, peerStatic)),
                                       'HKDF', false, ['deriveKey']);
    return subtle.deriveKey({ name: 'HKDF', hash: 'SHA-256', salt: concat(t.phoneNonce, t.macNonce),
                              info: concat(LABEL, t.macStatic, t.phoneStatic, t.macEph, t.phoneEph) },
                            ikm, { name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']);
  }

  function iv(dir, counter) {
    const v = new Uint8Array(12); v[0] = dir;
    new DataView(v.buffer).setBigUint64(4, counter);
    return v;
  }

  // side: 'phone' sends dir 2 and receives dir 1; 'mac' the reverse.
  function channel(key, side) {
    const [sendDir, recvDir] = side === 'mac' ? [1, 2] : [2, 1];
    let sent = 0n, received = 0n;
    return {
      async seal(plain) {
        sent += 1n;
        const ct = new Uint8Array(await subtle.encrypt({ name: 'AES-GCM', iv: iv(sendDir, sent), additionalData: LABEL }, key, plain));
        const head = new Uint8Array(8); new DataView(head.buffer).setBigUint64(0, sent);
        return concat(head, ct);
      },
      async open(frame) {
        if (frame.length < 24) throw new Error('malformed');
        const counter = new DataView(frame.buffer, frame.byteOffset, 8).getBigUint64(0);
        if (counter <= received) throw new Error('replay');
        const pt = new Uint8Array(await subtle.decrypt({ name: 'AES-GCM', iv: iv(recvDir, counter), additionalData: LABEL }, key, frame.subarray(8)));
        received = counter;
        return pt;
      },
    };
  }

  // Envelope payload `d`: tag 0 = handshake JSON, tag 1 = sealed frame.
  const payload = {
    handshake: (obj) => b64(concat(new Uint8Array([0]), enc.encode(JSON.stringify(obj)))),
    sealed: (frame) => b64(concat(new Uint8Array([1]), frame)),
    parse(d) {
      const u = unb64(d);
      if (u[0] === 0) return { handshake: JSON.parse(dec.decode(u.subarray(1))) };
      if (u[0] === 1) return { sealed: u.subarray(1) };
      throw new Error('malformed');
    },
  };

  // The phone's static key: a non-extractable CryptoKey kept in IndexedDB
  // (structured clone keeps it usable without ever exposing the bytes).
  const keystore = {
    db() {
      return new Promise((res, rej) => {
        const r = root.indexedDB.open('wireline-relay', 1);
        r.onupgradeneeded = () => r.result.createObjectStore('keys');
        r.onsuccess = () => res(r.result); r.onerror = () => rej(r.error);
      });
    },
    async op(mode, fn) {
      const db = await keystore.db();
      return new Promise((res, rej) => {
        const tx = db.transaction('keys', mode), r = fn(tx.objectStore('keys'));
        tx.oncomplete = () => { db.close(); res(r && r.result); };
        tx.onerror = () => { db.close(); rej(tx.error); };
      });
    },
    get: () => keystore.op('readonly', (s) => s.get('static')),
    put: (v) => keystore.op('readwrite', (s) => { s.put(v, 'static'); }),
    clear: () => keystore.op('readwrite', (s) => { s.delete('static'); }),
  };

  root.WLRelay = { keystore, VERSION, b64, unb64, b64url, unb64url, enc, dec, generateKeys, importPrivate, roomID, sessionKey, channel, payload,
                   nonce: () => root.crypto.getRandomValues(new Uint8Array(16)) };
})(typeof window !== 'undefined' ? window : globalThis);
