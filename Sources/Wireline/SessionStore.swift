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
                execName: "-\(name)"
            )
        }
    }

    func terminate() {
        guard isRunning else { return }
        isRunning = false
        stats.stop()
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

/// Tracks all open terminal sessions. Shared across the app so a session opened
/// from Quick Connect or the menu bar shows up wherever windows are hosted.
@Observable
@MainActor
final class SessionStore {
    private(set) var sessions: [TerminalSession] = []
    /// The session currently shown in the main window's terminal pane.
    var activeID: UUID?

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
        session.store = self
        let id = session.id
        session.terminalView.onCloseRequested = { [weak self] in self?.close(id) }
        sessions.append(session)
        session.start()
        activeID = id
        return id
    }

    func session(_ id: UUID) -> TerminalSession? {
        sessions.first { $0.id == id }
    }

    var activeSession: TerminalSession? {
        guard let activeID else { return nil }
        return session(activeID)
    }

    /// Focus the Nth session (1-based), for ⌘1…⌘9. No-op if out of range.
    func selectIndex(_ n: Int) {
        guard sessions.indices.contains(n - 1) else { return }
        activeID = sessions[n - 1].id
    }

    func close(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].terminate()
        sessions.remove(at: index)
        // Move focus to a neighbouring session, if any.
        if activeID == id {
            activeID = sessions.indices.contains(index) ? sessions[index].id
                     : sessions.last?.id
        }
    }

    func closeAll() {
        sessions.forEach { $0.terminate() }
        sessions.removeAll()
    }
}
