import Foundation
import CryptoKit

/// Phone relay wire protocol (docs/design/phone-relay.md): handshake, key
/// derivation, sealed frames and the inner messages. Mirrors relay/web/index.html.
public enum RelayCrypto {
    public static let label = Data("wireline-relay v1".utf8)
    public static let nonceSize = 16

    /// The relay room a Mac lives in: derived from its public key.
    public static func roomID(macPublicKey: Data) -> String {
        String(Data(SHA256.hash(data: macPublicKey)).base64URL.prefix(22))
    }

    public static func randomNonce() -> Data {
        Data((0 ..< nonceSize).map { _ in UInt8.random(in: 0 ... 255) })
    }

    /// HKDF-SHA256(X25519(priv, peer), salt: phoneNonce‖macNonce, info: label‖macPub‖phonePub).
    public static func sessionKey(privateKey: Curve25519.KeyAgreement.PrivateKey, peerPublicKey: Data,
                                  macPublicKey: Data, phonePublicKey: Data,
                                  phoneNonce: Data, macNonce: Data) throws -> SymmetricKey {
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        return shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: phoneNonce + macNonce,
                                              sharedInfo: label + macPublicKey + phonePublicKey,
                                              outputByteCount: 32)
    }
}

public enum RelayError: Error, Equatable {
    case malformed, replay, badKey
}

/// One direction-aware AES-GCM channel. Frame = counter(8, BE) ‖ ciphertext ‖ tag;
/// IV = dir ‖ 000000 ‖ counter. Counters strictly increase per direction.
public struct RelayChannel: Sendable {
    public enum Side: Sendable { case mac, phone }
    private let key: SymmetricKey
    private let sendDir: UInt8, recvDir: UInt8
    private var sent: UInt64 = 0
    private var received: UInt64 = 0

    public init(key: SymmetricKey, side: Side) {
        self.key = key
        (sendDir, recvDir) = side == .mac ? (1, 2) : (2, 1)
    }

    private static func iv(_ dir: UInt8, _ counter: UInt64) -> Data {
        var d = Data([dir, 0, 0, 0])
        withUnsafeBytes(of: counter.bigEndian) { d.append(contentsOf: $0) }
        return d
    }

    public mutating func seal(_ plaintext: Data) throws -> Data {
        sent += 1
        let box = try AES.GCM.seal(plaintext, using: key, nonce: AES.GCM.Nonce(data: Self.iv(sendDir, sent)),
                                   authenticating: RelayCrypto.label)
        var out = Data()
        withUnsafeBytes(of: sent.bigEndian) { out.append(contentsOf: $0) }
        return out + box.ciphertext + box.tag
    }

    public mutating func open(_ frame: Data) throws -> Data {
        let f = Data(frame)
        guard f.count >= 8 + 16 else { throw RelayError.malformed }
        let counter = f.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        guard counter > received else { throw RelayError.replay }
        let body = f.dropFirst(8)
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: Self.iv(recvDir, counter)),
                                        ciphertext: body.dropLast(16), tag: body.suffix(16))
        let plain = try AES.GCM.open(box, using: key, authenticating: RelayCrypto.label)
        received = counter
        return plain
    }
}

/// Payload of a relay envelope's `d`: tag 0 = handshake JSON, tag 1 = sealed frame.
public enum RelayPayload: Equatable, Sendable {
    case handshake(RelayHandshake)
    case sealed(Data)

    public var encoded: String {
        switch self {
        case .handshake(let h): (Data([0]) + ((try? JSONEncoder().encode(h)) ?? Data())).base64EncodedString()
        case .sealed(let d): (Data([1]) + d).base64EncodedString()
        }
    }

    public init(encoded: String) throws {
        guard let d = Data(base64Encoded: encoded), let tag = d.first else { throw RelayError.malformed }
        switch tag {
        case 0: self = .handshake(try JSONDecoder().decode(RelayHandshake.self, from: d.dropFirst()))
        case 1: self = .sealed(Data(d.dropFirst()))
        default: throw RelayError.malformed
        }
    }
}

public struct RelayHandshake: Codable, Equatable, Sendable {
    public var t: String
    public var v: Int?
    public var pub: String?
    public var nonce: String?

    public static func hello(publicKey: Data, nonce: Data) -> Self {
        Self(t: "hello", v: 1, pub: publicKey.base64EncodedString(), nonce: nonce.base64EncodedString())
    }
    public static func welcome(nonce: Data) -> Self { Self(t: "welcome", nonce: nonce.base64EncodedString()) }
    public static let deny = Self(t: "deny")
}

/// Relay envelope (what the relay itself reads).
public struct RelayEnvelope: Codable, Equatable, Sendable {
    public var t: String?
    public var peer: String?
    public var to: String?
    public var from: String?
    public var d: String?
    public var up: Bool?

    public init(t: String? = nil, peer: String? = nil, to: String? = nil, from: String? = nil, d: String? = nil, up: Bool? = nil) {
        self.t = t; self.peer = peer; self.to = to; self.from = from; self.d = d; self.up = up
    }
}

/// A session as the phone lists it.
public struct RelaySessionInfo: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var agent: String?
    public var state: String?
    public var note: String?
    public var busy: Bool

    public init(id: String, title: String, agent: String? = nil, state: String? = nil, note: String? = nil, busy: Bool = false) {
        self.id = id; self.title = title; self.agent = agent; self.state = state; self.note = note; self.busy = busy
    }
}

/// Inner (encrypted) message, both directions.
public struct RelayMessage: Codable, Equatable, Sendable {
    public var t: String
    public var code: String?
    public var name: String?
    public var sid: String?
    /// `input`: UTF-8 text. `snapshot` / `out`: base64 bytes.
    public var data: String?
    public var message: String?
    public var mac: String?
    public var list: [RelaySessionInfo]?

    public init(t: String, code: String? = nil, name: String? = nil, sid: String? = nil, data: String? = nil,
                message: String? = nil, mac: String? = nil, list: [RelaySessionInfo]? = nil) {
        self.t = t; self.code = code; self.name = name; self.sid = sid; self.data = data
        self.message = message; self.mac = mac; self.list = list
    }

    public static let maxInput = 4096

    public static func output(_ sid: String, _ bytes: Data, snapshot: Bool = false) -> Self {
        Self(t: snapshot ? "snapshot" : "out", sid: sid, data: bytes.base64EncodedString())
    }
    public static func error(_ text: String) -> Self { Self(t: "error", message: text) }

    public func encoded() throws -> Data { try JSONEncoder().encode(self) }
    public static func decode(_ data: Data) throws -> Self { try JSONDecoder().decode(Self.self, from: data) }
}

/// One-time pairing code: 8 Crockford base32 characters, expires, single use,
/// void after too many wrong tries.
public struct PairingCode: Sendable {
    public static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    public let code: String
    public let expires: Date
    public private(set) var failures = 0
    public private(set) var used = false
    public static let maxFailures = 5

    public init(code: String? = nil, now: Date = Date(), lifetime: TimeInterval = 300) {
        self.code = code ?? String((0 ..< 8).map { _ in Self.alphabet.randomElement()! })
        self.expires = now.addingTimeInterval(lifetime)
    }

    public func isOpen(at now: Date = Date()) -> Bool {
        !used && failures < Self.maxFailures && now < expires
    }

    /// Consumes the code on success; counts a failure otherwise.
    public mutating func redeem(_ attempt: String, at now: Date = Date()) -> Bool {
        guard isOpen(at: now) else { return false }
        let a = Array(attempt.uppercased().utf8), b = Array(code.utf8)
        var diff = a.count ^ b.count
        for i in 0 ..< min(a.count, b.count) { diff |= Int(a[i] ^ b[i]) }
        if diff == 0 { used = true; return true }
        failures += 1
        return false
    }
}

/// What the QR code carries: `https://relay/#v=1&k=<pub>&c=<code>&n=<name>`.
public struct PairingLink: Equatable, Sendable {
    public var relay: URL
    public var macPublicKey: Data
    public var code: String
    public var name: String

    public init(relay: URL, macPublicKey: Data, code: String, name: String) {
        self.relay = relay; self.macPublicKey = macPublicKey; self.code = code; self.name = name
    }

    public var url: URL {
        var c = URLComponents(url: relay, resolvingAgainstBaseURL: false)!
        if c.path.isEmpty { c.path = "/" }
        var f = URLComponents()
        f.queryItems = [URLQueryItem(name: "v", value: "1"), URLQueryItem(name: "k", value: macPublicKey.base64URL),
                        URLQueryItem(name: "c", value: code), URLQueryItem(name: "n", value: name)]
        c.percentEncodedFragment = f.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return c.url!
    }

    public init?(url: URL) {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false), let frag = c.percentEncodedFragment else { return nil }
        var q = URLComponents()
        q.percentEncodedQuery = frag
        let items = Dictionary((q.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        guard items["v"] == "1", let k = items["k"].flatMap(Data.init(base64URL:)), k.count == 32,
              let code = items["c"], !code.isEmpty else { return nil }
        c.fragment = nil
        guard let relay = c.url else { return nil }
        self.init(relay: relay, macPublicKey: k, code: code, name: items["n"] ?? "")
    }

    /// The relay's WebSocket endpoint for a role (`ws`/`wss` from `http`/`https`).
    public static func socketURL(relay: URL, room: String, role: String, token: String? = nil) -> URL? {
        guard var c = URLComponents(url: relay, resolvingAgainstBaseURL: false) else { return nil }
        c.scheme = c.scheme == "https" || c.scheme == "wss" ? "wss" : "ws"
        c.path = (c.path.hasSuffix("/") ? String(c.path.dropLast()) : c.path) + "/ws"
        c.queryItems = [URLQueryItem(name: "room", value: room), URLQueryItem(name: "role", value: role)]
            + (token.flatMap { $0.isEmpty ? nil : [URLQueryItem(name: "token", value: $0)] } ?? [])
        c.fragment = nil
        return c.url
    }
}

/// Token bucket: `rate` events per second, bursting to `rate`.
public struct RelayRateLimiter: Sendable {
    public let rate: Double
    private var tokens: Double
    private var last: Date

    public init(rate: Double, now: Date = Date()) {
        self.rate = rate; tokens = rate; last = now
    }

    public mutating func allow(at now: Date = Date()) -> Bool {
        tokens = min(rate, tokens + now.timeIntervalSince(last) * rate)
        last = now
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }
}

extension Data {
    public var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public init?(base64URL s: String) {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b += String(repeating: "=", count: (4 - b.count % 4) % 4)
        self.init(base64Encoded: b)
    }
}
