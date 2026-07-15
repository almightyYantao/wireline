import Foundation
import Security

/// Stores host passwords in the macOS Keychain. The ssh config only ever records
/// `auth=password`; the secret itself never touches disk in plaintext.
///
/// Each password is a generic-password item keyed by `(service, account=alias)`.
public struct KeychainService: Sendable {
    public let service: String

    public init(service: String = "com.wireline.app") {
        self.service = service
    }

    public enum KeychainError: Error, CustomStringConvertible {
        case unexpectedStatus(OSStatus)
        case dataEncoding

        public var description: String {
            switch self {
            case .unexpectedStatus(let s):
                let msg = SecCopyErrorMessageString(s, nil) as String? ?? "unknown"
                return "Keychain error \(s): \(msg)"
            case .dataEncoding:
                return "Failed to encode/decode keychain data."
            }
        }
    }

    private func baseQuery(_ alias: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: alias
        ]
    }

    /// Insert or update the password for a host alias.
    public func setPassword(_ password: String, for alias: String) throws {
        guard let data = password.data(using: .utf8) else { throw KeychainError.dataEncoding }
        let query = baseQuery(alias)
        let attributes: [String: Any] = [kSecValueData as String: data]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Fetch the password for a host alias, or `nil` if none is stored.
    public func password(for alias: String) throws -> String? {
        var query = baseQuery(alias)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let str = String(data: data, encoding: .utf8) else {
                throw KeychainError.dataEncoding
            }
            return str
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func hasPassword(for alias: String) -> Bool {
        (try? password(for: alias)) != nil
    }

    public func deletePassword(for alias: String) throws {
        let status = SecItemDelete(baseQuery(alias) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Rename an alias's keychain entry (used when a host is renamed).
    public func rename(from old: String, to new: String) throws {
        guard old != new, let pw = try password(for: old) else { return }
        try setPassword(pw, for: new)
        try deletePassword(for: old)
    }
}
