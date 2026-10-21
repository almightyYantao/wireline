import Foundation
import Security
import WirelineCore

/// Non-secret facts about a Touch ID–protected key. Stored as the Keychain
/// item's `kSecAttrGeneric` so the key list can be shown without ever reading
/// the private material.
struct ProtectedKeyInfo: Codable, Sendable, Identifiable, Equatable {
    var id: String { fingerprint }
    let fingerprint: String       // "SHA256:…", also the Keychain account
    let keyType: String           // e.g. "ssh-ed25519"
    let comment: String
    let publicBlob: Data
    /// Where the private key file lived when it was protected.
    var originalPath: String
    /// The original file was passphrase-encrypted (so keeping it is harmless).
    var originalWasEncrypted: Bool
    /// Set while the original sits in the Trash because the user moved it there.
    var trashedPath: String?
    var protectedAt: Date

    var movedToTrash: Bool { trashedPath != nil }
    var publicKeyLine: String { SSHPrivateKey.publicKeyLine(blob: publicBlob, comment: comment) }
}

/// Keeps protected private keys in the login Keychain: one generic-password item
/// per key (service `com.wireline.agent-keys`, account = SHA256 fingerprint),
/// holding the normalized UNENCRYPTED `openssh-key-v1` text, accessible only
/// while unlocked, on this device, never synced to iCloud.
///
/// Why not `SecAccessControl` with `.biometryCurrentSet`? That needs the
/// data-protection keychain, which requires a keychain-access-groups entitlement
/// — unavailable to the ad-hoc–signed builds `scripts/bundle.sh` can produce. So
/// the Keychain only provides encryption at rest; Touch ID is enforced in-app
/// (`TouchIDGate`) before every use of the material.
struct KeyVault: Sendable {
    let service = "com.wireline.agent-keys"

    enum VaultError: LocalizedError {
        case status(OSStatus)
        case corrupt

        var errorDescription: String? {
            switch self {
            case .status(let s):
                return "Keychain: " + (SecCopyErrorMessageString(s, nil) as String? ?? "\(s)")
            case .corrupt:
                return "Keychain item is unreadable"
            }
        }
    }

    private func query(_ fingerprint: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: fingerprint
        ]
    }

    /// All protected keys (metadata only — no secret is read).
    func list() -> [ProtectedKeyInfo] {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var items: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &items) == errSecSuccess,
              let rows = items as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            (row[kSecAttrGeneric as String] as? Data).flatMap { try? JSONDecoder().decode(ProtectedKeyInfo.self, from: $0) }
        }
        .sorted { $0.protectedAt < $1.protectedAt }
    }

    func contains(_ fingerprint: String) -> Bool {
        list().contains { $0.fingerprint == fingerprint }
    }

    func save(_ info: ProtectedKeyInfo, material: String) throws {
        var item = query(info.fingerprint)
        SecItemDelete(item as CFDictionary)
        item[kSecValueData as String] = Data(material.utf8)
        item[kSecAttrGeneric as String] = try JSONEncoder().encode(info)
        item[kSecAttrLabel as String] = "Wireline SSH key \(info.comment.isEmpty ? info.fingerprint : info.comment)"
        item[kSecAttrDescription as String] = "Wireline Touch ID protected SSH key"
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        item[kSecAttrSynchronizable as String] = false
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw VaultError.status(status) }
    }

    /// Rewrite the metadata only (e.g. after moving the original to the Trash).
    func update(_ info: ProtectedKeyInfo) throws {
        let attrs: [String: Any] = [kSecAttrGeneric as String: try JSONEncoder().encode(info)]
        let status = SecItemUpdate(query(info.fingerprint) as CFDictionary, attrs as CFDictionary)
        guard status == errSecSuccess else { throw VaultError.status(status) }
    }

    /// The unencrypted key text. Callers must have passed `TouchIDGate` first.
    func material(_ fingerprint: String) throws -> String {
        var q = query(fingerprint)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        guard status == errSecSuccess else { throw VaultError.status(status) }
        guard let data = item as? Data, let text = String(data: data, encoding: .utf8) else {
            throw VaultError.corrupt
        }
        return text
    }

    func privateKey(_ fingerprint: String) throws -> SSHPrivateKey {
        try SSHPrivateKey(openSSH: material(fingerprint))
    }

    func delete(_ fingerprint: String) throws {
        let status = SecItemDelete(query(fingerprint) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw VaultError.status(status) }
    }
}
