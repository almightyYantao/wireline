import Foundation
import WirelineCore

/// The app's one connection to the session agent (docs/design/wireline-agent.md):
/// starts the agent when a session needs it, says hello, and routes frames to
/// each session's `AgentPTY`. Frames sent before the agent answers wait in an
/// outbox; if it can't be reached, every waiting session falls back to a PTY
/// in the app, so a terminal always opens.
@MainActor
final class AgentClient {
    static let shared = AgentClient()

    /// Whether new SSH and local sessions should live in the agent
    /// (Settings → 会话常驻 / `session-agent`).
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "sessionAgent") }
    /// How long a session lives with the app closed (nil: until it ends).
    static var keepAlive: Double? {
        let s = UserDefaults.standard.double(forKey: "sessionAgentKeepAlive")
        return s > 0 ? s : nil
    }

    private enum State { case idle, connecting, ready }
    private var state: State = .idle
    private var conn: AgentConnection?
    private var outbox: [AgentFrame] = []
    private var routes: [UUID: Weak] = [:]
    private var listWaiters: [([AgentSessionInfo]) -> Void] = []
    private var launchedAt: Date?
    var socketPath = AgentProtocol.socketPath

    private struct Weak { weak var pty: AgentPTY? }

    func register(_ pty: AgentPTY) { routes[pty.id] = Weak(pty: pty) }
    func unregister(_ id: UUID) { routes[id] = nil }

    func send(_ frame: AgentFrame) {
        if state == .ready, let conn {
            conn.send(frame)
        } else {
            outbox.append(frame)
            connect(launching: true)
        }
    }

    /// The agent's sessions, if an agent is running (it isn't started for this).
    func listSessions() async -> [AgentSessionInfo] {
        await withCheckedContinuation { cont in
            listWaiters.append { cont.resume(returning: $0) }
            if state == .ready {
                conn?.send(.control(.list))
            } else {
                connect(launching: false)
            }
        }
    }

    /// Drop the connection as quitting would (the agent keeps the sessions).
    /// The next send reconnects.
    func disconnect() {
        let c = conn
        conn = nil
        state = .idle
        c?.onClose = nil
        c?.close()
    }

    // MARK: Connecting

    private func connect(launching: Bool) {
        guard state == .idle else { return }
        state = .connecting
        attempt(until: Date().addingTimeInterval(launching ? 3 : 0.3), launching: launching)
    }

    private func attempt(until deadline: Date, launching: Bool) {
        if let fd = try? AgentConnection.connect(path: socketPath) {
            open(fd)
            return
        }
        if launching, launchedAt == nil || Date().timeIntervalSince(launchedAt!) > 10 { launchAgent() }
        guard Date() < deadline else { unavailable(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            MainActor.assumeIsolated { self?.attempt(until: deadline, launching: launching) }
        }
    }

    /// `wireline-agent serve`, next to the app's executable. It detaches itself
    /// (setsid) so it outlives the app.
    private func launchAgent() {
        launchedAt = Date()
        guard let bin = Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("wireline-agent"),
              FileManager.default.isExecutableFile(atPath: bin.path) else { return }
        let p = Process()
        p.executableURL = bin
        p.arguments = ["serve", "--socket", socketPath]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    private func open(_ fd: Int32) {
        let c = AgentConnection(fd: fd, queue: .main)
        c.onFrame = { [weak self] frame in MainActor.assumeIsolated { self?.received(frame) } }
        c.onClose = { [weak self] in MainActor.assumeIsolated { self?.lost() } }
        conn = c
        c.start()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        c.send(.control(.hello(proto: AgentProtocol.version, client: "Wireline \(version)")))
    }

    private func received(_ frame: AgentFrame) {
        switch frame {
        case .control(.welcome):
            state = .ready
            let pending = outbox
            outbox = []
            for f in pending { conn?.send(f) }
            if !listWaiters.isEmpty { conn?.send(.control(.list)) }
        case .control(.sessions(let list)):
            let waiters = listWaiters
            listWaiters = []
            waiters.forEach { $0(list) }
        case .control(.failure(nil, let message)):
            terminalLog.error("session agent: \(message, privacy: .public)")
        case .control(.failure(let id?, _)), .control(.spawned(let id, _)), .control(.exited(let id, _)),
             .control(.foreground(let id, _)):
            routes[id]?.pty?.received(frame)
        case let .output(id, _, _), let .snapshotReady(id, _, _), let .snapshotHistory(id, _, _):
            routes[id]?.pty?.received(frame)
        case .control, .input:
            break
        }
    }

    /// Never reached the agent: sessions waiting on it run in the app instead.
    private func unavailable() {
        terminalLog.error("session agent unreachable at \(self.socketPath, privacy: .public); sessions run in the app")
        state = .idle
        outbox = []
        let waiters = listWaiters
        listWaiters = []
        waiters.forEach { $0([]) }
        for r in routes.values { r.pty?.agentUnavailable() }
    }

    /// The connection dropped (the agent quit or crashed): its sessions are gone.
    private func lost() {
        let wasReady = state == .ready
        conn = nil
        state = .idle
        if !wasReady { unavailable(); return }
        for r in routes.values { r.pty?.agentLost() }
    }
}
