import Foundation
import Observation
import WirelineCore

/// Central, observable application state. Owns the parsed ssh config, keychain
/// access, live host statuses, and preferences. Everything the UI renders flows
/// from here, and every mutation writes straight back to `~/.ssh/config`.
@Observable
@MainActor
final class HostStore {
    /// The app's store, for sessions that need a host's credentials (they
    /// don't hold the store).
    static weak var current: HostStore?
    private(set) var document: SSHConfig.Document
    /// Mirrored into `PrivacyContext` so the AI masker knows the real addresses.
    private(set) var hosts: [Host] { didSet { PrivacyContext.setHosts(hosts) } }
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
    /// Default cursor shape for new output (programs may still change it, e.g.
    /// vim's insert-mode bar).
    var terminalCursorShape: CursorShape {
        didSet { UserDefaults.standard.set(terminalCursorShape.rawValue, forKey: "terminalCursorShape") }
    }
    /// How visible unfocused split panes stay (Ghostty's unfocused-split-opacity):
    /// 1 = no dimming, lower = recede more.
    var unfocusedSplitOpacity: Double {
        didSet { UserDefaults.standard.set(unfocusedSplitOpacity, forKey: "unfocusedSplitOpacity") }
    }
    /// Space between the terminal grid and the panel edges, in points.
    var terminalPaddingX: Double {
        didSet { UserDefaults.standard.set(terminalPaddingX, forKey: "terminalPaddingX") }
    }
    var terminalPaddingY: Double {
        didSet { UserDefaults.standard.set(terminalPaddingY, forKey: "terminalPaddingY") }
    }
    /// Colour label per group — e.g. red for production — shown on its hosts'
    /// rows, tabs and terminal edge so you always know where you're typing.
    var groupColors: [String: GroupColor] = (UserDefaults.standard.dictionary(forKey: "groupColors") as? [String: String] ?? [:])
        .compactMapValues(GroupColor.init) {
        didSet { UserDefaults.standard.set(groupColors.mapValues(\.rawValue), forKey: "groupColors") }
    }

    func groupColor(forAlias alias: String) -> GroupColor? {
        guard let g = hosts.first(where: { $0.alias == alias })?.group else { return nil }
        return groupColors[g]
    }

    /// When each host was last connected (for the overview page).
    var lastConnected: [String: Date] = (UserDefaults.standard.dictionary(forKey: "lastConnected") as? [String: Date]) ?? [:] {
        didSet { UserDefaults.standard.set(lastConnected, forKey: "lastConnected") }
    }

    /// The terminal renderer for new sessions. Config file only for now
    /// (`terminal-engine`); "ghostty" falls back to SwiftTerm until the
    /// libghostty engine can run (see `TerminalEngineKind.makeEngine`).
    var terminalEngine: TerminalEngineKind {
        didSet { UserDefaults.standard.set(terminalEngine.rawValue, forKey: "terminalEngine") }
    }
    /// Render terminals on the GPU (SwiftTerm's Metal renderer).
    var terminalGPU: Bool {
        didSet { UserDefaults.standard.set(terminalGPU, forKey: "terminalGPU") }
    }
    /// New tabs / windows start in the focused local shell's directory.
    var inheritWorkingDirectory: Bool {
        didSet { UserDefaults.standard.set(inheritWorkingDirectory, forKey: "inheritWorkingDirectory") }
    }
    /// New SSH and local sessions live in the session agent (wireline-agent)
    /// and survive quitting the app (experimental, off by default).
    var sessionAgentEnabled: Bool {
        didSet { UserDefaults.standard.set(sessionAgentEnabled, forKey: "sessionAgent") }
    }
    /// How long the agent keeps a session nobody is attached to; 0 = until it ends.
    var sessionAgentKeepAlive: Double {
        didSet { UserDefaults.standard.set(sessionAgentKeepAlive, forKey: "sessionAgentKeepAlive") }
    }
    /// Ask before closing a tab / pane that's still running a command or agent.
    var confirmCloseRunning: Bool {
        didSet { UserDefaults.standard.set(confirmCloseRunning, forKey: "confirmCloseRunning") }
    }
    /// Notify when a command that ran at least this long finishes while
    /// Wireline isn't frontmost (seconds).
    var notifyCommandAfter: Double {
        didSet { UserDefaults.standard.set(notifyCommandAfter, forKey: "notifyCommandAfter") }
    }
    /// Quick terminal: fraction of the screen height it takes.
    var quickTerminalHeight: Double {
        didSet { UserDefaults.standard.set(quickTerminalHeight, forKey: "quickTerminalHeight") }
    }
    /// Quick terminal hides when it loses focus.
    var quickTerminalAutohide: Bool {
        didSet { UserDefaults.standard.set(quickTerminalAutohide, forKey: "quickTerminalAutohide") }
    }
    /// Follow the system's light / dark appearance with these two themes
    /// (both set = following; nil = use `selectedThemeName` as is).
    var themeForLight: String? {
        didSet { UserDefaults.standard.set(themeForLight, forKey: "themeForLight"); applyAppearanceTheme() }
    }
    var themeForDark: String? {
        didSet { UserDefaults.standard.set(themeForDark, forKey: "themeForDark"); applyAppearanceTheme() }
    }
    var followsSystemAppearance: Bool { themeForLight != nil && themeForDark != nil }

    /// Pick the light / dark theme for the current system appearance.
    func applyAppearanceTheme() {
        // A system-following theme re-resolves its colors on every switch.
        if activeTheme.followsSystem == true { applyActiveTheme() }
        guard let light = themeForLight, let dark = themeForDark else { return }
        let systemDark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        let want = systemDark ? dark : light
        if allThemes.contains(where: { $0.name == want }), selectedThemeName != want { selectedThemeName = want }
    }
    var terminalCursorBlink: Bool {
        didSet { UserDefaults.standard.set(terminalCursorBlink, forKey: "terminalCursorBlink") }
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
        (allThemes.first { $0.name == selectedThemeName } ?? .wirelineDefault).resolvedForSystem()
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
        defer { Self.current = self }
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
        self.terminalCursorShape = UserDefaults.standard.string(forKey: "terminalCursorShape")
            .flatMap(CursorShape.init) ?? .block
        self.terminalCursorBlink = UserDefaults.standard.object(forKey: "terminalCursorBlink") as? Bool ?? true
        self.unfocusedSplitOpacity = UserDefaults.standard.object(forKey: "unfocusedSplitOpacity") as? Double ?? 0.7
        self.terminalGPU = UserDefaults.standard.object(forKey: "terminalGPU") as? Bool ?? true
        self.terminalEngine = UserDefaults.standard.string(forKey: "terminalEngine")
            .flatMap(TerminalEngineKind.init) ?? .ghostty
        self.terminalPaddingX = UserDefaults.standard.object(forKey: "terminalPaddingX") as? Double ?? 16
        self.terminalPaddingY = UserDefaults.standard.object(forKey: "terminalPaddingY") as? Double ?? 10
        self.inheritWorkingDirectory = UserDefaults.standard.object(forKey: "inheritWorkingDirectory") as? Bool ?? true
        self.confirmCloseRunning = UserDefaults.standard.object(forKey: "confirmCloseRunning") as? Bool ?? true
        self.sessionAgentEnabled = UserDefaults.standard.bool(forKey: "sessionAgent")
        self.sessionAgentKeepAlive = UserDefaults.standard.double(forKey: "sessionAgentKeepAlive")
        self.notifyCommandAfter = UserDefaults.standard.object(forKey: "notifyCommandAfter") as? Double ?? 10
        self.quickTerminalHeight = UserDefaults.standard.object(forKey: "quickTerminalHeight") as? Double ?? 0.4
        self.quickTerminalAutohide = UserDefaults.standard.object(forKey: "quickTerminalAutohide") as? Bool ?? true
        self.themeForLight = UserDefaults.standard.string(forKey: "themeForLight")
        self.themeForDark = UserDefaults.standard.string(forKey: "themeForDark")
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
            rdpDocument = RDPHostsFile.normalize(try rdpRepository.load())
            // RDP blocks pasted into ~/.ssh/config are listed too, and move to
            // the RDP file on the next save.
            let rdp = rdpDocument.hosts
            hosts = document.hosts + rdp.filter { r in !document.hosts.contains { $0.alias == r.alias } }
        } catch {
            lastError = "Failed to read ssh config: \(error.localizedDescription)"
        }
    }

    /// SSH hosts only (fleet, batch, files, forwards — what needs a shell).
    var sshHosts: [Host] { hosts.filter { !$0.isRDP } }

    /// `~/.ssh/wireline-rdp-hosts` (see `RDPHostsFile`).
    let rdpRepository = ConfigRepository(url: RDPHostsFile.defaultURL)
    private var rdpDocument = SSHConfig.Document(items: [])

    /// Persist the current host list back to disk, preserving unmanaged
    /// blocks: SSH hosts to `~/.ssh/config`, RDP hosts to their own file.
    private func persist() {
        document = document.replacingHosts(with: sshHosts)
        do {
            try repository.save(document)
        } catch {
            lastError = "Failed to write ssh config: \(error.localizedDescription)"
        }
        let rdp = hosts.filter(\.isRDP)
        // No RDP hosts, no file.
        guard !rdp.isEmpty || FileManager.default.fileExists(atPath: rdpRepository.url.path) else { return }
        rdpDocument = RDPHostsFile.document(for: rdp, from: rdpDocument)
        do {
            try rdpRepository.save(rdpDocument)
        } catch {
            lastError = "Failed to write RDP hosts: \(error.localizedDescription)"
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

    /// What an RDP pane dials: the host, its Keychain password, and its SSH
    /// jump host's password and launch arguments.
    func rdpTarget(for host: Host) -> RDPTarget {
        let via = host.rdpVia.flatMap { v in hosts.first { $0.alias == v } }
        return RDPTarget(host: host, password: password(for: host),
                         viaPassword: via.flatMap { password(for: $0) },
                         viaArgs: via?.launchArgTokens ?? [])
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

    func search(_ query: String) -> [Host] { matches(query).map(\.host) }

    /// Every host search box goes through this — see `HostQuery`.
    func matches(_ query: String) -> [HostSearchMatch] { HostSearch.search(query, in: hosts) }
}

/// Terminal cursor shape; raw values double as the config-file spelling.
enum CursorShape: String, CaseIterable, Sendable {
    case block, bar, underline
}

