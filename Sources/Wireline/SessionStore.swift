import AppKit
import Observation
import SwiftTerm
import WirelineCore

/// What a terminal session runs.
enum SessionKind {
    /// An SSH connection to a host alias.
    case ssh(alias: String, password: String?, autoSudo: Bool, args: [String])
    /// An interactive SFTP file-transfer session to a host alias.
    case sftp(alias: String, password: String?, args: [String])
    /// A plain local login shell (the user's `$SHELL`, e.g. zsh).
    case localShell
}

/// One live in-app terminal session. Owns the AppKit terminal view for its whole
/// lifetime so SwiftUI can embed/re-embed it without ever tearing down the PTY.
@Observable
@MainActor
final class TerminalSession: Identifiable {
    let id = UUID()
    let kind: SessionKind
    var title: String
    /// Name of the full-screen editor currently running (`"vim"`), else nil.
    /// Drives the vim cheat-sheet overlay.
    var activeEditor: String?

    /// Whether a command / process is currently running in this session (the shell
    /// prompt has gone away). Drives the "running…" badge shown on a backgrounded
    /// tab. Updated from the terminal view's prompt heuristic.
    var isBusy = false

    /// Recent terminal output (ANSI-stripped) for AI context.
    var recentOutput: String { terminalView.recentClean }

    /// Insert text into the terminal WITHOUT a trailing newline, so the user
    /// reviews an AI-suggested command and presses Return themselves.
    func insertIntoTerminal(_ text: String) { terminalView.send(txt: text) }

    /// Insert text AND execute it (adds a trailing newline). Only ever called
    /// from an explicit user tap on "Run".
    func runInTerminal(_ text: String) { terminalView.send(txt: text + "\n") }

    /// Run a command out-of-band and capture its combined output — for the AI
    /// agent mode. SSH sessions reuse the ControlMaster socket (no re-auth, no
    /// disturbance to the interactive terminal); local shells run via zsh.
    func runCapturing(_ command: String) async -> String {
        switch kind {
        case .ssh(let alias, _, _, _):
            return await Self.exec(["/usr/bin/ssh", "-S", controlSocket, "-o", "BatchMode=yes", alias, command])
        case .localShell:
            return await Self.exec(["/bin/zsh", "-lc", command])
        case .sftp:
            return "(SFTP 会话不支持执行命令)"
        }
    }

    /// Run a command IN the visible terminal (so the user sees it happen) and
    /// capture its output by bracketing it with unique start/end markers, then
    /// polling the terminal's clean output buffer for them.
    func runInTerminalCapturing(_ command: String, timeout: TimeInterval = 30) async -> String {
        let tag = String(UUID().uuidString.prefix(6))
        let start = "WLc\(tag)START", end = "WLc\(tag)END"
        // Markers print on their own lines; `$?` captures the command's exit code.
        terminalView.send(txt: "printf '%s\\n' \(start); \(command); printf '%s:%d\\n' \(end) $?\n")

        let deadline = Date().addingTimeInterval(timeout)
        let startRE = try? NSRegularExpression(pattern: "(?m)^\(start)$")
        let endRE = try? NSRegularExpression(pattern: "(?m)^\(end):(\\d+)$")
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(200))
            let buf = terminalView.recentClean
            let ns = buf as NSString
            guard let sM = startRE?.firstMatch(in: buf, range: NSRange(location: 0, length: ns.length)),
                  let eM = endRE?.firstMatch(in: buf, range: NSRange(location: 0, length: ns.length)),
                  eM.range.location > sM.range.location else { continue }
            let outStart = sM.range.location + sM.range.length
            let out = ns.substring(with: NSRange(location: outStart, length: eM.range.location - outStart))
            let code = ns.substring(with: eM.range(at: 1))
            let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "(无输出，退出码 \(code))" : trimmed + "\n(退出码 \(code))"
        }
        return "(执行超时)"
    }

    nonisolated private static func exec(_ argv: [String], timeout: TimeInterval = 30) async -> String {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: argv[0])
                p.arguments = Array(argv.dropFirst())
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch {
                    cont.resume(returning: "(执行失败: \(error.localizedDescription))"); return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if p.isRunning { p.terminate() }
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                let text = String(data: data, encoding: .utf8) ?? ""
                cont.resume(returning: text.isEmpty ? "(无输出，退出码 \(p.terminationStatus))" : text)
            }
        }
    }
    /// SSH host alias, or "" for a local shell.
    let alias: String
    let startedAt = Date()
    private(set) var isRunning = true
    let terminalView: WirelineTerminalView
    /// Live remote vitals (SSH sessions only), polled over the ControlMaster socket.
    let stats = StatsMonitor()

    weak var store: SessionStore?
    private var askpassURL: URL?
    /// SSH ControlMaster socket path, for out-of-band stats polling.
    private let controlSocket = NSTemporaryDirectory() + "wl-\(UUID().uuidString.prefix(8)).sock"

    init(kind: SessionKind, title: String) {
        self.kind = kind
        self.title = title
        switch kind {
        case .ssh(let a, _, _, _): self.alias = a
        case .sftp(let a, _, _): self.alias = a
        case .localShell: self.alias = ""
        }
        let frame = CGRect(x: 0, y: 0, width: 800, height: 480)
        switch kind {
        case .ssh(_, let password, let autoSudo, _):
            self.terminalView = WirelineTerminalView(frame: frame, password: password, autoSudo: autoSudo)
        case .sftp, .localShell:
            self.terminalView = WirelineTerminalView(frame: frame, password: nil, autoSudo: false)
        }
        terminalView.onEditorChange = { [weak self] editor in
            self?.activeEditor = editor
        }
        terminalView.onCommandFinished = { [weak self] elapsed in
            guard let self else { return }
            // Only ping when the app isn't frontmost — if you're watching, you
            // already see the prompt return.
            guard !NSApp.isActive else { return }
            let loc = Localizer.shared
            Notifier.post(title: loc.t("命令完成 · \(self.title)", "Command finished · \(self.title)"),
                          body: loc.t("耗时 \(Int(elapsed)) 秒", "took \(Int(elapsed))s"))
        }
        terminalView.onBusyChange = { [weak self] busy, elapsed in
            guard let self else { return }
            // Local shells use reliable foreground-process polling (see
            // `pollForeground`); the output heuristic is only trustworthy enough
            // for SSH/SFTP, where the local foreground process is always `ssh`.
            if case .localShell = self.kind { return }
            self.applyBusy(busy, elapsed: elapsed)
        }
    }

    /// Apply a busy-state change: update the badge and, when a run finishes in a
    /// tab you've switched away from (app still frontmost — the away-from-app case
    /// is handled by `onCommandFinished`), ping so you know it's done.
    private func applyBusy(_ busy: Bool, elapsed: TimeInterval) {
        guard busy != isBusy else { return }
        isBusy = busy
        guard !busy, elapsed >= 5, NSApp.isActive else { return }
        let inActiveTab = store?.activeTab?.leafID(for: id) != nil
        guard !inActiveTab else { return }
        let loc = Localizer.shared
        Notifier.post(title: loc.t("运行完成 · \(title)", "Finished · \(title)"),
                      body: loc.t("该标签的任务已结束（耗时 \(Int(elapsed)) 秒）",
                                  "This tab's task is done (\(Int(elapsed))s)"))
    }

    // MARK: - Foreground-process polling (local shells)

    private var busyTimer: DispatchSourceTimer?
    private var busyStartedAt: Date?

    /// Poll the PTY's foreground process group for local shells: if it isn't the
    /// login shell itself, a command is running. Reliable and prompt-agnostic.
    private func startBusyPolling() {
        guard case .localShell = kind else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 0.8, repeating: 0.8)
        t.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.pollForeground() }
        }
        t.resume()
        busyTimer = t
    }

    private func pollForeground() {
        guard let proc = terminalView.process, proc.childfd >= 0 else { return }
        let pgid = tcgetpgrp(proc.childfd)
        let running = pgid > 0 && pgid != proc.shellPid
        if running, !isBusy {
            busyStartedAt = Date()
            applyBusy(true, elapsed: 0)
        } else if !running, isBusy {
            let elapsed = busyStartedAt.map { Date().timeIntervalSince($0) } ?? 0
            applyBusy(false, elapsed: elapsed)
            busyStartedAt = nil
        }
    }

    func start() {
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        // Preserve the user's locale so remote/local shells render UTF-8 correctly.
        if let lang = ProcessInfo.processInfo.environment["LANG"] { env.append("LANG=\(lang)") }

        switch kind {
        case .ssh(let alias, let password, _, let extraArgs):
            // For password hosts, feed the password to ssh deterministically via
            // an askpass helper (OpenSSH SSH_ASKPASS + REQUIRE=force) instead of
            // typing it into the PTY — no prompt-scraping, no dropped characters.
            if let password, !password.isEmpty, let script = Self.makeAskpassScript() {
                askpassURL = script
                env.append("SSH_ASKPASS=\(script.path)")
                env.append("SSH_ASKPASS_REQUIRE=force")
                env.append("WIRELINE_ASKPASS_PW=\(password)")
            }
            // Enable ControlMaster so a side channel can poll server stats over
            // the same authenticated connection (no re-auth, no PTY interference).
            let args = [
                "-o", "StrictHostKeyChecking=accept-new",
                "-o", "ControlMaster=auto",
                "-o", "ControlPath=\(controlSocket)",
                "-o", "ControlPersist=30"
            ] + extraArgs + [alias]
            terminalView.startProcess(executable: "/usr/bin/ssh", args: args, environment: env)
            stats.start(socket: controlSocket, alias: alias)
        case .sftp(let alias, let password, let extraArgs):
            if let password, !password.isEmpty, let script = Self.makeAskpassScript() {
                askpassURL = script
                env.append("SSH_ASKPASS=\(script.path)")
                env.append("SSH_ASKPASS_REQUIRE=force")
                env.append("WIRELINE_ASKPASS_PW=\(password)")
            }
            terminalView.startProcess(
                executable: "/usr/bin/sftp",
                args: ["-o", "StrictHostKeyChecking=accept-new"] + extraArgs + [alias],
                environment: env
            )
        case .localShell:
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            let name = (shell as NSString).lastPathComponent
            // Launch as a login shell (leading '-') so ~/.zprofile & ~/.zshrc load,
            // which is what gives the user their familiar prompt, theme, and colors.
            terminalView.startProcess(
                executable: shell,
                args: ["-l"],
                environment: env,
                execName: "-\(name)",
                // Start in the user's home, not the app's cwd (which is `/`).
                currentDirectory: FileManager.default.homeDirectoryForCurrentUser.path
            )
            startBusyPolling()
        }
    }

    /// Whether this session is recording its output to a log file, and where.
    var isLogging = false
    var logURL: URL?

    /// Start or stop logging this session's output to a file.
    func toggleLogging() {
        if isLogging {
            terminalView.stopLogging()
            isLogging = false
        } else {
            let label = alias.isEmpty ? "local" : alias
            logURL = terminalView.startLogging(label: label)
            isLogging = logURL != nil
        }
    }

    func terminate() {
        guard isRunning else { return }
        isRunning = false
        busyTimer?.cancel()
        busyTimer = nil
        stats.stop()
        terminalView.stopLogging()
        isLogging = false
        terminalView.terminate()
        try? FileManager.default.removeItem(atPath: controlSocket)
        if let askpassURL { try? FileManager.default.removeItem(at: askpassURL) }
        askpassURL = nil
    }

    /// Write a throwaway askpass script that prints the password from an env var.
    /// The password lives only in the ssh child's environment, not on disk.
    private static func makeAskpassScript() -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wireline-askpass-\(UUID().uuidString).sh")
        let script = "#!/bin/sh\nprintf '%s\\n' \"$WIRELINE_ASKPASS_PW\"\n"
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                  ofItemAtPath: url.path)
            return url
        } catch {
            return nil
        }
    }
}

/// A restorable description of an open session — enough to reopen it (and
/// reconnect) on the next launch. Live PTY state can't be frozen, so we persist
/// what the session *is*, then re-establish it.
struct SessionSnapshot: Codable, Sendable {
    enum Kind: String, Codable { case ssh, sftp, local }
    var kind: Kind
    var alias: String
    var title: String
}

/// How the terminal area is split into panes.
enum SplitAxis { case none, horizontal, vertical }

/// Tracks all open terminal sessions. Shared across the app so a session opened
/// from Quick Connect or the menu bar shows up wherever windows are hosted.
@Observable
@MainActor
final class SessionStore {
    /// All live sessions (the terminal/PTY objects).
    private(set) var sessions: [TerminalSession] = []

    /// The tab bar: each tab is a pane group — a single session (leaf) or a
    /// split tree of sessions. Dragging one tab onto another's pane merges them
    /// into one tab; detaching a pane splits it back out into its own tab.
    private(set) var tabs: [PaneNode] = []
    /// Which tab (pane group) is currently shown.
    var activeTabID: UUID?
    /// The focused session within the active tab (drives which pane is highlighted
    /// and where the keyboard goes).
    var activeID: UUID?

    var activeTab: PaneNode? { tabs.first { $0.id == activeTabID } }

    private static let persistKey = "wireline.openSessions"
    /// Guards one-time restore so re-appearing windows don't reopen duplicates.
    private var didRestore = false

    /// Open an SSH session for a host. `password` is fetched from the Keychain
    /// by the caller (nil for key auth).
    @discardableResult
    func open(host: Host, password: String?) -> UUID {
        add(TerminalSession(
            kind: .ssh(alias: host.alias, password: password, autoSudo: host.autoSudo, args: host.launchArgTokens),
            title: host.alias))
    }

    /// Open an interactive SFTP file-transfer session for a host.
    @discardableResult
    func openSFTP(host: Host, password: String?) -> UUID {
        add(TerminalSession(kind: .sftp(alias: host.alias, password: password, args: host.launchArgTokens),
                            title: "📁 \(host.alias)"))
    }

    /// Open a plain local shell session.
    @discardableResult
    func openLocalShell() -> UUID {
        add(TerminalSession(kind: .localShell, title: "Local Shell"))
    }

    private func add(_ session: TerminalSession) -> UUID {
        let id = spawn(session)
        // Every new session starts as its own single-pane tab.
        let tab = PaneNode.makeLeaf(id)
        tabs.append(tab)
        activeTabID = tab.id
        activeID = id
        persist()
        return id
    }

    /// Register a session and start its PTY, WITHOUT creating a tab for it —
    /// `add` then wraps it in a leaf tab.
    private func spawn(_ session: TerminalSession) -> UUID {
        session.store = self
        let id = session.id
        session.terminalView.onCloseRequested = { [weak self] in self?.close(id) }
        sessions.append(session)
        session.start()
        return id
    }

    /// The tab (pane group) containing `session`, if any.
    private func tabIndex(containing session: UUID) -> Int? {
        tabs.firstIndex { $0.leafID(for: session) != nil }
    }

    // MARK: - Split (tab groups)

    /// Merge the dragged tab into the target pane: remove the dragged tab and
    /// splice its whole pane node into the target tab, splitting `targetLeaf`
    /// along `edge`. The two tabs become one. Dropping a tab onto a pane inside
    /// the SAME tab is ignored.
    func mergeTab(_ draggedTabID: UUID, ontoLeaf targetLeaf: UUID, edge: PaneEdge) {
        guard let di = tabs.firstIndex(where: { $0.id == draggedTabID }),
              let ti = tabs.firstIndex(where: { $0.contains(leaf: targetLeaf) }),
              di != ti else { return }
        let draggedNode = tabs[di]
        tabs.remove(at: di)
        let target = di < ti ? ti - 1 : ti
        let e: PaneEdge = (edge == .center) ? .trailing : edge
        tabs[target] = tabs[target].splitting(leaf: targetLeaf, insertNode: draggedNode, edge: e)
        activeTabID = tabs[target].id
        activeID = draggedNode.sessionIDs.first ?? activeID
    }

    /// Detach a pane (session) from its multi-pane tab into its own new tab.
    func detachPaneToTab(_ session: UUID) {
        guard let ti = tabIndex(containing: session) else { return }
        // Only meaningful when the tab actually has more than one pane.
        guard tabs[ti].sessionIDs.count > 1 else { return }
        if let remaining = tabs[ti].removingSession(session) { tabs[ti] = remaining }
        let tab = PaneNode.makeLeaf(session)
        tabs.append(tab)
        activeTabID = tab.id
        activeID = session
    }

    /// Focus a session from a tab click / keyboard: activate its tab and pane.
    func focusSession(_ id: UUID) {
        guard let ti = tabIndex(containing: id) else { return }
        activeTabID = tabs[ti].id
        activeID = id
    }

    /// Cycle keyboard focus to the next/previous pane within the active tab.
    func focusNextPane() { cyclePane(+1) }
    func focusPreviousPane() { cyclePane(-1) }

    private func cyclePane(_ delta: Int) {
        guard let tab = activeTab else { return }
        let ids = tab.sessionIDs
        guard ids.count > 1 else { return }
        let cur = ids.firstIndex(of: activeID ?? UUID()) ?? 0
        activeID = ids[(cur + delta + ids.count) % ids.count]
    }

    /// Focus a whole tab (its first pane).
    func focusTab(_ tabID: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        activeTabID = tabID
        if tab.leafID(for: activeID ?? UUID()) == nil { activeID = tab.sessionIDs.first }
    }

    /// Rename a tab; the custom title is persisted and restored.
    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let s = session(id) else { return }
        s.title = trimmed
        persist()
    }

    func session(_ id: UUID) -> TerminalSession? {
        sessions.first { $0.id == id }
    }

    var activeSession: TerminalSession? {
        guard let activeID else { return nil }
        return session(activeID)
    }

    /// Focus the Nth tab (1-based), for ⌘1…⌘9. No-op if out of range.
    func selectIndex(_ n: Int) {
        guard tabs.indices.contains(n - 1) else { return }
        focusTab(tabs[n - 1].id)
    }

    /// Cycle the active tab by `delta` (+1 next, -1 previous), wrapping around.
    func focusAdjacentTab(_ delta: Int) {
        guard !tabs.isEmpty else { return }
        let cur = tabs.firstIndex { $0.id == activeTabID } ?? 0
        focusTab(tabs[(cur + delta + tabs.count) % tabs.count].id)
    }

    /// Move the active tab left/right in the tab bar by `delta`. No-op at the ends.
    func moveActiveTab(_ delta: Int) {
        guard let cur = tabs.firstIndex(where: { $0.id == activeTabID }) else { return }
        let dest = cur + delta
        guard tabs.indices.contains(dest) else { return }
        tabs.swapAt(cur, dest)
    }

    func close(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].terminate()
        sessions.remove(at: index)
        // Remove the session from its tab; drop the tab if it becomes empty.
        if let ti = tabIndex(containing: id) {
            if let remaining = tabs[ti].removingSession(id) { tabs[ti] = remaining }
            else { tabs.remove(at: ti) }
        }
        // Re-derive the active tab / session.
        if !tabs.contains(where: { $0.id == activeTabID }) {
            activeTabID = tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id
        }
        if let at = activeTab {
            if at.leafID(for: activeID ?? UUID()) == nil { activeID = at.sessionIDs.first }
        } else {
            activeID = nil
        }
        persist()
    }

    func closeAll() {
        sessions.forEach { $0.terminate() }
        sessions.removeAll()
        tabs.removeAll()
        activeTabID = nil
        activeID = nil
        persist()
    }

    /// Focus the active session's terminal so keystrokes go straight to the PTY —
    /// used by the "focus terminal" shortcut after the command bar / AI panel.
    func focusActiveTerminal() {
        guard let term = activeSession?.terminalView else { return }
        term.window?.makeFirstResponder(term)
    }

    /// Send the same text to every open session's terminal (the broadcast bar).
    func broadcast(_ text: String) {
        for s in sessions { s.terminalView.send(txt: text) }
    }


    // MARK: - Persistence / restore

    private func persist() {
        let snaps = sessions.map(snapshot(of:))
        if let data = try? JSONEncoder().encode(snaps) {
            UserDefaults.standard.set(data, forKey: Self.persistKey)
        }
    }

    /// A restorable description of one live session.
    private func snapshot(of s: TerminalSession) -> SessionSnapshot {
        let kind: SessionSnapshot.Kind
        switch s.kind {
        case .ssh:        kind = .ssh
        case .sftp:       kind = .sftp
        case .localShell: kind = .local
        }
        return SessionSnapshot(kind: kind, alias: s.alias, title: s.title)
    }

    /// Reopen (and reconnect) the sessions that were open at last quit. Runs once.
    /// SSH/SFTP sessions resolve their password from the Keychain via `store`.
    func restoreIfNeeded(store: HostStore) {
        guard !didRestore else { return }
        didRestore = true
        guard let data = UserDefaults.standard.data(forKey: Self.persistKey),
              let snaps = try? JSONDecoder().decode([SessionSnapshot].self, from: data) else { return }
        for snap in snaps {
            switch snap.kind {
            case .ssh:
                if let h = store.hosts.first(where: { $0.alias == snap.alias }) {
                    let id = open(host: h, password: store.password(for: h))
                    session(id)?.title = snap.title
                }
            case .sftp:
                if let h = store.hosts.first(where: { $0.alias == snap.alias }) {
                    let id = openSFTP(host: h, password: store.password(for: h))
                    session(id)?.title = snap.title
                }
            case .local:
                let id = openLocalShell()
                session(id)?.title = snap.title
            }
        }
        persist()
    }
}
