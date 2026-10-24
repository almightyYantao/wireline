import Foundation
import WirelineCore

/// What a `PrivacyMasker` must recognise beyond its patterns: the real
/// addresses behind the aliases (ssh config `HostName`s) and every password
/// saved in the Keychain. Read from any thread (`AIClient` streams off the main
/// actor); the passwords are re-read at most once a minute.
enum PrivacyContext {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var hosts: [String] = []
    nonisolated(unsafe) private static var secrets: [String] = []
    nonisolated(unsafe) private static var secretsRead = Date.distantPast

    /// Called whenever the host list is (re)loaded.
    static func setHosts(_ list: [Host]) {
        let names = list.compactMap(\.hostname)
        lock.lock(); hosts = names; lock.unlock()
    }

    #if DEBUG
    /// Stands in for the Keychain in tests (reading the app's items from the
    /// test runner would raise an access prompt).
    nonisolated(unsafe) static var passwordsForTesting: [String]?
    #endif

    private static func savedPasswords() -> [String] {
        #if DEBUG
        if let fake = passwordsForTesting { return fake }
        #endif
        let keychain = KeychainService()
        return keychain.accounts().compactMap { (try? keychain.password(for: $0)) ?? nil }
    }

    private static func known() -> (hosts: [String], secrets: [String]) {
        lock.lock()
        let stale = Date().timeIntervalSince(secretsRead) > 60
        lock.unlock()
        if stale {
            let fresh = savedPasswords()
            lock.lock(); secrets = fresh; secretsRead = Date(); lock.unlock()
        }
        lock.lock(); defer { lock.unlock() }
        return (hosts, secrets)
    }

    /// A new masker at `level`, or nil when masking is off.
    static func masker(_ level: PrivacyPolicy.Level) -> PrivacyMasker? {
        guard level != .off else { return nil }
        let k = known()
        return PrivacyMasker(policy: PrivacyPolicy(level: level, knownHosts: k.hosts, knownSecrets: k.secrets))
    }

    nonisolated(unsafe) private static var conversations: [String: PrivacyMasker] = [:]

    /// The masker for one conversation (a host's AI panel, the pet), so a value
    /// keeps one placeholder across turns. Memory only: after a restart the
    /// saved history's placeholders no longer resolve, and
    /// `PrivacyMasker.containsPlaceholder` keeps them from being run. A new
    /// level starts a new masker.
    static func masker(conversation key: String, level: PrivacyPolicy.Level) -> PrivacyMasker? {
        lock.lock()
        if let m = conversations[key], m.level == level { lock.unlock(); return m }
        lock.unlock()
        let m = masker(level)
        lock.lock(); conversations[key] = m; lock.unlock()
        return m
    }

    /// Bring a long-lived masker up to date before it masks another request.
    static func refresh(_ masker: PrivacyMasker) {
        let k = known()
        masker.updateKnown(hosts: k.hosts, secrets: k.secrets)
    }
}
