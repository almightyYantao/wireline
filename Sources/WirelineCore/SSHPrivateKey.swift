import Foundation
import CryptoKit
import Security

/// An unencrypted OpenSSH private key (`openssh-key-v1`), parsed far enough to
/// produce its public blob and to create SSH signatures in-process — the signing
/// half of Wireline's built-in ssh-agent.
///
/// Supported: ssh-ed25519, ecdsa-sha2-nistp256/384/521, ssh-rsa. Encrypted keys
/// are rejected (`.encrypted`); the app decrypts a temp copy with ssh-keygen first.
public struct SSHPrivateKey: Sendable {
    public enum Curve: String, Sendable {
        case p256 = "nistp256", p384 = "nistp384", p521 = "nistp521"
        public var keyType: String { "ecdsa-sha2-\(rawValue)" }
        /// Byte length of the private scalar / each signature half.
        var scalarLength: Int {
            switch self { case .p256: return 32; case .p384: return 48; case .p521: return 66 }
        }
    }

    /// RSA private parameters as unsigned big-endian magnitudes.
    public struct RSAParameters: Sendable {
        public let n, e, d, iqmp, p, q: Data
    }

    public enum Kind: Sendable {
        case ed25519(seed: Data)                   // 32-byte seed
        case ecdsa(curve: Curve, scalar: Data)     // fixed-length big-endian d
        case rsa(RSAParameters)
    }

    public enum ParseError: Error, Equatable {
        case notOpenSSHFormat
        case encrypted
        case malformed
        case unsupportedKeyType(String)
    }

    public enum SignError: Error {
        case crypto(String)
    }

    public let keyType: String
    public let kind: Kind
    public let publicKeyBlob: Data
    public let comment: String

    public var fingerprint: String { Self.fingerprint(of: publicKeyBlob) }

    /// `<type> <base64 blob> <comment>` — the `.pub` file contents.
    public var publicKeyLine: String {
        Self.publicKeyLine(blob: publicKeyBlob, comment: comment)
    }

    public static func publicKeyLine(blob: Data, comment: String) -> String {
        var reader = SSHWireReader(blob)
        let type = (try? reader.readStringUTF8()) ?? "unknown"
        let line = "\(type) \(blob.base64EncodedString())"
        return comment.isEmpty ? line : "\(line) \(comment)"
    }

    /// OpenSSH-style `SHA256:<base64, no padding>` fingerprint of a public blob.
    public static func fingerprint(of blob: Data) -> String {
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.replacingOccurrences(of: "=", with: "")
    }

    private static let begin = "-----BEGIN OPENSSH PRIVATE KEY-----"
    private static let end = "-----END OPENSSH PRIVATE KEY-----"
    private static let magic = Data("openssh-key-v1".utf8) + Data([0])

    /// Whether a key file's text is passphrase-protected, in either the
    /// `openssh-key-v1` format or a legacy PEM one ("Proc-Type: 4,ENCRYPTED" /
    /// "BEGIN ENCRYPTED PRIVATE KEY").
    public static func isEncrypted(_ text: String) -> Bool {
        if text.contains(begin) {
            do { _ = try SSHPrivateKey(openSSH: text); return false }
            catch ParseError.encrypted { return true }
            catch { return false }
        }
        return text.contains("ENCRYPTED")
    }

    public init(openSSH text: String) throws {
        guard let b = text.range(of: Self.begin), let e = text.range(of: Self.end),
              b.upperBound <= e.lowerBound else { throw ParseError.notOpenSSHFormat }
        let body = text[b.upperBound..<e.lowerBound].filter { !$0.isWhitespace }
        guard let raw = Data(base64Encoded: String(body)), raw.starts(with: Self.magic) else {
            throw ParseError.notOpenSSHFormat
        }
        do {
            var r = SSHWireReader(raw.dropFirst(Self.magic.count))
            let cipher = try r.readStringUTF8()
            _ = try r.readString()          // kdfname
            _ = try r.readString()          // kdfoptions
            guard cipher == "none" else { throw ParseError.encrypted }
            guard try r.readUInt32() == 1 else { throw ParseError.malformed }
            let blob = try r.readString()
            var p = SSHWireReader(try r.readString())
            guard try p.readUInt32() == p.readUInt32() else { throw ParseError.malformed }
            let type = try p.readStringUTF8()
            let kind: Kind
            switch type {
            case "ssh-ed25519":
                let pub = try p.readString()
                let priv = try p.readString()
                guard pub.count == 32, priv.count == 64 else { throw ParseError.malformed }
                let seed = Data(priv.prefix(32))
                // Cross-check: the seed must derive the stored public key.
                guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed),
                      key.publicKey.rawRepresentation == pub else { throw ParseError.malformed }
                kind = .ed25519(seed: seed)
            case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
                guard let curve = Curve(rawValue: try p.readStringUTF8()),
                      curve.keyType == type else { throw ParseError.malformed }
                let q = try p.readString()
                let d = try p.readMPInt()
                guard d.count <= curve.scalarLength else { throw ParseError.malformed }
                let scalar = Data(repeating: 0, count: curve.scalarLength - d.count) + d
                guard Self.ecdsaPublicPoint(curve: curve, scalar: scalar) == q else {
                    throw ParseError.malformed
                }
                kind = .ecdsa(curve: curve, scalar: scalar)
            case "ssh-rsa":
                let n = try p.readMPInt(), e = try p.readMPInt(), d = try p.readMPInt()
                let iqmp = try p.readMPInt(), pp = try p.readMPInt(), q = try p.readMPInt()
                guard !n.isEmpty, !d.isEmpty, !pp.isEmpty, !q.isEmpty else { throw ParseError.malformed }
                kind = .rsa(RSAParameters(n: n, e: e, d: d, iqmp: iqmp, p: pp, q: q))
            default:
                throw ParseError.unsupportedKeyType(type)
            }
            let comment = try p.readStringUTF8()
            var br = SSHWireReader(blob)
            guard try br.readStringUTF8() == type else { throw ParseError.malformed }
            self.keyType = type
            self.kind = kind
            self.publicKeyBlob = blob
            self.comment = comment
        } catch let error as ParseError {
            throw error
        } catch {
            throw ParseError.malformed
        }
    }

    private static func ecdsaPublicPoint(curve: Curve, scalar: Data) -> Data? {
        switch curve {
        case .p256: return try? P256.Signing.PrivateKey(rawRepresentation: scalar).publicKey.x963Representation
        case .p384: return try? P384.Signing.PrivateKey(rawRepresentation: scalar).publicKey.x963Representation
        case .p521: return try? P521.Signing.PrivateKey(rawRepresentation: scalar).publicKey.x963Representation
        }
    }

    // MARK: - Signing

    /// Sign `data` and return an SSH signature blob (`string alg, string sig`),
    /// as carried in an agent SIGN_RESPONSE. `flags` picks the RSA hash.
    public func sign(_ data: Data, flags: UInt32 = 0) throws -> Data {
        var out = SSHWireWriter()
        switch kind {
        case .ed25519(let seed):
            do {
                let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
                out.writeString("ssh-ed25519")
                out.writeString(try key.signature(for: data))
            } catch { throw SignError.crypto("ed25519") }
        case .ecdsa(let curve, let scalar):
            // CryptoKit hashes with the curve's matching digest (SHA-256/384/512),
            // exactly what ecdsa-sha2-nistp* specifies; raw output is r ‖ s.
            let raw: Data
            do {
                switch curve {
                case .p256: raw = try P256.Signing.PrivateKey(rawRepresentation: scalar).signature(for: data).rawRepresentation
                case .p384: raw = try P384.Signing.PrivateKey(rawRepresentation: scalar).signature(for: data).rawRepresentation
                case .p521: raw = try P521.Signing.PrivateKey(rawRepresentation: scalar).signature(for: data).rawRepresentation
                }
            } catch { throw SignError.crypto("ecdsa") }
            let half = raw.count / 2
            var inner = SSHWireWriter()
            inner.writeMPInt(Data(raw.prefix(half)))
            inner.writeMPInt(Data(raw.suffix(half)))
            out.writeString(curve.keyType)
            out.writeString(inner.data)
        case .rsa(let params):
            let alg: String
            let secAlg: SecKeyAlgorithm
            if flags & SSHAgentMessage.flagRSASHA512 != 0 {
                (alg, secAlg) = ("rsa-sha2-512", .rsaSignatureMessagePKCS1v15SHA512)
            } else if flags & SSHAgentMessage.flagRSASHA256 != 0 {
                (alg, secAlg) = ("rsa-sha2-256", .rsaSignatureMessagePKCS1v15SHA256)
            } else {
                (alg, secAlg) = ("ssh-rsa", .rsaSignatureMessagePKCS1v15SHA1)
            }
            let key = try Self.makeRSAKey(params)
            var error: Unmanaged<CFError>?
            guard let sig = SecKeyCreateSignature(key, secAlg, data as CFData, &error) as Data? else {
                throw SignError.crypto("rsa")
            }
            out.writeString(alg)
            out.writeString(sig)
        }
        return out.data
    }

    // MARK: - RSA

    /// SecKey only imports a full PKCS#1 RSAPrivateKey, which includes the CRT
    /// exponents dp = d mod (p-1) and dq = d mod (q-1) — OpenSSH's format omits
    /// them. We compute them here with a tiny shift-and-subtract modulo rather
    /// than shelling out to `ssh-keygen -m PEM`: that would mean writing another
    /// plaintext copy of the key to disk and spawning a process per key, while
    /// this is ~40 lines, pure, and fast enough (a few ms for a 4096-bit key).
    static func makeRSAKey(_ k: RSAParameters) throws -> SecKey {
        let dp = BigMod.mod(k.d, BigMod.decrement(k.p))
        let dq = BigMod.mod(k.d, BigMod.decrement(k.q))
        let der = DER.sequence([
            DER.integer(Data([0])), DER.integer(k.n), DER.integer(k.e), DER.integer(k.d),
            DER.integer(k.p), DER.integer(k.q), DER.integer(dp), DER.integer(dq), DER.integer(k.iqmp)
        ])
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(der as CFData, attrs as CFDictionary, &error) else {
            throw SignError.crypto("rsa import")
        }
        return key
    }
}

/// Minimal unsigned big-integer helpers for the RSA CRT parameters. Values are
/// big-endian byte magnitudes; internally little-endian UInt32 limbs.
enum BigMod {
    static func limbs(_ d: Data) -> [UInt32] {
        let bytes = [UInt8](d)
        var out = [UInt32](repeating: 0, count: (bytes.count + 3) / 4)
        for (i, b) in bytes.reversed().enumerated() { out[i / 4] |= UInt32(b) << (8 * UInt32(i % 4)) }
        return out
    }

    static func bytes(_ l: [UInt32]) -> Data {
        var out = [UInt8]()
        for limb in l.reversed() {
            out += [UInt8(limb >> 24 & 0xff), UInt8(limb >> 16 & 0xff), UInt8(limb >> 8 & 0xff), UInt8(limb & 0xff)]
        }
        return Data(out.drop { $0 == 0 })
    }

    /// a - 1 (a > 0).
    static func decrement(_ a: Data) -> Data {
        var l = limbs(a)
        for i in l.indices {
            if l[i] > 0 { l[i] -= 1; break }
            l[i] = .max
        }
        return bytes(l)
    }

    /// a mod m, by binary long division (one shift + conditional subtract per bit of a).
    static func mod(_ a: Data, _ m: Data) -> Data {
        let ml = limbs(m) + [0]
        var r = [UInt32](repeating: 0, count: ml.count)
        for byte in a {
            for bit in (0..<8).reversed() {
                // r = r << 1 | bit
                var carry = UInt32(byte >> UInt8(bit) & 1)
                for i in r.indices {
                    let next = r[i] >> 31
                    r[i] = r[i] << 1 | carry
                    carry = next
                }
                if !less(r, ml) { subtract(&r, ml) }
            }
        }
        return bytes(r)
    }

    private static func less(_ a: [UInt32], _ b: [UInt32]) -> Bool {
        for i in a.indices.reversed() where a[i] != b[i] { return a[i] < b[i] }
        return false
    }

    private static func subtract(_ a: inout [UInt32], _ b: [UInt32]) {
        var borrow: UInt64 = 0
        for i in a.indices {
            let lhs = UInt64(a[i]), rhs = UInt64(b[i]) + borrow
            if lhs >= rhs { a[i] = UInt32(lhs - rhs); borrow = 0 }
            else { a[i] = UInt32(lhs + (1 << 32) - rhs); borrow = 1 }
        }
    }
}

/// Just enough DER to build a PKCS#1 RSAPrivateKey.
enum DER {
    static func length(_ n: Int) -> Data {
        if n < 0x80 { return Data([UInt8(n)]) }
        var bytes = [UInt8]()
        var v = n
        while v > 0 { bytes.insert(UInt8(v & 0xff), at: 0); v >>= 8 }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }

    static func integer(_ magnitude: Data) -> Data {
        var bytes = [UInt8](magnitude.drop { $0 == 0 })
        if bytes.isEmpty || bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        return Data([0x02]) + length(bytes.count) + Data(bytes)
    }

    static func sequence(_ items: [Data]) -> Data {
        let body = items.reduce(Data(), +)
        return Data([0x30]) + length(body.count) + body
    }
}
