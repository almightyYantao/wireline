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
    /// Periodically re-check reachability in the background and notify on changes.
    var backgroundMonitor: Bool {
        didSet {
            UserDefaults.standard.set(backgroundMonitor, forKey: "backgroundMonitor")
            backgroundMonitor ? startMonitoring() : stopMonitoring()
        }
    }
    /// Seconds between background checks.
    var monitorInterval: Double {
        didSet { UserDefaults.standard.set(monitorInterval, forKey: "monitorInterval") }
    }
    private var monitorTask: Task<Void, Never>?
    private var autoBackupTask: Task<Void, Never>?
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
    /// (Kept for the terminal's color path — SwiftTerm reads this directly.)
    var terminalTheme: TerminalTheme? {
        didSet {
            let data = terminalTheme.flatMap { try? JSONEncoder().encode($0) }
            UserDefaults.standard.set(data, forKey: "terminalTheme")
            Palette.shared.update(from: terminalTheme)   // recolor the whole UI
        }
    }

    // MARK: - Themes (skins)

    /// User-created skins (colors + shape + typography + background), persisted
    /// as JSON. Built-ins live in `AppTheme.builtIns`; `allThemes` merges both.
    var customThemes: [AppTheme] = [] {
        didSet {
            let data = try? JSONEncoder().encode(customThemes)
            UserDefaults.standard.set(data, forKey: "customThemes")
            applyActiveTheme()
        }
    }
    /// Name of the selected theme (matched across `allThemes`).
    var selectedThemeName: String = "Wireline" {
        didSet {
            UserDefaults.standard.set(selectedThemeName, forKey: "selectedThemeName")
            applyActiveTheme()
        }
    }

    /// Built-in + custom themes, in one list.
    var allThemes: [AppTheme] { AppTheme.builtIns + customThemes }
    /// The currently selected theme (falls back to the Wireline default).
    var activeTheme: AppTheme {
        allThemes.first { $0.name == selectedThemeName } ?? .wirelineDefault
    }

    /// Push the active theme into the running UI: the terminal color path stays
    /// on `terminalTheme`, while `Palette` carries the full skin (colors + shape
    /// + typography + background). A theme may also set the wallpaper.
    func applyActiveTheme() {
        let t = activeTheme
        let desiredColors: TerminalTheme? = t.usesDefaultColors ? nil : t.colors
        if terminalTheme != desiredColors { terminalTheme = desiredColors }
        Palette.shared.apply(t)
        if let img = t.background.imagePath, !img.isEmpty, terminalBgImagePath != img {
            terminalBgImagePath = img
        }
    }

    /// Save (create or overwrite) a custom theme by name and select it.
    func upsertTheme(_ theme: AppTheme) {
        var t = theme
        t.isBuiltIn = false
        if let i = customThemes.firstIndex(where: { $0.id == t.id }) {
            customThemes[i] = t
        } else if let i = customThemes.firstIndex(where: { $0.name == t.name }) {
            customThemes[i] = t
        } else {
            customThemes.append(t)
        }
        selectedThemeName = t.name
    }

    /// Delete a custom theme; if it was selected, fall back to the default.
    func deleteTheme(_ theme: AppTheme) {
        customThemes.removeAll { $0.id == theme.id }
        if selectedThemeName == theme.name { selectedThemeName = "Wireline" }
    }

    /// A unique "Custom", "Custom 2", … name for a new theme.
    func uniqueThemeName(_ base: String) -> String {
        let names = Set(allThemes.map(\.name))
        if !names.contains(base) { return base }
        var n = 2
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
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
        self.backgroundMonitor = UserDefaults.standard.object(forKey: "backgroundMonitor") as? Bool ?? false
        self.monitorInterval = UserDefaults.standard.object(forKey: "monitorInterval") as? Double ?? 60
        self.useBuiltInTerminal = UserDefaults.standard.object(forKey: "useBuiltInTerminal") as? Bool ?? true
        self.terminalOpacity = UserDefaults.standard.object(forKey: "terminalOpacity") as? Double ?? 1.0
        self.terminalBgImagePath = UserDefaults.standard.string(forKey: "terminalBgImagePath")
        self.terminalFontName = UserDefaults.standard.string(forKey: "terminalFontName")
        self.terminalFontSize = UserDefaults.standard.object(forKey: "terminalFontSize") as? Double ?? 13
        self.terminalTheme = UserDefaults.standard.data(forKey: "terminalTheme")
            .flatMap { try? JSONDecoder().decode(TerminalTheme.self, from: $0) }
        self.customThemes = UserDefaults.standard.data(forKey: "customThemes")
            .flatMap { try? JSONDecoder().decode([AppTheme].self, from: $0) } ?? []
        self.document = SSHConfig.Document(items: [])
        self.hosts = []

        // Resolve the selected theme. Migrate legacy users who only had a saved
        // `terminalTheme`: adopt its name, and if it was an imported scheme not in
        // the built-in list, fold it into the custom library so it stays editable.
        if let saved = UserDefaults.standard.string(forKey: "selectedThemeName") {
            self.selectedThemeName = saved
        } else if let legacy = terminalTheme {
            self.selectedThemeName = legacy.name
            let known = AppTheme.builtIns.map(\.name) + customThemes.map(\.name)
            if !known.contains(legacy.name) {
                self.customThemes.append(AppTheme(name: legacy.name, colors: legacy))
            }
        } else {
            self.selectedThemeName = "Wireline"
        }
        Palette.shared.apply(activeTheme)   // recolor + restyle UI from saved skin
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

    // MARK: - Background monitoring

    func startMonitoring() {
        guard backgroundMonitor, monitorTask == nil else { return }
        Notifier.requestAuthorization()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval = self?.monitorInterval ?? 60
                try? await Task.sleep(for: .seconds(max(15, interval)))
                if Task.isCancelled { break }
                await self?.monitorPass()
            }
        }
    }

    func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    // MARK: - Scheduled WebDAV backup

    /// (Re)start the auto-backup timer. Only runs when WebDAV is configured and
    /// a passphrase has been saved. Call after toggling the setting.
    func startAutoBackup() {
        autoBackupTask?.cancel()
        autoBackupTask = nil
        let cfg = WebDAVConfig.shared
        guard cfg.autoBackup, cfg.isConfigured, !cfg.savedPassphrase.isEmpty else { return }
        autoBackupTask = Task { [weak self] in
            while !Task.isCancelled {
                let hours = max(1, WebDAVConfig.shared.autoIntervalHours)
                try? await Task.sleep(for: .seconds(hours * 3600))
                if Task.isCancelled { break }
                await self?.runAutoBackup()
            }
        }
    }

    func runAutoBackup() async {
        let cfg = WebDAVConfig.shared
        guard cfg.autoBackup, cfg.isConfigured, !cfg.savedPassphrase.isEmpty,
              let data = try? exportBackup(passphrase: cfg.savedPassphrase) else { return }
        let client = WebDAVClient(config: cfg)
        await client.ensureCollection()
        try? await client.upload(data)
    }

    /// Re-check all hosts and notify on online↔offline transitions.
    /// Ask the AI for likely causes when a host drops off, and notify. The host
    /// is unreachable, so this is advisory (causes + what to check).
    private static func postAttribution(for host: Host) async {
        let loc = Localizer.shared
        let client = AIClient(config: AIConfig.shared)
        let model = AIConfig.shared.hasFastModel ? AIConfig.shared.activeModelFast : nil
        let sys = "你是运维值班助手。某台主机刚变为不可达（TCP 连接失败）。用中文给出最可能的 2-3 个原因和应立即检查的项，一句话一条，简短，不要客套。"
        let msg = AIMessage(role: .user, content: "主机：\(host.alias)（\(host.connectionSummary)）刚刚离线。可能原因与排查建议：")
        var text = ""
        do { for try await d in client.stream(system: sys, messages: [msg], model: model) { text += d } }
        catch { return }
        let note = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else { return }
        Notifier.post(title: loc("AI 归因 · \(host.alias)", "AI triage · \(host.alias)"),
                      body: String(note.prefix(400)))
    }

    private func monitorPass() async {
        let before = statuses
        await checkAll()
        let loc = Localizer.shared
        for host in hosts {
            let old = before[host.alias]
            switch (old, statuses[host.alias]) {
            case (.online, .offline):
                Notifier.post(title: loc("主机离线", "Host offline"),
                              body: "\(host.alias) · \(host.connectionSummary)")
                if AIConfig.shared.enabled, AIConfig.shared.alertAttribution {
                    Task { await Self.postAttribution(for: host) }
                }
            case (.offline, .online):
                Notifier.post(title: loc("主机恢复", "Host back online"),
                              body: "\(host.alias) · \(host.connectionSummary)")
            default: break
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

    /// The password to feed to `sudo` for an auto-sudo host. Unlike `password`,
    /// this is returned regardless of the login auth method — key-auth hosts have
    /// no login password but still need one for `sudo -i`.
    func sudoPassword(for host: Host) -> String? {
        guard host.autoSudo else { return nil }
        return (try? keychain.password(for: host.alias)) ?? nil
    }

    // MARK: - Backup / migration

    /// Supplies the current to-do list to include in a backup, and restores an
    /// imported one. Wired up in `WirelineApp` where both stores exist, so the
    /// backup layer stays decoupled from `TodoStore`. Defaults are no-ops, so
    /// backup works even before they're set.
    var currentTodos: () -> [Todo] = { [] }
    var restoreTodos: ([Todo]) -> Void = { _ in }

    /// Bundle every host plus its Keychain password into an encrypted blob.
    func exportBackup(passphrase: String) throws -> Data {
        var passwords: [String: String] = [:]
        for host in hosts where host.resolvedAuthMethod == .password {
            if let pw = try? keychain.password(for: host.alias) { passwords[host.alias] = pw }
        }
        let bundle = BackupBundle(hosts: hosts, passwords: passwords, todos: currentTodos())
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
        if !bundle.todos.isEmpty { restoreTodos(bundle.todos) }
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
