import AppKit
import SystemConfiguration
import Observation
import SwiftTerm
import WirelineCore

/// What a terminal session runs.
enum SessionKind {
    /// An SSH connection to a host alias. `password` is the login password (nil
    /// for key auth); `sudoPassword` is fed to `sudo` for auto-sudo hosts and is
    /// available even on key-auth hosts (which have no login password).
    case ssh(alias: String, password: String?, sudoPassword: String?, autoSudo: Bool, args: [String])
    /// An interactive SFTP file-transfer session to a host alias.
    case sftp(alias: String, password: String?, args: [String])
    /// A plain local login shell (the user's `$SHELL`, e.g. zsh).
    case localShell
    /// A Windows remote desktop (FreeRDP), shown by `RDPView` instead of a terminal.
    case rdp(alias: String, target: RDPTarget)
}

/// One live in-app terminal session. Owns the AppKit terminal view for its whole
/// lifetime so SwiftUI can embed/re-embed it without ever tearing down the PTY.
/// Coarse connection lifecycle of a session, for the status indicator.
enum ConnectionState: Equatable {
    case connecting     // process spawned, waiting for the server's first byte
    case connected      // server is responding
    case disconnected   // process exited / link dropped / closed
}

@Observable
@MainActor
final class TerminalSession: Identifiable {
    let id = UUID()
    let kind: SessionKind
    var title: String
    /// The session's current working directory (absolute path), as reported by
    /// the shell via OSC 7. Drives the tab tooltip (full path) and — for local
    /// shells — the tab title (its basename). Nil until the shell first reports.
    var currentDirectory: String?
    /// True once the user has renamed this tab by hand, which pins the title so
    /// automatic directory-tracking (see `applyReportedDirectory`) leaves it alone.
    var isManuallyRenamed = false

    /// Drives the prompt-inline AI command flow (⌘; or a `# …` request line).
    let inlineAI = InlineAIController()
    /// Name of the full-screen editor currently running (`"vim"`), else nil.
    /// Drives the vim cheat-sheet overlay.
    var activeEditor: String?
    /// `activeEditor`, unless a local shell's real foreground program says
    /// otherwise (the byte-stream guess is only needed through `ssh`).
    var shownEditor: String? {
        guard let fg = foregroundName?.lowercased(),
              !["ssh", "mosh", "vim", "vi", "nvim", "view", "vimdiff", "nvimdiff"].contains(fg)
        else { return activeEditor }
        return nil
    }

    /// Whether a command / process is currently running in this session (the shell
    /// prompt has gone away). Drives the "running…" badge shown on a backgrounded
    /// tab. Updated from the terminal view's prompt heuristic.
    var isBusy = false
    /// Name of the program in the foreground of a local shell (`vim`, `node`,
    /// `claude`), nil at the prompt. Picks the pane / tab icon.
    var foregroundName: String?
    /// A coding agent (Claude Code, Codex …) running in this pane, and what
    /// it's doing — the island's tracker, mirrored here (nil: no agent). An
    /// agent sitting at its prompt isn't "running" even though its process is
    /// in the foreground.
    var agentState: CodingAgentTracker.State?

    /// Coarse connection lifecycle for the animated status indicator: dialing
    /// (`connecting`) → server responding (`connected`) → process gone
    /// (`disconnected`, whether by logout, a dropped link, or explicit close).
    var connectionState: ConnectionState = .connecting

    /// Whether this session produced output while it was NOT the visible tab —
    /// drives the "new output" dot on a backgrounded tab. Cleared when you switch
    /// to it.
    var hasUnread = false

    /// Recent terminal output (ANSI-stripped) for AI context.
    var recentOutput: String { io.recentClean }

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
        case .ssh(let alias, _, _, _, _):
            return await Self.exec(["/usr/bin/ssh", "-S", controlSocket, "-o", "BatchMode=yes", alias, command],
                                   timeout: 1800, useAgent: true)
        case .localShell:
            return await Self.exec(["/bin/zsh", "-lc", command], timeout: 1800)
        case .sftp:
            return "(SFTP 会话不支持执行命令)"
        case .rdp:
            return "(远程桌面会话不支持执行命令)"
        }
    }

    /// Run a command IN the visible terminal (so the user sees it happen) and
    /// capture its output by bracketing it with unique start/end markers, then
    /// polling the terminal's clean output buffer for them.
    /// `idleTimeout` is time with NO new terminal output (a truly wedged shell);
    /// `maxTimeout` is a hard ceiling. A long-but-active command (e.g. `docker
    /// build`) keeps producing output, so it never trips the idle timer.
    func runInTerminalCapturing(_ command: String,
                                idleTimeout: TimeInterval = 120,
                                maxTimeout: TimeInterval = 3600) async -> String {
        let tag = String(UUID().uuidString.prefix(6))
        let start = "WLc\(tag)START", end = "WLc\(tag)END"
        // Markers print on their own lines; `$?` captures the command's exit code.
        terminalView.send(txt: "printf '%s\\n' \(start); \(command); printf '%s:%d\\n' \(end) $?\n")

        let hardDeadline = Date().addingTimeInterval(maxTimeout)
        var idleDeadline = Date().addingTimeInterval(idleTimeout)
        var lastBuf = ""
        let startRE = try? NSRegularExpression(pattern: "(?m)^\(start)$")
        let endRE = try? NSRegularExpression(pattern: "(?m)^\(end):(\\d+)$")
        while Date() < hardDeadline, Date() < idleDeadline {
            try? await Task.sleep(for: .milliseconds(200))
            let buf = io.recentClean
            if buf != lastBuf { lastBuf = buf; idleDeadline = Date().addingTimeInterval(idleTimeout) }
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

    /// `useAgent`: if the ControlMaster has gone away, ssh reconnects on its own,
    /// so it must be able to reach Wireline's agent for protected keys.
    nonisolated private static func exec(_ argv: [String], timeout: TimeInterval = 30,
                                         useAgent: Bool = false) async -> String {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: argv[0])
                p.arguments = Array(argv.dropFirst())
                if useAgent, SSHAgentEnvironment.socketPath != nil {
                    var env = ProcessInfo.processInfo.environment
                    SSHAgentEnvironment.apply(to: &env)
                    p.environment = env
                }
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
    /// The renderer — SwiftTerm, or libghostty (`terminal-engine`); see `TerminalEngine`.
    let terminalView: any TerminalEngine
    /// The PTY and the byte-stream logic around it (engine-independent).
    let io: TerminalIO
    /// Live remote vitals (SSH sessions only), polled over the ControlMaster socket.
    let stats = StatsMonitor()
    /// The connect panel's view of the current ssh attempt (SSH sessions only).
    let connect = ConnectProgress()
    /// The remote desktop (RDP sessions only). The pane shows its view; the
    /// terminal below is never launched.
    let rdp: RDPSession?

    /// What takes keyboard focus for this pane.
    var focusView: NSView { rdp?.view ?? terminalView }

    weak var store: SessionStore?
    private var askpassURL: URL?
    /// SSH ControlMaster socket path, for out-of-band stats polling. A split
    /// opened from an SSH pane reuses its source's socket: the new `ssh` rides
    /// the already-authenticated connection (no password / Touch ID, instant).
    /// ControlPersist keeps that master alive in the background, so closing the
    /// source pane doesn't take the split down with it.
    let controlSocket: String
    /// Only the session that created the socket deletes it.
    private let ownsControlSocket: Bool
    /// Where a local shell starts (a split inherits its source's directory).
    private let startDirectory: String?

    /// Stable key for this session's persisted scrollback file (survives relaunch
    /// via the snapshot). Defaults to the session id; overwritten on restore.
    var scrollbackKey: String = ""
    /// Raw output from a previous run, fed into the terminal on `start()` so the
    /// history reappears as if the app was never closed.
    var pendingScrollback: Data?

    /// Attaching to a session the agent already holds (restored at launch)
    /// rather than starting a process.
    private let attachesToAgent: Bool

    /// New SSH and local sessions live in the session agent when it's on —
    /// libghostty only (restoring needs its snapshot support).
    private static func usesAgent(_ kind: SessionKind, engine: any TerminalEngine) -> Bool {
        guard AgentClient.isEnabled, engine is GhosttyTerminalView else { return false }
        switch kind {
        case .ssh, .localShell: return true
        case .sftp, .rdp: return false
        }
    }

    /// `allowsAgent: false` keeps the process in the app even with the agent on
    /// (the quick terminal: never saved, so nothing could reattach to it).
    init(kind: SessionKind, title: String, sharingControlSocket shared: String? = nil,
         startDirectory: String? = nil, attachingToAgent agentID: UUID? = nil, allowsAgent: Bool = true) {
        self.kind = kind
        self.title = title
        self.controlSocket = shared ?? NSTemporaryDirectory() + "wl-\(UUID().uuidString.prefix(8)).sock"
        self.ownsControlSocket = shared == nil
        self.startDirectory = startDirectory
        self.scrollbackKey = id.uuidString
        switch kind {
        case .ssh(let a, _, _, _, _): self.alias = a
        case .sftp(let a, _, _): self.alias = a
        case .localShell: self.alias = ""
        case .rdp(let a, _): self.alias = a
        }
        let view: any TerminalEngine
        if case .rdp(_, let target) = kind {
            rdp = RDPSession(target: target)
            // Never shown or launched: the plain engine, without libghostty's
            // renderer thread.
            view = WirelineTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 480))
        } else {
            rdp = nil
            view = TerminalEngineKind.makeEngine(frame: CGRect(x: 0, y: 0, width: 800, height: 480))
        }
        self.terminalView = view
        let backend: AgentPTY? = agentID.map { AgentPTY(id: $0, existing: true) }
            ?? (allowsAgent && Self.usesAgent(kind, engine: view) ? AgentPTY() : nil)
        self.attachesToAgent = agentID != nil
        switch kind {
        case .ssh(_, let password, let sudoPassword, let autoSudo, _):
            self.io = TerminalIO(password: password, sudoPassword: sudoPassword, autoSudo: autoSudo, backend: backend)
        case .sftp, .localShell, .rdp:
            self.io = TerminalIO(password: nil, autoSudo: false, backend: backend)
        }
        // Engine ⇄ PTY: output goes to the engine, keystrokes and grid changes
        // come back to the PTY.
        terminalView.io = io
        io.engine = terminalView
        terminalView.onInput = { [weak io, weak self] bytes in
            io?.send(bytes)
            if let self { IslandCenter.shared.sessionInput(self) }
        }
        terminalView.onGridResize = { [weak io] in io?.gridDidChange() }
        io.onEditorChange = { [weak self] editor in
            self?.activeEditor = editor
        }
        io.onCommandFinished = { [weak self] elapsed in
            // The engine's command marks, once seen, are the better source.
            guard let self, !self.commandMarks.isActive else { return }
            self.notifyCommandFinished(elapsed: elapsed, exitCode: nil)
            IslandCenter.shared.commandFinished(self, exitCode: nil, duration: elapsed)
        }
        io.onBusyChange = { [weak self] busy, elapsed in
            guard let self, !self.commandMarks.isActive else { return }
            // Local shells use reliable foreground-process polling (see
            // `pollForeground`); the output heuristic is only trustworthy enough
            // for SSH/SFTP, where the local foreground process is always `ssh`.
            if case .localShell = self.kind { return }
            self.applyBusy(busy, elapsed: elapsed)
        }
        // Shell-integration marks (OSC 133 C / D) from engines that report
        // them (libghostty): exact start / end and exit code, remote hosts too.
        // Local shells keep foreground polling for the badge either way.
        terminalView.onShellCommand = { [weak self] event in
            guard let self else { return }
            let local = if case .localShell = self.kind { true } else { false }
            switch event {
            case .started:
                let token = self.commandMarks.started()
                guard !local else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + CommandMarkTracker.busyDelay) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.commandMarks.confirmBusy(token) else { return }
                        self.applyBusy(true, elapsed: 0)
                    }
                }
            case let .finished(exitCode, duration):
                let wasBusy = self.commandMarks.finished()
                if !local, wasBusy || self.isBusy { self.applyBusy(false, elapsed: duration) }
                self.notifyCommandFinished(elapsed: duration, exitCode: exitCode)
                IslandCenter.shared.commandFinished(self, exitCode: exitCode, duration: duration)
            }
        }
        io.onOutput = { [weak self] in
            self?.noteOutput()
            self?.connect.noteOutput()
            if let self { IslandCenter.shared.sessionOutput(self) }
        }
        // Bells and desktop notifications (OSC 9 / 777 / 99): a coding agent
        // waiting for you, for the notch island.
        io.onAttention = { [weak self] message in
            if let self { IslandCenter.shared.sessionAttention(self, message: message) }
        }
        io.onConnected = { [weak self] in
            guard let self, self.connectionState == .connecting else { return }
            self.connectionState = .connected
        }
        io.onDisconnected = { [weak self] _ in
            guard let self else { return }
            self.connect.processExited()
            self.commandMarks.reset()
            self.connectionState = .disconnected
            self.isRunning = false
            IslandCenter.shared.sessionGone(self.id)
        }
        terminalView.onDirectoryChange = { [weak self] dir in
            self?.applyReportedDirectory(dir)
        }
        terminalView.onTitleReport = { [weak self] title in
            self?.applyReportedTitle(title)
            if let self { IslandCenter.shared.sessionTitle(self, title) }
        }
        terminalView.onOpenPath = { [weak self] path in self?.openPath(path) }
        terminalView.onClickFocus = { [weak self] in
            guard let self, let store = self.store, store.activeID != self.id else { return }
            store.activeID = self.id
        }
        terminalView.isActivePane = { [weak self] in
            guard let self else { return false }
            return self.store?.activeID == self.id
        }
        io.onCommentRequest = { [weak self] nl in
            guard let self, self.store?.activeID == self.id else { return }
            self.inlineAI.activate(prefill: nl)
        }
        inlineAI.session = self
        // `-E` sends ssh's warnings and errors to the connect log too; put them
        // back in the terminal, where they'd have appeared without it.
        connect.onUserFacingLine = { [weak self] line in
            self?.terminalView.feed(text: line + "\r\n")
        }
        if let rdp { wireRDP(rdp) }
    }

    private func wireRDP(_ rdp: RDPSession) {
        rdp.onStateChange = { [weak self] state in
            guard let self else { return }
            self.connectionState = state
            self.isRunning = state != .disconnected
            if state == .disconnected { IslandCenter.shared.sessionGone(self.id) }
        }
        rdp.onFocusRequest = { [weak self] in
            guard let self, let store = self.store, store.activeID != self.id else { return }
            store.activeID = self.id
        }
        // "Remember password" on the password card: the same Keychain item
        // HostStore reads.
        rdp.onSavePassword = { alias, password in
            try? KeychainService().setPassword(password, for: alias)
        }
    }

    /// Handle an OSC-7 working-directory report: record the absolute path (for the
    /// tooltip) and, for a local shell the user hasn't hand-renamed, retitle the tab
    /// to the directory's basename. SSH/SFTP tabs keep their host alias as the title.
    private func applyReportedDirectory(_ raw: String?) {
        guard let raw, let path = Self.parseOSC7Path(raw) else { return }
        switch kind {
        case .localShell:
            currentDirectory = path
            guard !isManuallyRenamed else { return }
            let name = Self.tabTitle(forPath: path)
            if name != title { title = name }
        case .ssh:
            applyRemoteDirectory(path)
        case .sftp, .rdp:
            break
        }
    }

    /// The remote shell's directory, when it reports one (OSC 7, or an
    /// oh-my-zsh-style `user@host: ~/dir` window title). The tab reads
    /// "alias · dir" so you can tell two panes on one host apart. Not stored in
    /// `currentDirectory` — that's a local path a local split would `cd` into.
    private(set) var remoteDirectory: String?

    private func applyRemoteDirectory(_ path: String) {
        remoteDirectory = path
        guard !isManuallyRenamed else { return }
        let leaf = path == "~" || path == "/" ? path : ((path as NSString).lastPathComponent)
        let name = "\(alias) · \(leaf)"
        if name != title { title = name }
    }

    /// A path ⌘-clicked in the terminal: a local one opens with its default app
    /// (folders in Finder); a remote one opens in the SFTP browser.
    private func openPath(_ raw: String) {
        switch kind {
        case .localShell:
            var p = (raw as NSString).expandingTildeInPath
            if !p.hasPrefix("/") {
                p = ((currentDirectory ?? NSHomeDirectory()) as NSString).appendingPathComponent(p)
            }
            guard FileManager.default.fileExists(atPath: p) else { NSSound.beep(); return }
            NSWorkspace.shared.open(URL(fileURLWithPath: p))
        case .ssh:
            var p = raw
            if !p.hasPrefix("/"), !p.hasPrefix("~"), let dir = remoteDirectory {
                p = (dir as NSString).appendingPathComponent(p)
            }
            FileBrowserModel.pendingPath[alias] = p
            NotificationCenter.default.post(name: .aiOpenFiles, object: alias)
        case .sftp, .rdp:
            break
        }
    }

    /// Program-set window titles (OSC 0/2) are ignored as tab titles — except an
    /// SSH session's idle `user@host: path` title, which is mined for the
    /// remote directory.
    private func applyReportedTitle(_ text: String) {
        guard case .ssh = kind else { return }
        let t = text.trimmingCharacters(in: .whitespaces)
        guard let at = t.firstIndex(of: "@"), let colon = t[at...].firstIndex(of: ":"),
              !t[t.startIndex..<at].contains(" "), !t[at..<colon].contains(" ") else { return }
        let path = t[t.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard path.hasPrefix("/") || path.hasPrefix("~") else { return }
        applyRemoteDirectory(path)
    }

    /// Parse an OSC-7 payload (`file://host/path`, or occasionally a bare path)
    /// into an absolute filesystem path. Returns nil if it isn't a usable path.
    static func parseOSC7Path(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let path: String
        if s.hasPrefix("file://") {
            // `rest` is `host/abs/path` (or `/abs/path` when the host is empty, i.e.
            // `file:///…`). Drop the host segment up to the first slash.
            let rest = String(s.dropFirst("file://".count))
            if rest.hasPrefix("/") { path = rest }
            else if let slash = rest.firstIndex(of: "/") { path = String(rest[slash...]) }
            else { return nil }
        } else if s.hasPrefix("/") {
            path = s
        } else {
            return nil
        }
        let decoded = path.removingPercentEncoding ?? path
        return decoded.isEmpty ? nil : decoded
    }

    /// The tab title for a working directory: the last path component, with the
    /// home directory shown as `~` and the filesystem root as `/`.
    /// This Mac's short host name (Bonjour name, no `.local`), read once.
    static let localHostName: String = {
        if let n = SCDynamicStoreCopyLocalHostName(nil) as String?, !n.isEmpty { return n }
        return ProcessInfo.processInfo.hostName.split(separator: ".").first.map(String.init) ?? "mac"
    }()

    static func tabTitle(forPath path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // At home a bare "~" says little (every new tab is "~"); name the
        // machine instead, like a shell's default title: user@host: ~
        if path == home { return "\(NSUserName())@\(localHostName): ~" }
        if path == "/" { return "/" }
        let base = (path as NSString).lastPathComponent
        return base.isEmpty ? path : base
    }

    /// Flag unread output unless this session sits in the tab you're looking at.
    private func noteOutput() {
        guard !hasUnread else { return }               // already flagged; nothing to do
        let inActiveTab = store?.activeTab?.leafID(for: id) != nil
        if !inActiveTab { hasUnread = true }
    }

    /// Busy state from the engine's OSC 133 marks (see `onShellCommand`).
    @ObservationIgnored private var commandMarks = CommandMarkTracker()

    /// A command that ran at least `notifyCommandAfter` seconds finished while
    /// the app isn't frontmost (if you're watching, you see the prompt return).
    private func notifyCommandFinished(elapsed: TimeInterval, exitCode: Int?) {
        guard !NSApp.isActive else { return }
        // HostStore's `notifyCommandAfter` (Settings / config file), read
        // where it persists — the session doesn't hold the HostStore.
        let threshold = UserDefaults.standard.object(forKey: "notifyCommandAfter") as? Double ?? 10
        guard elapsed >= threshold else { return }
        let loc = Localizer.shared
        var body = loc.t("耗时 \(Int(elapsed)) 秒", "took \(Int(elapsed))s")
        if let exitCode, exitCode != 0 { body += loc.t(" · 退出码 \(exitCode)", " · exit \(exitCode)") }
        Notifier.post(title: loc.t("命令完成 · \(title)", "Command finished · \(title)"), body: body)
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
        busyTimer?.cancel()          // avoid stacking timers across a reconnect
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 0.8, repeating: 0.8)
        t.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.pollForeground() }
        }
        t.resume()
        busyTimer = t
    }

    private func pollForeground() {
        let running: Bool, name: String?
        switch io.foregroundJob() {
        case .none: return
        case .child: (running, name) = (false, nil)
        case .job(let pgid, let n): (running, name) = (true, ForegroundProcess.identify(pgid) ?? n)
        }
        if foregroundName != name {
            foregroundName = name
            IslandCenter.shared.foregroundChanged(self)
        }
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
        if let rdp { rdp.start(); return }
        if attachesToAgent {
            // The process never stopped: its screen comes back as the agent's
            // snapshot, then live output. Nothing to dial, nothing to replay.
            io.attachToAgentSession()
            if case .ssh = kind { stats.start(socket: controlSocket, alias: alias) }
            startBusyPolling()
            return
        }
        // Replay prior scrollback (with colors) so a reopened tab looks untouched,
        // then a dim separator before the fresh live session begins.
        if let sb = pendingScrollback, !sb.isEmpty {
            // The snapshot is a self-contained stream of SGR + text + CRLF (see
            // Terminal.serializeColored), so feed the raw bytes — colors and styles
            // come back intact and there are no cursor moves to disturb the session.
            terminalView.feed(ArraySlice([UInt8](sb)))
            terminalView.feed(text: "\r\n\u{1b}[2m──────── 已恢复上次会话 / restored ────────\u{1b}[0m\r\n")
            pendingScrollback = nil
        }
        launch()
    }

    /// Re-establish the PTY in place after the link dropped (or the shell exited),
    /// reusing the SAME terminal view so the on-screen scrollback is preserved and
    /// the tab / split pane never moves. Works for SSH, SFTP, and local shells.
    /// Safe to call whether the connection is already gone or still up.
    func reconnect() {
        if let rdp {
            // Rejected credentials: ask for the password before dialling again.
            if rdp.failedOnCredentials { rdp.retryAskingPassword() } else { rdp.reconnect() }
            return
        }
        // Tear down the old process and side channels — but never the terminal view.
        stats.stop()
        busyTimer?.cancel(); busyTimer = nil
        if isRunning { io.terminate() }
        if ownsControlSocket { try? FileManager.default.removeItem(atPath: controlSocket) }
        if let askpassURL { try? FileManager.default.removeItem(at: askpassURL); self.askpassURL = nil }

        // Forget per-connection heuristics (password prompts, prompt/busy tracking)
        // and mark ourselves dialing again.
        io.resetForReconnect()
        isRunning = true
        isBusy = false
        connectionState = .connecting

        // The old child may have died inside a full-screen program: undo the
        // modes it left on (alternate screen, mouse tracking, hidden cursor…)
        // without touching the screen or scrollback.
        terminalView.feed(text: TerminalModeReset.afterChildExit)
        // A dim divider so the restart reads clearly in the scrollback.
        terminalView.feed(text: "\r\n\u{1b}[2m──────── 重新连接 / reconnecting ────────\u{1b}[0m\r\n")
        launch()
    }

    /// Spawn (or respawn) the underlying process for this session's kind. Split out
    /// of `start()` so `reconnect()` can relaunch without re-replaying scrollback.
    private func launch() {
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        // Preserve the user's locale so remote/local shells render UTF-8 correctly.
        if let lang = ProcessInfo.processInfo.environment["LANG"] { env.append("LANG=\(lang)") }

        // The agent deletes the askpass script when the process ends.
        io.agent?.cleanupPaths = []
        switch kind {
        case .ssh(let alias, let password, _, _, let extraArgs):
            // For password hosts, feed the password to ssh deterministically via
            // an askpass helper (OpenSSH SSH_ASKPASS + REQUIRE=force) instead of
            // typing it into the PTY — no prompt-scraping, no dropped characters.
            if let password, !password.isEmpty, let script = Self.makeAskpassScript() {
                askpassURL = script
                io.agent?.cleanupPaths = [script.path]
                env.append("SSH_ASKPASS=\(script.path)")
                env.append("SSH_ASKPASS_REQUIRE=force")
                env.append("WIRELINE_ASKPASS_PW=\(password)")
            }
            // Touch ID–protected keys are served by Wireline's own ssh-agent.
            SSHAgentEnvironment.apply(to: &env)
            // `-v -E`: the debug log goes to a file (never the terminal) that the
            // connect panel follows to show resolve → connect → auth → session.
            let logArgs = connect.begin().map { ["-v", "-E", $0] } ?? []
            // Enable ControlMaster so a side channel can poll server stats over
            // the same authenticated connection (no re-auth, no PTY interference).
            let args = logArgs + [
                "-o", "StrictHostKeyChecking=accept-new",
                "-o", "ControlMaster=auto",
                "-o", "ControlPath=\(controlSocket)",
                "-o", "ControlPersist=30"
            ] + extraArgs + [alias]
            io.start(executable: "/usr/bin/ssh", args: args, environment: env)
            stats.start(socket: controlSocket, alias: alias)
        case .sftp(let alias, let password, let extraArgs):
            if let password, !password.isEmpty, let script = Self.makeAskpassScript() {
                askpassURL = script
                env.append("SSH_ASKPASS=\(script.path)")
                env.append("SSH_ASKPASS_REQUIRE=force")
                env.append("WIRELINE_ASKPASS_PW=\(password)")
            }
            SSHAgentEnvironment.apply(to: &env)
            io.start(
                executable: "/usr/bin/sftp",
                args: ["-o", "StrictHostKeyChecking=accept-new"] + extraArgs + [alias],
                environment: env
            )
        case .localShell:
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            let name = (shell as NSString).lastPathComponent
            // For zsh, inject a shell-integration shim (via ZDOTDIR) that loads the
            // user's real config untouched and then reports the working directory
            // over OSC 7 on every prompt / `cd`, so the tab title tracks the folder.
            if name == "zsh", let shim = Self.zshIntegrationZDOTDIR() {
                let userZDOTDIR = ProcessInfo.processInfo.environment["ZDOTDIR"]
                    ?? FileManager.default.homeDirectoryForCurrentUser.path
                env.removeAll { $0.hasPrefix("ZDOTDIR=") }
                env.append("ZDOTDIR=\(shim.path)")
                env.append("WIRELINE_USER_ZDOTDIR=\(userZDOTDIR)")
            }
            // Launch as a login shell (leading '-') so ~/.zprofile & ~/.zshrc load,
            // which is what gives the user their familiar prompt, theme, and colors.
            io.start(
                executable: shell,
                args: ["-l"],
                environment: env,
                execName: "-\(name)",
                // Start in the source pane's directory for a split, else the
                // user's home (not the app's cwd, which is `/`).
                currentDirectory: startDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path
            )
            startBusyPolling()
        case .rdp:
            break   // `start()` / `reconnect()` hand over to `rdp`
        }
    }

    /// Persist this session's rendered scrollback (plain text, correct layout) so
    /// it can be replayed next launch. Writes the last ~256KB to
    /// `<dir>/<scrollbackKey>.txt`; removes the file when empty.
    func saveScrollback(dir: URL) {
        guard !scrollbackKey.isEmpty, isRunning, rdp == nil else { return }
        let url = dir.appendingPathComponent("\(scrollbackKey).txt")
        // Nil means a full-screen app owned the alternate screen at save time —
        // keep the previous snapshot rather than clobbering it with a blank one.
        guard let text = replayableScrollback() else { return }
        if text.isEmpty { try? FileManager.default.removeItem(at: url) }
        else { try? Data(text.utf8).write(to: url, options: .atomic) }
    }

    /// The rendered scrollback as a replayable stream (see `start()`); nil when
    /// there's nothing to take (RDP, or a full-screen app on the alternate screen).
    func replayableScrollback() -> String? {
        guard rdp == nil else { return nil }
        let data = terminalView.renderedBuffer
        guard !data.isEmpty else { return nil }
        // The stream is colored SGR + text with CRLF line breaks. Drop prior
        // restore-banner lines (they get re-serialized after each launch) while
        // preserving CRLF and escape sequences, so the tail stays replayable.
        return String(decoding: data, as: UTF8.self)
            .components(separatedBy: "\r\n")
            .filter { !$0.contains("已恢复上次会话") }
            .joined(separator: "\r\n")
            .trimmingCharacters(in: .newlines)
    }

    /// Something is running here that closing would kill: a command (the tab's
    /// "running" badge) or a coding agent, even one idle at its own prompt.
    var hasRunningWork: Bool {
        isRunning && rdp == nil && (isBusy || agentState != nil)
    }

    /// Whether this session is recording its output to a log file, and where.
    var isLogging = false
    var logURL: URL?

    /// Start or stop logging this session's output to a file.
    func toggleLogging() {
        if isLogging {
            io.stopLogging()
            isLogging = false
        } else {
            let label = alias.isEmpty ? "local" : alias
            logURL = io.startLogging(label: label)
            isLogging = logURL != nil
        }
    }

    func terminate() {
        if let rdp {
            // Also from a failed / disconnected state: drops prompts and the tunnel.
            rdp.close()
            isRunning = false
            connectionState = .disconnected
            return
        }
        // An exited agent session is still held there (for a respawn): release it.
        guard isRunning else { io.agent?.close(); return }
        isRunning = false
        connectionState = .disconnected
        busyTimer?.cancel()
        busyTimer = nil
        stats.stop()
        connect.stop()
        io.stopLogging()
        isLogging = false
        io.close()
        if ownsControlSocket { try? FileManager.default.removeItem(atPath: controlSocket) }
        if let askpassURL { try? FileManager.default.removeItem(at: askpassURL) }
        askpassURL = nil
    }

    /// The connect panel's 取消: stop dialing. The session ends up disconnected,
    /// with the usual reconnect banner.
    func cancelConnect() {
        connect.stop()
        terminate()
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

    /// Where the ZDOTDIR shim lives. Application Support, *not* the temp dir:
    /// macOS prunes `$TMPDIR` after a few days, and a pruned shim left every new
    /// session with a ZDOTDIR containing no startup files at all — so the user's
    /// `~/.zshrc` silently never loaded (they had to `source ~/.zshrc` by hand).
    private static let zshIntegrationDir: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wireline/zsh", isDirectory: true)
    }()

    /// The shim's startup files, by name. Each one points ZDOTDIR at the user's
    /// real dir, sources their counterpart file, then puts ZDOTDIR back so the
    /// next startup file is read from the shim too — the well-known VS Code
    /// approach, which also copes with a user `.zshenv` that relocates ZDOTDIR.
    private static var zshIntegrationFiles: [String: String] {
        // The hook: report $PWD via OSC 7 on each prompt and on every directory
        // change, deduped so re-sourcing the rc doesn't stack the callback.
        let hook = """

        # --- Wireline shell integration: report cwd via OSC 7 (tab title tracking) ---
        _wireline_osc7() { printf '\\033]7;file://%s%s\\a' "${HOST:-}" "$PWD"; }
        # OSC 133 prompt marks, the way Ghostty's own zsh integration places
        # them: in PS1 itself (A at the start, k=s on each continuation line of
        # a multi-line prompt, B before the input), so zsh re-emits them on every
        # redisplay — notably its SIGWINCH redraw. The terminal blanks the marked
        # prompt before a resize reflow and the redraw replaces it in place,
        # instead of stacking prompts or scattering right-prompt copies. Plus C
        # when a command starts and D with its status. Only when this hook runs
        # last (themes rebuild PS1 in their own precmd); otherwise A is printed.
        _wireline_133_precmd() {
          builtin local -i st=$?
          builtin emulate -L zsh -o no_warn_create_global -o no_aliases
          if ! builtin zle; then
            (( ${_wireline_133_state:-0} == 1 )) && builtin print -n "\\e]133;D;$st\\a"
          fi
          builtin local markA=$'%{\\e]133;A;cl=line\\a%}' markS=$'%{\\e]133;P;k=s\\a%}' markB=$'%{\\e]133;B\\a%}'
          if [[ -o prompt_percent && ${precmd_functions[-1]} == _wireline_133_precmd ]]; then
            builtin local changed=0
            if [[ -n ${_wireline_ps1+x} ]]; then
              if [[ $PS1 == $_wireline_marked_ps1 ]]; then PS1=$_wireline_ps1; PS2=$_wireline_ps2
              elif [[ $PS1 != $_wireline_ps1 ]]; then changed=1; fi
            fi
            _wireline_ps1=$PS1 _wireline_ps2=$PS2
            # A trailing bare '%' would swallow the '%{' of the mark.
            [[ $PS1 == *[^%]% || $PS1 == % ]] && PS1=$PS1%
            PS1=${markA}${PS1}${markB}
            (( ! changed )) && [[ $PS1 == *$'\\n'* ]] && PS1=${PS1//$'\\n'/$'\\n'${markS}}
            [[ $PS2 == *[^%]% || $PS2 == % ]] && PS2=$PS2%
            PS2=${markS}${PS2}${markB}
            _wireline_marked_ps1=$PS1
          else
            precmd_functions=(${precmd_functions:#_wireline_133_precmd} _wireline_133_precmd)
            builtin zle || builtin print -n '\\e]133;A;cl=line\\a'
          fi
          _wireline_133_state=2
        }
        _wireline_133_preexec() {
          builtin emulate -L zsh -o no_warn_create_global -o no_aliases
          if [[ -n ${_wireline_ps1+x} && $PS1 == $_wireline_marked_ps1 ]]; then PS1=$_wireline_ps1; PS2=$_wireline_ps2; fi
          builtin print -n '\\e]133;C\\a'
          _wireline_133_state=1
        }
        if [[ -z "${_wireline_osc7_installed:-}" ]]; then
          _wireline_osc7_installed=1
          typeset -ag precmd_functions chpwd_functions preexec_functions
          precmd_functions+=(_wireline_osc7 _wireline_133_precmd)
          chpwd_functions+=(_wireline_osc7)
          preexec_functions+=(_wireline_133_preexec)
        fi
        """
        // `/etc/zshrc` derives HISTFILE from ZDOTDIR, which at that point is this
        // shim — so repoint it at the user's real dir *before* their rc runs (it
        // may read HISTFILE), or Wireline's history would be written inside the
        // shim instead of joining the user's normal `~/.zsh_history`.
        let histFix = """
        [[ "${HISTFILE:-}" == "$WIRELINE_SHIM_ZDOTDIR"/* ]] && HISTFILE="$WIRELINE_USER_ZDOTDIR/.zsh_history"
        """
        // `restoreShim: false` hands ZDOTDIR back to the user's dir for good, so
        // nothing after startup (history, compdump, a nested `zsh`) reads from here.
        func stage(_ file: String, before: String = "", after: String = "", restoreShim: Bool = true) -> String {
            """
            WIRELINE_SHIM_ZDOTDIR="${WIRELINE_SHIM_ZDOTDIR:-$ZDOTDIR}"
            : "${WIRELINE_USER_ZDOTDIR:=$HOME}"
            \(before)
            ZDOTDIR="$WIRELINE_USER_ZDOTDIR"
            [[ -f "$ZDOTDIR/\(file)" ]] && builtin source "$ZDOTDIR/\(file)"
            WIRELINE_USER_ZDOTDIR="$ZDOTDIR"
            ZDOTDIR="\(restoreShim ? "$WIRELINE_SHIM_ZDOTDIR" : "$WIRELINE_USER_ZDOTDIR")"
            \(after)
            """
        }
        return [
            ".zshenv": stage(".zshenv"),
            ".zprofile": stage(".zprofile"),
            // A login shell still has `.zlogin` to read, so it keeps ZDOTDIR on the
            // shim; a non-login interactive shell is done here and hands it back.
            ".zshrc": stage(".zshrc", before: histFix,
                            after: hook + "\n[[ -o login ]] || ZDOTDIR=\"$WIRELINE_USER_ZDOTDIR\""),
            ".zlogin": stage(".zlogin", restoreShim: false),
        ]
    }

    /// Ensure the shim directory holds the current startup files, and return it.
    /// Re-verified on every launch (four small reads) so a deleted, truncated, or
    /// outdated shim heals itself instead of breaking every session from then on.
    static func zshIntegrationZDOTDIR() -> URL? {
        let dir = zshIntegrationDir
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, content) in zshIntegrationFiles {
            let url = dir.appendingPathComponent(name)
            if (try? String(contentsOf: url, encoding: .utf8)) == content { continue }
            do { try content.write(to: url, atomically: true, encoding: .utf8) }
            catch { return nil }
        }
        // Without a readable .zshrc the shim would *suppress* the user's config
        // rather than extend it — better to launch a plain shell than a broken one.
        guard fm.isReadableFile(atPath: dir.appendingPathComponent(".zshrc").path) else { return nil }
        return dir
    }
}

/// A restorable description of an open session — enough to reopen it (and
/// reconnect) on the next launch. Live PTY state can't be frozen, so we persist
/// what the session *is*, then re-establish it.
struct SessionSnapshot: Codable, Sendable {
    enum Kind: String, Codable { case ssh, sftp, local, rdp }
    var kind: Kind
    var alias: String
    var title: String
    /// Key locating this session's persisted scrollback file (empty for older data).
    var scrollbackKey: String = ""
    /// Whether the title was set by hand (so directory auto-tracking leaves it
    /// alone). Optional so snapshots written before this field decode cleanly.
    var manuallyRenamed: Bool?
    /// A local shell's working directory, so it reopens where it was.
    var directory: String?
    /// The session agent's id for it, when its process lives there: the next
    /// launch attaches instead of reconnecting.
    var agentID: UUID?
    /// An SSH session's ControlMaster socket (kept by an agent session's ssh).
    var controlSocket: String?
}

/// The tab / split arrangement, saved next to the session list. Leaves refer to
/// sessions by their index in that list.
struct LayoutSnapshot: Codable {
    indirect enum Node: Codable {
        case leaf(Int)
        case branch(vertical: Bool, ratio: Double, first: Node, second: Node)
    }
    var tabs: [Node]
    var activeTab: Int?
    var activeSession: Int?
    /// tab index → zoomed session index
    var zoomed: [Int: Int] = [:]
    /// tab index → name given to a split tab (nil in older data)
    var names: [Int: String]?
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
    var activeTabID: UUID? {
        didSet { clearUnread(inTab: activeTabID); if activeTabID != oldValue { persistLayout() } }
    }

    /// Mark every session in a tab as read (its "new output" dot goes away once
    /// you're looking at it).
    private func clearUnread(inTab tabID: UUID?) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        for sid in tab.sessionIDs { session(sid)?.hasUnread = false }
    }
    /// The focused session within the active tab (drives which pane is highlighted
    /// and where the keyboard goes).
    var activeID: UUID? {
        didSet {
            guard activeID != oldValue else { return }
            if let id = activeID {
                focusHistory.removeAll { $0 == id }
                focusHistory.append(id)
                if focusHistory.count > 64 { focusHistory.removeFirst() }
            }
            persistLayout()
        }
    }

    var activeTab: PaneNode? { tabs.first { $0.id == activeTabID } }

    private static let persistKey = "wireline.openSessions"
    /// Guards one-time restore so re-appearing windows don't reopen duplicates.
    private var didRestore = false

    /// Open an SSH session for a host. `password` is fetched from the Keychain
    /// by the caller (nil for key auth).
    @discardableResult
    func open(host: Host, password: String?, sudoPassword: String? = nil) -> UUID {
        add(TerminalSession(
            kind: .ssh(alias: host.alias, password: password, sudoPassword: sudoPassword,
                       autoSudo: host.autoSudo, args: host.launchArgTokens),
            title: host.alias))
    }

    /// Open an interactive SFTP file-transfer session for a host.
    @discardableResult
    func openSFTP(host: Host, password: String?) -> UUID {
        add(TerminalSession(kind: .sftp(alias: host.alias, password: password, args: host.launchArgTokens),
                            title: "📁 \(host.alias)"))
    }

    /// Open a remote desktop for an RDP host (`HostStore.rdpTarget(for:)`).
    @discardableResult
    func openRDP(host: Host, target: RDPTarget) -> UUID {
        add(TerminalSession(kind: .rdp(alias: host.alias, target: target), title: host.alias))
    }

    /// Open a plain local shell session.
    @discardableResult
    func openLocalShell() -> UUID {
        // Like Ghostty's window-inherit-working-directory: start where the
        // focused local shell is. (HostStore's setting, read where it persists.)
        let inherit = UserDefaults.standard.object(forKey: "inheritWorkingDirectory") as? Bool ?? true
        var dir: String?
        if inherit, let s = activeSession, case .localShell = s.kind { dir = s.currentDirectory }
        return add(TerminalSession(kind: .localShell, title: "Local Shell", startDirectory: dir))
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
        session.terminalView.onCloseRequested = { [weak self] in
            // Remaining panes grow into the space (performClose animates, one reflow).
            self?.requestClose([id])
        }
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

    // MARK: - Splits (keyboard)

    /// Split ratios per branch id (first child's share, 0…1). Missing = even.
    private(set) var splitRatios: [UUID: CGFloat] = [:]
    /// The leaf session zoomed to fill its tab, per tab id.
    private(set) var zoomedSession: [UUID: UUID] = [:]
    /// Last laid-out frame of every visible pane (window coordinates), for
    /// directional focus. Not observed: layout writes it every pass.
    @ObservationIgnored var paneFrames: [UUID: CGRect] = [:]

    func ratio(for branch: UUID) -> CGFloat { splitRatios[branch] ?? 0.5 }

    func setRatio(_ r: CGFloat, for branch: UUID) {
        splitRatios[branch] = min(max(r, 0.12), 0.88)
        persistLayout()
    }

    /// Rebuild tabs and splits for freshly restored sessions (`restored` is
    /// index-aligned with the saved session list). Sessions the saved layout
    /// doesn't place — or every session, for data from before layouts were
    /// saved — get a tab of their own.
    private func restoreLayout(_ restored: [TerminalSession?]) {
        let layout = UserDefaults.standard.data(forKey: Self.layoutKey)
            .flatMap { try? JSONDecoder().decode(LayoutSnapshot.self, from: $0) }
        func id(_ i: Int) -> UUID? { restored.indices.contains(i) ? restored[i]?.id : nil }
        func build(_ n: LayoutSnapshot.Node) -> PaneNode? { buildPane(n, id: id) }
        var built: [PaneNode] = []
        var tabIndexMap: [Int: Int] = [:]   // saved tab index → built tab index
        for (i, node) in (layout?.tabs ?? []).enumerated() {
            if let t = build(node) { tabIndexMap[i] = built.count; built.append(t) }
        }
        let placed = Set(built.flatMap(\.sessionIDs))
        for s in restored.compactMap({ $0 }) where !placed.contains(s.id) {
            built.append(PaneNode.makeLeaf(s.id))
        }
        tabs = built
        for (ti, name) in layout?.names ?? [:] {
            if let bt = tabIndexMap[ti], let anchor = tabs[bt].sessionIDs.first { tabNames[anchor] = name }
        }
        for (ti, si) in layout?.zoomed ?? [:] {
            if let bt = tabIndexMap[ti], let sid = id(si) { zoomedSession[tabs[bt].id] = sid }
        }
        let activeTab = layout?.activeTab.flatMap { tabIndexMap[$0] }.map { tabs[$0] } ?? tabs.last
        activeTabID = activeTab?.id
        let wanted = layout?.activeSession.flatMap(id)
        activeID = wanted.flatMap { w in activeTab?.leafID(for: w) != nil ? w : nil } ?? activeTab?.sessionIDs.first
    }

    /// A saved pane tree back into a live one; leaves whose session is gone
    /// drop out and their sibling takes the space.
    private func buildPane(_ n: LayoutSnapshot.Node, id: (Int) -> UUID?) -> PaneNode? {
        switch n {
        case .leaf(let i):
            return id(i).map(PaneNode.makeLeaf)
        case .branch(let vertical, let ratio, let a, let b):
            switch (buildPane(a, id: id), buildPane(b, id: id)) {
            case (let x?, let y?):
                let bid = UUID()
                if abs(ratio - 0.5) > 0.001 { splitRatios[bid] = min(max(CGFloat(ratio), 0.12), 0.88) }
                return .branch(id: bid, axis: vertical ? .vertical : .horizontal, first: x, second: y)
            case (let x?, nil): return x
            case (nil, let y?): return y
            case (nil, nil): return nil
            }
        }
    }

    /// Make every split in the active tab even.
    func equalizeSplits() {
        guard let tab = activeTab else { return }
        for id in tab.branchIDs { splitRatios[id] = nil }
        persistLayout()
    }

    /// ⌘D: split into a grid at most two panes wide. A pane alone in its row
    /// gets a neighbour on the right; once its row holds two, the new pane
    /// starts a row below the stack of rows, and the rows are evened out.
    @discardableResult
    func splitActiveGrid() -> UUID? {
        guard let source = activeSession, let ti = tabIndex(containing: source.id),
              let leaf = tabs[ti].leafID(for: source.id) else { return nil }
        let path = tabs[ti].ancestors(ofLeaf: leaf)
        guard var k = path.lastIndex(where: { $0.axis == .horizontal }) else {
            return splitActive(.trailing)
        }
        // Climb to the top of the column of rows this row belongs to.
        while k > 0, path[k - 1].axis == .vertical { k -= 1 }
        let stack = path[k]
        if let tabID = activeTabID { zoomedSession[tabID] = nil }
        let id = spawn(siblingSession(of: source))
        let branchID = UUID()
        let rows = stack.rowCount
        tabs[ti] = tabs[ti].stacking(.makeLeaf(id), below: stack.id, branchID: branchID)
        setRatio(CGFloat(rows) / CGFloat(rows + 1), for: branchID)
        activeTabID = tabs[ti].id
        activeID = id
        persist()
        return id
    }

    /// A new session like `source`: same SSH host (sharing its connection), or
    /// a local shell in the same directory. (Not a second remote desktop: on
    /// a workstation Windows it would log the first one out.)
    private func siblingSession(of source: TerminalSession) -> TerminalSession {
        switch source.kind {
        case .ssh:
            return TerminalSession(kind: source.kind, title: source.alias,
                                   sharingControlSocket: source.controlSocket)
        case .sftp, .localShell, .rdp:
            return TerminalSession(kind: .localShell, title: "Local Shell",
                                   startDirectory: source.currentDirectory)
        }
    }

    /// Open a new pane next to the active one, like the source: a local shell
    /// in the same directory, or the same host over the same SSH connection.
    @discardableResult
    func splitActive(_ edge: PaneEdge) -> UUID? {
        guard let source = activeSession, let ti = tabIndex(containing: source.id),
              let leaf = tabs[ti].leafID(for: source.id) else { return nil }
        let session = siblingSession(of: source)
        if let tabID = activeTabID { zoomedSession[tabID] = nil }
        let id = spawn(session)
        tabs[ti] = tabs[ti].splitting(leaf: leaf, insert: id, edge: edge)
        // Splitting a single-pane tab turns its root leaf into a new branch, so
        // the tab's id changes — follow it, or the active tab is "lost" and the
        // view falls back to showing one pane until the tab is clicked.
        activeTabID = tabs[ti].id
        activeID = id
        persist()
        return id
    }

    /// Open a session to `host` as a new pane beside `leaf` (a host dragged
    /// onto a terminal's edge): SSH, or a remote desktop when `rdp` is given.
    @discardableResult
    func splitHost(_ host: Host, password: String?, sudoPassword: String?, rdp: RDPTarget? = nil,
                   ontoLeaf leaf: UUID, edge: PaneEdge) -> UUID? {
        guard let ti = tabs.firstIndex(where: { $0.contains(leaf: leaf) }) else { return nil }
        let session = if let rdp {
            TerminalSession(kind: .rdp(alias: host.alias, target: rdp), title: host.alias)
        } else {
            TerminalSession(
                kind: .ssh(alias: host.alias, password: password, sudoPassword: sudoPassword,
                           autoSudo: host.autoSudo, args: host.launchArgTokens),
                title: host.alias)
        }
        if let tabID = activeTabID { zoomedSession[tabID] = nil }
        let id = spawn(session)
        tabs[ti] = tabs[ti].splitting(leaf: leaf, insert: id, edge: edge == .center ? .trailing : edge)
        activeTabID = tabs[ti].id
        activeID = id
        persist()
        return id
    }

    /// Zoom the active pane to fill its tab, or restore the split.
    func toggleZoom() {
        guard let tabID = activeTabID, let tab = activeTab, tab.sessionIDs.count > 1,
              let active = activeID else { return }
        zoomedSession[tabID] = zoomedSession[tabID] == nil ? active : nil
        persistLayout()
    }

    func zoomedSession(inTab tabID: UUID?) -> UUID? {
        guard let tabID, let z = zoomedSession[tabID],
              tabs.first(where: { $0.id == tabID })?.leafID(for: z) != nil else { return nil }
        return z
    }

    enum Direction { case left, right, up, down }

    /// Focus the nearest pane in `direction` from the active one: it must lie
    /// beyond the active pane's edge; prefer the most overlap, then the closest.
    func focusPane(_ direction: Direction) {
        guard let tab = activeTab, let active = activeID, let from = paneFrames[active] else { return }
        let candidates = tab.sessionIDs.filter { $0 != active }.compactMap { id in paneFrames[id].map { (id, $0) } }
        func overlap(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat { max(0, min(b, d) - max(a, c)) }
        let scored: [(UUID, CGFloat, CGFloat)] = candidates.compactMap { id, r in
            switch direction {
            case .left:  guard r.maxX <= from.minX + 2 else { return nil }
                return (id, overlap(r.minY, r.maxY, from.minY, from.maxY), from.minX - r.maxX)
            case .right: guard r.minX >= from.maxX - 2 else { return nil }
                return (id, overlap(r.minY, r.maxY, from.minY, from.maxY), r.minX - from.maxX)
            case .up:    guard r.maxY <= from.minY + 2 else { return nil }
                return (id, overlap(r.minX, r.maxX, from.minX, from.maxX), from.minY - r.maxY)
            case .down:  guard r.minY >= from.maxY - 2 else { return nil }
                return (id, overlap(r.minX, r.maxX, from.minX, from.maxX), r.minY - from.maxY)
            }
        }
        let best = scored.filter { $0.1 > 0 }.min { $0.2 != $1.2 ? $0.2 < $1.2 : $0.1 > $1.1 }
            ?? scored.min { $0.2 < $1.2 }
        if let best { activeID = best.0 }
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
    /// Names given to split tabs, keyed by one of the tab's sessions (a tab's
    /// own id changes whenever its layout does). A single-pane tab's name is
    /// its session's title instead.
    private(set) var tabNames: [UUID: String] = [:]

    func tabName(_ tab: PaneNode) -> String? {
        tab.sessionIDs.lazy.compactMap { self.tabNames[$0] }.first
    }

    /// Rename a tab: a single pane renames its session; a split tab gets a
    /// name of its own. An empty name on a split tab goes back to the panes' titles.
    func renameTab(_ tab: PaneNode, to name: String) {
        let ids = tab.sessionIDs
        if ids.count == 1, let only = ids.first { rename(only, to: name); return }
        for id in ids { tabNames[id] = nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, let anchor = ids.first { tabNames[anchor] = trimmed }
        persist()
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let s = session(id) else { return }
        s.title = trimmed
        s.isManuallyRenamed = true          // pin it — stop directory auto-tracking
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

    /// Panes in the order they were last focused (most recent last) — closing
    /// the focused pane returns to the one you were in before it, like tmux /
    /// Ghostty, instead of jumping to the first pane.
    private var focusHistory: [UUID] = []

    // MARK: - Close (with confirmation) / reopen

    /// A close that's waiting on "something is still running — close anyway?".
    struct CloseRequest: Identifiable {
        let id = UUID()
        let sessionIDs: [UUID]
        /// Titles of the sessions that are busy, for the dialog.
        let busyTitles: [String]
    }
    /// Set while the confirmation dialog is up (presented by ContentView).
    var pendingClose: CloseRequest?

    /// The user asked to close these sessions (⌘W, a tab's or pane's ×). Asks
    /// first when one of them is still running something, unless that's
    /// turned off (`confirm-close-surface`).
    func requestClose(_ ids: [UUID]) {
        guard pendingClose == nil else { return }   // the dialog is already asking
        let confirm = UserDefaults.standard.object(forKey: "confirmCloseRunning") as? Bool ?? true
        let busy = ids.compactMap(session).filter(\.hasRunningWork)
        if confirm, !busy.isEmpty {
            wlAnimate(Motion.flipIn) { pendingClose = CloseRequest(sessionIDs: ids, busyTitles: busy.map(\.title)) }
        } else {
            performClose(ids)
        }
    }

    func confirmPendingClose() {
        guard let request = pendingClose else { return }
        wlAnimate(Motion.flipOut) { pendingClose = nil }
        performClose(request.sessionIDs)
    }

    /// Close a whole tab at once, or a single pane — remembered as one entry
    /// for "reopen closed tab" either way.
    private func performClose(_ ids: [UUID]) {
        wlAnimateTerminalLayout {
            if ids.count > 1, let ti = tabIndex(containing: ids[0]),
               Set(tabs[ti].sessionIDs) == Set(ids) {
                rememberClosed(tab: tabs[ti], at: ti)
                for id in ids { close(id, remember: false) }
            } else {
                for id in ids { close(id) }
            }
        }
    }

    /// What it takes to bring a closed tab (or pane) back: its sessions, their
    /// screens, and how they were arranged.
    private struct ClosedTab {
        var sessions: [(snapshot: SessionSnapshot, scrollback: String?)]
        var layout: LayoutSnapshot.Node
        var name: String?
        var tabIndex: Int
    }
    /// Most recent last; in memory only.
    private var recentlyClosed: [ClosedTab] = []
    private static let recentlyClosedLimit = 10

    var canReopenClosed: Bool { !recentlyClosed.isEmpty }

    private func rememberClosed(tab: PaneNode, at tabIndex: Int, only leaf: UUID? = nil) {
        let ids = leaf.map { [$0] } ?? tab.sessionIDs
        let live = ids.compactMap(session)
        guard !live.isEmpty else { return }
        let index = Dictionary(uniqueKeysWithValues: live.enumerated().map { ($1.id, $0) })
        let node: LayoutSnapshot.Node? = leaf == nil ? encodePane(tab, index: index) : .leaf(0)
        guard let node else { return }
        recentlyClosed.append(ClosedTab(
            sessions: live.map { (snapshot(of: $0), $0.replayableScrollback()) },
            layout: node,
            name: leaf == nil && tab.sessionIDs.count > 1 ? tabName(tab) : nil,
            tabIndex: tabIndex))
        if recentlyClosed.count > Self.recentlyClosedLimit { recentlyClosed.removeFirst() }
    }

    /// ⇧⌘T: reopen the most recently closed tab (or pane, as its own tab) where
    /// it was, reconnecting and replaying what was on screen.
    func reopenClosed(store: HostStore) {
        while let entry = recentlyClosed.popLast() {
            let built = entry.sessions.map { item -> TerminalSession? in
                guard let s = makeSession(from: item.snapshot, store: store) else { return nil }
                s.pendingScrollback = item.scrollback.map { Data($0.utf8) }
                return s
            }
            guard built.contains(where: { $0 != nil }) else { continue }   // its hosts are gone
            for s in built.compactMap({ $0 }) { _ = spawn(s) }
            guard let tab = buildPane(entry.layout, id: { built.indices.contains($0) ? built[$0]?.id : nil })
            else { continue }
            wlAnimateTerminalLayout {
                tabs.insert(tab, at: min(entry.tabIndex, tabs.count))
                if let name = entry.name, tab.sessionIDs.count > 1, let anchor = tab.sessionIDs.first {
                    tabNames[anchor] = name
                }
                activeTabID = tab.id
                activeID = tab.sessionIDs.first
            }
            persist()
            return
        }
    }

    func close(_ id: UUID, remember: Bool = true) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        if remember, let ti = tabIndex(containing: id) { rememberClosed(tab: tabs[ti], at: ti, only: id) }
        IslandCenter.shared.sessionGone(id)
        focusHistory.removeAll { $0 == id }
        // A split tab's name was keyed by this pane: hand it to a surviving one.
        if let name = tabNames.removeValue(forKey: id), let ti = tabIndex(containing: id),
           let other = tabs[ti].sessionIDs.first(where: { $0 != id }) {
            tabNames[other] = name
        }
        // Closing the focused pane: fall back to the pane focused before it in
        // the same tab, else its neighbour before it in layout order.
        var successor: UUID?
        if activeID == id, let ti = tabIndex(containing: id) {
            let ids = tabs[ti].sessionIDs
            successor = focusHistory.last { ids.contains($0) }
            if successor == nil, let k = ids.firstIndex(of: id) {
                successor = k > 0 ? ids[k - 1] : ids.dropFirst().first
            }
        }
        sessions[index].terminate()
        sessions.remove(at: index)
        // Remove the session from its tab; drop the tab if it becomes empty.
        if let ti = tabIndex(containing: id) {
            let wasActive = tabs[ti].id == activeTabID
            if let remaining = tabs[ti].removingSession(id) {
                tabs[ti] = remaining
                // Collapsing a split can promote a child to the root, changing
                // the tab's id — keep the same tab active.
                if wasActive { activeTabID = remaining.id }
            } else {
                tabs.remove(at: ti)
            }
        }
        // Re-derive the active tab / session.
        if !tabs.contains(where: { $0.id == activeTabID }) {
            activeTabID = tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id
        }
        zoomedSession = zoomedSession.filter { id, s in tabs.contains { $0.id == id && $0.leafID(for: s) != nil } }
        if let at = activeTab {
            if at.leafID(for: activeID ?? UUID()) == nil {
                activeID = successor.flatMap { at.leafID(for: $0) != nil ? $0 : nil } ?? at.sessionIDs.first
            }
        } else {
            activeID = nil
        }
        persist()
    }

    // MARK: - Quit

    /// Sessions whose process lives in the session agent (they outlive the app).
    var keptByAgent: Int { sessions.filter { $0.io.agent.map { !$0.runsLocally } ?? false }.count }
    private static let quitNoticeKey = "sessionAgentQuitNoticeShown"

    /// ⌘Q. The first time it would leave sessions running in the agent, say
    /// so first (ContentView shows QuitNoticeSheet); after that, just quit.
    func requestQuit() {
        if keptByAgent > 0, !UserDefaults.standard.bool(forKey: Self.quitNoticeKey) {
            NSApp.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(name: .confirmQuit, object: nil)
            return
        }
        NSApp.terminate(nil)
    }

    /// Quit, leaving agent sessions running, or ending every session (⌥⌘Q).
    func quit(endingSessions: Bool) {
        UserDefaults.standard.set(true, forKey: Self.quitNoticeKey)
        guard endingSessions else { NSApp.terminate(nil); return }
        closeAll()
        // Let the close messages reach the agent before we go.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
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
    /// used by the "focus terminal" shortcut after the command bar / AI panel, and
    /// after launch restore. Must make the window *key* (not just set first
    /// responder): the floating desktop pet grabs key status on launch, so a bare
    /// makeFirstResponder on a non-key window would never receive keystrokes.
    func focusActiveTerminal() {
        guard let term = activeSession?.focusView, let window = term.window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(term)
    }

    /// Send the same text to every open session's terminal (the broadcast bar).
    func broadcast(_ text: String) {
        for s in sessions where s.rdp == nil { s.terminalView.send(txt: text) }
    }


    // MARK: - Persistence / restore

    /// Where per-session scrollback files live.
    static let scrollbackDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wireline/scrollback", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    private func loadScrollback(_ key: String) -> Data? {
        guard !key.isEmpty else { return nil }
        return try? Data(contentsOf: Self.scrollbackDir.appendingPathComponent("\(key).txt"))
    }

    /// Persist open sessions AND their scrollback, so a relaunch restores the tabs
    /// with their history intact. Prunes scrollback files for closed sessions.
    func persist() {
        let snaps = sessions.map(snapshot(of:))
        if let data = try? JSONEncoder().encode(snaps) {
            UserDefaults.standard.set(data, forKey: Self.persistKey)
        }
        persistLayout()
        for s in sessions { s.saveScrollback(dir: Self.scrollbackDir) }
        pruneScrollback(keeping: Set(sessions.map(\.scrollbackKey)))
    }

    private static let layoutKey = "wireline.sessionLayout"

    /// Save just the arrangement (cheap — no scrollback), on every split /
    /// ratio / focus / zoom change.
    func persistLayout() {
        guard didRestore else { return }   // don't clobber it before it's been read
        let index = Dictionary(uniqueKeysWithValues: sessions.enumerated().map { ($1.id, $0) })
        func encode(_ n: PaneNode) -> LayoutSnapshot.Node? { encodePane(n, index: index) }
        var zoomed: [Int: Int] = [:]
        var names: [Int: String] = [:]
        for (ti, tab) in tabs.enumerated() {
            if let z = zoomedSession(inTab: tab.id), let si = index[z] { zoomed[ti] = si }
            if tab.sessionIDs.count > 1, let name = tabName(tab) { names[ti] = name }
        }
        let layout = LayoutSnapshot(
            tabs: tabs.compactMap(encode),
            activeTab: tabs.firstIndex { $0.id == activeTabID },
            activeSession: activeID.flatMap { index[$0] },
            zoomed: zoomed,
            names: names.isEmpty ? nil : names)
        if let data = try? JSONEncoder().encode(layout) {
            UserDefaults.standard.set(data, forKey: Self.layoutKey)
        }
    }

    /// A live pane tree as a saved one, leaves named by `index` (session → position).
    private func encodePane(_ n: PaneNode, index: [UUID: Int]) -> LayoutSnapshot.Node? {
        switch n {
        case .leaf(_, let s):
            return index[s].map { .leaf($0) }
        case .branch(let id, let axis, let a, let b):
            switch (encodePane(a, index: index), encodePane(b, index: index)) {
            case (let x?, let y?):
                return .branch(vertical: axis == .vertical, ratio: Double(ratio(for: id)), first: x, second: y)
            case (let x?, nil): return x
            case (nil, let y?): return y
            case (nil, nil): return nil
            }
        }
    }

    private func pruneScrollback(keeping keys: Set<String>) {
        let dir = Self.scrollbackDir
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for f in files where f.hasSuffix(".txt") {
            let key = String(f.dropLast(4))
            if !keys.contains(key) { try? FileManager.default.removeItem(at: dir.appendingPathComponent(f)) }
        }
    }

    /// A restorable description of one live session.
    private func snapshot(of s: TerminalSession) -> SessionSnapshot {
        let kind: SessionSnapshot.Kind
        switch s.kind {
        case .ssh:        kind = .ssh
        case .sftp:       kind = .sftp
        case .localShell: kind = .local
        case .rdp:        kind = .rdp
        }
        var dir: String?
        if case .localShell = s.kind { dir = s.currentDirectory }
        let agentID = s.io.agent.flatMap { $0.runsLocally ? nil : $0.id }
        return SessionSnapshot(kind: kind, alias: s.alias, title: s.title,
                               scrollbackKey: s.scrollbackKey, manuallyRenamed: s.isManuallyRenamed,
                               directory: dir, agentID: agentID,
                               controlSocket: agentID != nil && kind == .ssh ? s.controlSocket : nil)
    }

    /// A fresh (not yet started) session for a snapshot; nil when its host is gone.
    private func makeSession(from snap: SessionSnapshot, store: HostStore, attachingTo agentID: UUID? = nil) -> TerminalSession? {
        let built: TerminalSession?
        switch snap.kind {
        case .ssh:
            built = store.hosts.first { $0.alias == snap.alias }.map { h in
                TerminalSession(kind: .ssh(alias: h.alias, password: store.password(for: h),
                                           sudoPassword: store.sudoPassword(for: h),
                                           autoSudo: h.autoSudo, args: h.launchArgTokens), title: snap.title,
                                sharingControlSocket: agentID != nil ? snap.controlSocket : nil,
                                attachingToAgent: agentID)
            }
        case .sftp:
            built = store.hosts.first { $0.alias == snap.alias }.map { h in
                TerminalSession(kind: .sftp(alias: h.alias, password: store.password(for: h),
                                            args: h.launchArgTokens), title: snap.title)
            }
        case .rdp:
            built = store.hosts.first { $0.alias == snap.alias && $0.isRDP }.map { h in
                TerminalSession(kind: .rdp(alias: h.alias, target: store.rdpTarget(for: h)), title: snap.title)
            }
        case .local:
            built = TerminalSession(kind: .localShell, title: snap.title,
                                    startDirectory: snap.directory.flatMap {
                                        FileManager.default.fileExists(atPath: $0) ? $0 : nil
                                    },
                                    attachingToAgent: agentID)
        }
        built?.isManuallyRenamed = snap.manuallyRenamed ?? false
        return built
    }

    /// Reopen (and reconnect) the sessions that were open at last quit. Runs once.
    /// SSH/SFTP sessions resolve their password from the Keychain via `store`.
    func restoreIfNeeded(store: HostStore) async {
        guard !didRestore else { return }
        didRestore = true
        guard let data = UserDefaults.standard.data(forKey: Self.persistKey),
              let snaps = try? JSONDecoder().decode([SessionSnapshot].self, from: data) else { return }
        // Sessions still running in the agent come back as they are: attach.
        // (Asked even with the setting now off, so nothing it holds is orphaned.)
        let held = snaps.contains { $0.agentID != nil }
        let alive = held || AgentClient.isEnabled ? Set(await AgentClient.shared.listSessions().map(\.id)) : []
        // Agent sessions no tab refers to (the app died before saving) can't
        // be reached again: end them rather than leave them running.
        for orphan in alive.subtracting(snaps.compactMap(\.agentID)) {
            AgentClient.shared.send(.control(.close(id: orphan)))
        }
        var restored: [TerminalSession?] = []
        for snap in snaps {
            let attach = snap.agentID.flatMap { alive.contains($0) ? $0 : nil }
            let built = makeSession(from: snap, store: store, attachingTo: attach)
            restored.append(built)
            guard let s = built else { continue }
            // Reuse the persisted key so we load THIS session's saved scrollback.
            if !snap.scrollbackKey.isEmpty { s.scrollbackKey = snap.scrollbackKey }
            // An attached session's screen is the agent's; no replay.
            if attach == nil { s.pendingScrollback = loadScrollback(s.scrollbackKey) }
            s.title = snap.title
            _ = spawn(s)                    // starts (start() replays scrollback first)
        }
        restoreLayout(restored)
        persist()
        // Focus is re-asserted from WirelineApp's .task after the pet window opens
        // (which grabs key status), so we don't fight it with a racing call here.
    }
}
