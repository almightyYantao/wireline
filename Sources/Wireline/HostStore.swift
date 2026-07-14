import Foundation
import Observation
import WirelineCore

/// Central, observable application state. Owns the parsed ssh config, keychain
/// access, live host statuses, and preferences. Everything the UI renders flows
/// from here, and every mutation writes straight back to `~/.ssh/config`.
@Observable
@MainActor
final class HostStore {
    private(set) var document: SSHConfig.Document
    private(set) var hosts: [Host]
    var statuses: [String: HostStatus] = [:]
    var lastError: String?

    // Preferences (mirrored into UserDefaults).
    var terminalApp: TerminalApp {
        didSet { UserDefaults.standard.set(terminalApp.rawValue, forKey: "terminalApp") }
    }
    var autoCheckOnLaunch: Bool {
        didSet { UserDefaults.standard.set(autoCheckOnLaunch, forKey: "autoCheckOnLaunch") }
    }
    /// Use the app's built-in terminal (default), or hand off to Terminal.app/iTerm2.
    var useBuiltInTerminal: Bool {
        didSet { UserDefaults.standard.set(useBuiltInTerminal, forKey: "useBuiltInTerminal") }
    }
    /// Terminal background opacity (0.2–1.0). Below 1 lets the background image
    /// (or the window behind) show through.
    var terminalOpacity: Double {
        didSet { UserDefaults.standard.set(terminalOpacity, forKey: "terminalOpacity") }
    }
    /// Optional path to a terminal background image.
    var terminalBgImagePath: String? {
        didSet { UserDefaults.standard.set(terminalBgImagePath, forKey: "terminalBgImagePath") }
    }
    /// Terminal font family name (nil = auto-detected Nerd Font).
    var terminalFontName: String? {
        didSet { UserDefaults.standard.set(terminalFontName, forKey: "terminalFontName") }
    }
    var terminalFontSize: Double {
        didSet { UserDefaults.standard.set(terminalFontSize, forKey: "terminalFontSize") }
    }
    /// The active color scheme, persisted as JSON. Nil = built-in default.
    var terminalTheme: TerminalTheme? {
        didSet {
            let data = terminalTheme.flatMap { try? JSONEncoder().encode($0) }
            UserDefaults.standard.set(data, forKey: "terminalTheme")
        }
    }

    let repository: ConfigRepository
    let keychain: KeychainService
    let checker: ConnectivityChecker

    init(repository: ConfigRepository = ConfigRepository(),
         keychain: KeychainService = KeychainService(),
         checker: ConnectivityChecker = ConnectivityChecker()) {
        self.repository = repository
        self.keychain = keychain
        self.checker = checker
        let saved = UserDefaults.standard.string(forKey: "terminalApp")
        self.terminalApp = saved.flatMap(TerminalApp.init) ?? .terminal
        self.autoCheckOnLaunch = UserDefaults.standard.object(forKey: "autoCheckOnLaunch") as? Bool ?? true
        self.useBuiltInTerminal = UserDefaults.standard.object(forKey: "useBuiltInTerminal") as? Bool ?? true
        self.terminalOpacity = UserDefaults.standard.object(forKey: "terminalOpacity") as? Double ?? 1.0
        self.terminalBgImagePath = UserDefaults.standard.string(forKey: "terminalBgImagePath")
        self.terminalFontName = UserDefaults.standard.string(forKey: "terminalFontName")
        self.terminalFontSize = UserDefaults.standard.object(forKey: "terminalFontSize") as? Double ?? 13
        self.terminalTheme = UserDefaults.standard.data(forKey: "terminalTheme")
            .flatMap { try? JSONDecoder().decode(TerminalTheme.self, from: $0) }
        self.document = SSHConfig.Document(items: [])
        self.hosts = []
        reload()
    }

    // MARK: - Loading / saving

    func reload() {
        do {
            document = try repository.load()
            hosts = document.hosts
        } catch {
            lastError = "Failed to read ssh config: \(error.localizedDescription)"
        }
    }

    /// Persist the current host list back to disk, preserving unmanaged blocks.
    private func persist() {
        // Rebuild the document: keep raw items, replace host items in order,
        // append any newly-added hosts at the end.
        var remaining = hosts
        var newItems: [SSHConfig.Item] = []
        for item in document.items {
            switch item {
            case .raw(let text):
                newItems.append(.raw(text))
            case .host(let old):
                if let idx = remaining.firstIndex(where: { $0.alias == old.alias }) {
                    newItems.append(.host(remaining.remove(at: idx)))
                }
                // else: host was deleted — drop it.
            }
        }
        for leftover in remaining { newItems.append(.host(leftover)) }
        document = SSHConfig.Document(items: newItems)
        do {
            try repository.save(document)
        } catch {
            lastError = "Failed to write ssh config: \(error.localizedDescription)"
        }
    }

    // MARK: - Grouping

    /// User-created groups that don't (yet) contain any host. Persisted so an
    /// empty group stays visible until a host is dragged into it.
    var emptyGroups: [String] = UserDefaults.standard.stringArray(forKey: "emptyGroups") ?? [] {
        didSet { UserDefaults.standard.set(emptyGroups, forKey: "emptyGroups") }
    }

    var groups: [String] {
        let named = Set(hosts.compactMap { $0.group?.isEmpty == false ? $0.group : nil })
        return named.union(emptyGroups).sorted()
    }

    /// Create an empty group so the user can drag hosts into it.
    func createGroup(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !groups.contains(trimmed) else { return }
        emptyGroups.append(trimmed)
    }

    /// Delete a group but keep its machines — they fall back to Ungrouped.
    func deleteGroup(_ name: String) {
        let aliases = hosts(inGroup: name).map(\.alias)
        if !aliases.isEmpty { setGroup(nil, for: aliases) }
        emptyGroups.removeAll { $0 == name }
    }

    var hasUngrouped: Bool { hosts.contains { ($0.group ?? "").isEmpty } }

    func hosts(inGroup group: String?) -> [Host] {
        hosts.filter { host in
            let g = host.group ?? ""
            return group == nil ? g.isEmpty : g == group
        }.sorted { $0.alias.localizedCaseInsensitiveCompare($1.alias) == .orderedAscending }
    }

    // MARK: - Mutations

    func upsert(_ host: Host, password: String?, originalAlias: String? = nil) {
        if let original = originalAlias, original != host.alias {
            try? keychain.rename(from: original, to: host.alias)
        }
        if let idx = hosts.firstIndex(where: { $0.alias == (originalAlias ?? host.alias) }) {
            hosts[idx] = host
        } else {
            hosts.append(host)
        }
        if host.resolvedAuthMethod == .password, let password, !password.isEmpty {
            do { try keychain.setPassword(password, for: host.alias) }
            catch { lastError = "Keychain: \(error.localizedDescription)" }
        }
        persist()
    }

    func delete(_ host: Host) {
        hosts.removeAll { $0.alias == host.alias }
        try? keychain.deletePassword(for: host.alias)
        statuses[host.alias] = nil
        persist()
    }

    func setGroup(_ group: String?, for aliases: [String]) {
        for alias in aliases {
            if let idx = hosts.firstIndex(where: { $0.alias == alias }) {
                hosts[idx].group = (group?.isEmpty == true) ? nil : group
            }
        }
        persist()
    }

    // MARK: - Connectivity

    func check(_ host: Host) async {
        statuses[host.alias] = .checking
        let result = await checker.check(host)
        statuses[host.alias] = result
    }

    func checkAll() async {
        await withTaskGroup(of: (String, HostStatus).self) { group in
            for host in hosts {
                statuses[host.alias] = .checking
                group.addTask { [checker] in (host.alias, await checker.check(host)) }
            }
            for await (alias, status) in group {
                statuses[alias] = status
            }
        }
    }

    // MARK: - Connecting

    /// Hand the session off to the user's external terminal (Terminal.app / iTerm2).
    func connectExternal(_ host: Host) {
        let launcher = SSHLauncher(terminal: terminalApp)
        do { try launcher.launch(host) }
        catch { lastError = "Could not open terminal: \(error.localizedDescription)" }
    }

    /// The password to auto-fill for a host, if it uses password auth.
    func password(for host: Host) -> String? {
        guard host.resolvedAuthMethod == .password else { return nil }
        return (try? keychain.password(for: host.alias)) ?? nil
    }

    // MARK: - Backup / migration

    /// Bundle every host plus its Keychain password into an encrypted blob.
    func exportBackup(passphrase: String) throws -> Data {
        var passwords: [String: String] = [:]
        for host in hosts where host.resolvedAuthMethod == .password {
            if let pw = try? keychain.password(for: host.alias) { passwords[host.alias] = pw }
        }
        let bundle = BackupBundle(hosts: hosts, passwords: passwords)
        return try BackupService().export(bundle, passphrase: passphrase)
    }

    /// Restore hosts and passwords from an encrypted backup. Existing hosts with
    /// the same alias are overwritten; others are left untouched.
    func importBackup(_ data: Data, passphrase: String) throws -> Int {
        let bundle = try BackupService().import(data, passphrase: passphrase)
        for host in bundle.hosts {
            if let idx = hosts.firstIndex(where: { $0.alias == host.alias }) {
                hosts[idx] = host
            } else {
                hosts.append(host)
            }
            if let pw = bundle.passwords[host.alias] {
                try? keychain.setPassword(pw, for: host.alias)
            }
        }
        persist()
        return bundle.hosts.count
    }

    // MARK: - Search (quick connect)

    func search(_ query: String) -> [Host] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else {
            return hosts.sorted { $0.alias.localizedCaseInsensitiveCompare($1.alias) == .orderedAscending }
        }
        return hosts
            .compactMap { host -> (Host, Int)? in
                guard let score = Self.fuzzyScore(query: q, host: host) else { return nil }
                return (host, score)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// Simple subsequence fuzzy match over alias/hostname/description/group.
    static func fuzzyScore(query: String, host: Host) -> Int? {
        let fields = [
            (host.alias.lowercased(), 100),
            ((host.hostname ?? "").lowercased(), 40),
            ((host.descriptionText ?? "").lowercased(), 30),
            ((host.group ?? "").lowercased(), 20)
        ]
        var best: Int?
        for (field, weight) in fields where !field.isEmpty {
            if field == query { best = max(best ?? 0, weight + 100) }
            else if field.hasPrefix(query) { best = max(best ?? 0, weight + 50) }
            else if field.contains(query) { best = max(best ?? 0, weight + 20) }
            else if isSubsequence(query, of: field) { best = max(best ?? 0, weight) }
        }
        return best
    }

    static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var it = haystack.makeIterator()
        for ch in needle {
            var matched = false
            while let h = it.next() {
                if h == ch { matched = true; break }
            }
            if !matched { return false }
        }
        return true
    }
}
