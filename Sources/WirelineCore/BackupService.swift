import Foundation
import CryptoKit
import CommonCrypto

/// The decrypted contents of a backup: every host plus the passwords that live
/// in the Keychain. This is the only place secrets and hosts travel together,
/// and only ever inside an encrypted envelope.
public struct BackupBundle: Codable, Sendable {
    public var hosts: [Host]
    /// alias -> password, only for hosts that use password auth.
    public var passwords: [String: String]
    /// The user's to-do items, so a migration carries them along too.
    public var todos: [Todo]

    public init(hosts: [Host], passwords: [String: String], todos: [Todo] = []) {
        self.hosts = hosts
        self.passwords = passwords
        self.todos = todos
    }

    // Tolerant decoding: backups written before to-dos existed have no `todos`
    // key, and must still restore.
    enum CodingKeys: String, CodingKey { case hosts, passwords, todos }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hosts = try c.decode([Host].self, forKey: .hosts)
        passwords = try c.decode([String: String].self, forKey: .passwords)
        todos = try c.decodeIfPresent([Todo].self, forKey: .todos) ?? []
    }
}

/// Encrypts/decrypts a `BackupBundle` under a user passphrase for cross-device
/// migration. The passphrase never touches disk; losing it means the backup is
/// unrecoverable — by design (see §八 of the project brief).
public struct BackupService: Sendable {
    public static let magic = "wireline-backup"
    public static let version = 1
    public var iterations: Int

    public init(iterations: Int = 200_000) {
        self.iterations = iterations
    }

    public enum BackupError: Error, CustomStringConvertible {
        case badFormat
        case wrongPassphraseOrCorrupt
        case keyDerivationFailed

        public var description: String {
            switch self {
            case .badFormat: return "This file is not a Wireline backup."
            case .wrongPassphraseOrCorrupt: return "Wrong passphrase, or the backup is corrupted."
            case .keyDerivationFailed: return "Could not derive an encryption key."
            }
        }
    }

    // On-disk envelope. All binary fields are base64 for portability.
    private struct Envelope: Codable {
        var format: String
        var version: Int
        var kdf: String
        var iterations: Int
        var salt: String
        var sealed: String   // AES-GCM combined (nonce || ciphertext || tag)
    }

    public func export(_ bundle: BackupBundle, passphrase: String) throws -> Data {
        let salt = Self.randomBytes(16)
        let key = try Self.deriveKey(passphrase: passphrase, salt: salt, iterations: iterations)
        let plaintext = try JSONEncoder().encode(bundle)
        let box = try AES.GCM.seal(plaintext, using: key)
        guard let combined = box.combined else { throw BackupError.keyDerivationFailed }

        let envelope = Envelope(
            format: Self.magic,
            version: Self.version,
            kdf: "pbkdf2-sha256",
            iterations: iterations,
            salt: salt.base64EncodedString(),
            sealed: combined.base64EncodedString()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(envelope)
    }

    public func `import`(_ data: Data, passphrase: String) throws -> BackupBundle {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.format == Self.magic else {
            throw BackupError.badFormat
        }
        guard let salt = Data(base64Encoded: envelope.salt),
              let sealed = Data(base64Encoded: envelope.sealed) else {
            throw BackupError.badFormat
        }
        let key = try Self.deriveKey(passphrase: passphrase, salt: salt,
                                     iterations: envelope.iterations)
        do {
            let box = try AES.GCM.SealedBox(combined: sealed)
            let plaintext = try AES.GCM.open(box, using: key)
            return try JSONDecoder().decode(BackupBundle.self, from: plaintext)
        } catch {
            throw BackupError.wrongPassphraseOrCorrupt
        }
    }

    // MARK: - Crypto helpers

    static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    static func deriveKey(passphrase: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        var derived = [UInt8](repeating: 0, count: 32)
        let pwData = Array(passphrase.utf8)
        let saltBytes = Array(salt)
        let status = saltBytes.withUnsafeBufferPointer { saltPtr in
            derived.withUnsafeMutableBufferPointer { outPtr in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pwData, pwData.count,
                    saltPtr.baseAddress, saltPtr.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(iterations),
                    outPtr.baseAddress, outPtr.count
                )
            }
        }
        guard status == kCCSuccess else { throw BackupError.keyDerivationFailed }
        return SymmetricKey(data: Data(derived))
    }
}
