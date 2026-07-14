import AppKit
import Observation
import SwiftTerm
import WirelineCore

/// What a terminal session runs.
enum SessionKind {
    /// An SSH connection to a host alias.
    case ssh(alias: String, password: String?, autoSudo: Bool)
    /// An interactive SFTP file-transfer session to a host alias.
    case sftp(alias: String, password: String?)
    /// A plain local login shell (the user's `$SHELL`, e.g. zsh).
    case localShell
}

/// One live in-app terminal session. Owns the AppKit terminal view for its whole
/// lifetime so SwiftUI can embed/re-embed it without ever tearing down the PTY.
@MainActor
final class TerminalSession: Identifiable {
    let id = UUID()
    let kind: SessionKind
    var title: String
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
        case .ssh(let a, _, _): self.alias = a
        case .sftp(let a, _): self.alias = a
        case .localShell: self.alias = ""
        }
        let frame = CGRect(x: 0, y: 0, width: 800, height: 480)
        switch kind {
        case .ssh(_, let password, let autoSudo):
            self.terminalView = WirelineTerminalView(frame: frame, password: password, autoSudo: autoSudo)
        case .sftp, .localShell:
            self.terminalView = WirelineTerminalView(frame: frame, password: nil, autoSudo: false)
        }
    }

    func start() {
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        // Preserve the user's locale so remote/local shells render UTF-8 correctly.
        if let lang = ProcessInfo.processInfo.environment["LANG"] { env.append("LANG=\(lang)") }

        switch kind {
        case .ssh(let alias, let password, _):
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
                "-o", "ControlPersist=30",
                alias
            ]
            terminalView.startProcess(executable: "/usr/bin/ssh", args: args, environment: env)
            stats.start(socket: controlSocket, alias: alias)
        case .sftp(let alias, let password):
            if let password, !password.isEmpty, let script = Self.makeAskpassScript() {
                askpassURL = script
                env.append("SSH_ASKPASS=\(script.path)")
                env.append("SSH_ASKPASS_REQUIRE=force")
                env.append("WIRELINE_ASKPASS_PW=\(password)")
            }
            terminalView.startProcess(
                executable: "/usr/bin/sftp",
                args: ["-o", "StrictHostKeyChecking=accept-new", alias],
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
            kind: .ssh(alias: host.alias, password: password, autoSudo: host.autoSudo),
            title: host.alias))
    }

    /// Open an interactive SFTP file-transfer session for a host.
    @discardableResult
    func openSFTP(host: Host, password: String?) -> UUID {
        add(TerminalSession(kind: .sftp(alias: host.alias, password: password),
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
