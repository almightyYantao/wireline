import Foundation
import os
import WirelineCore

let terminalLog = Logger(subsystem: "com.wireline.app", category: "terminal")

/// A session whose PTY the session agent owns: it outlives the app, and a
/// later launch attaches to it again (snapshot, then live output). Behaves
/// like `PTYProcess` to `TerminalIO`. If the agent can't be reached before
/// the process starts, it runs in a local `PTYProcess` instead.
@MainActor
final class AgentPTY: PTYBackend {
    /// The session's id in the agent (persisted with the tab).
    let id: UUID
    var onOutput: ((ArraySlice<UInt8>) -> Void)?
    var onExit: ((PTYTermination) -> Void)?
    /// A snapshot through READY: restore the screen from it (attach).
    var onSnapshotReady: (([UInt8]) -> Void)?
    /// Snapshot history records, after `onSnapshotReady`.
    var onSnapshotHistory: (([UInt8]) -> Void)?

    /// Files the agent deletes when the process ends (askpass scripts).
    var cleanupPaths: [String] = []
    var keepAlive: Double? = AgentClient.keepAlive
    var scrollbackBytes: Int? = 50_000_000

    private(set) var isRunning = false
    private(set) var pid: pid_t = 0
    nonisolated let windowSize = PTYWindowSize()
    /// The agent holds this session (spawned, or found at launch).
    private var existsInAgent: Bool
    private var expectedOffset: UInt64?
    private var foreground: PTYForegroundJob = .none
    private var theme: AgentTheme?
    /// The agent wasn't reachable: the process runs here.
    private var local: PTYProcess?
    private var pendingStart: (() throws -> Void)?
    private let client = AgentClient.shared

    /// `existing`: a session the agent already holds (attach to it with `attach`).
    init(id: UUID = UUID(), existing: Bool = false) {
        self.id = id
        self.existsInAgent = existing
        client.register(self)
        // libghostty resizes from its IO thread: forward in order, on main.
        let id = self.id
        windowSize.observe { size in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    AgentClient.shared.send(.control(.resize(id: id, cols: size.ws_col, rows: size.ws_row,
                                                             cellWidth: Self.cell(size.ws_xpixel, size.ws_col),
                                                             cellHeight: Self.cell(size.ws_ypixel, size.ws_row))))
                }
            }
        }
    }

    deinit {
        let id = self.id
        MainActor.assumeIsolated { AgentClient.shared.unregister(id) }
    }

    var runsLocally: Bool { local != nil }

    // MARK: PTYBackend

    func start(executable: String, args: [String], environment: [String],
               execName: String?, currentDirectory: String?, windowSize size: winsize?) throws {
        if let local {
            try local.start(executable: executable, args: args, environment: environment, execName: execName,
                            currentDirectory: currentDirectory, windowSize: size)
            return
        }
        if let size { windowSize.set(size) }
        let grid = windowSize.current ?? winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        let spec = AgentSpawnSpec(executable: executable, args: args, environment: environment, execName: execName,
                                  currentDirectory: currentDirectory, cols: grid.ws_col, rows: grid.ws_row,
                                  cellWidth: Self.cell(grid.ws_xpixel, grid.ws_col),
                                  cellHeight: Self.cell(grid.ws_ypixel, grid.ws_row),
                                  scrollbackBytes: scrollbackBytes, cleanup: cleanupPaths)
        // Kept for falling back to a local PTY if the agent never answers.
        pendingStart = { [weak self] in
            try self?.startLocally(executable: executable, args: args, environment: environment,
                                   execName: execName, currentDirectory: currentDirectory, size: size)
        }
        isRunning = true
        if existsInAgent {
            client.send(.control(.respawn(id: id, spec: spec)))
        } else {
            existsInAgent = true
            expectedOffset = 0
            client.send(.control(.spawn(id: id, spec: spec, keepAliveSeconds: keepAlive)))
        }
        if let theme { client.send(.control(.theme(id: id, theme: theme))) }
    }

    /// Attach to the agent's session: its screen arrives as a snapshot, then output.
    func attach() {
        isRunning = true
        let g = windowSize.current ?? winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        client.send(.control(.attach(id: id, cols: g.ws_col, rows: g.ws_row,
                                     cellWidth: Self.cell(g.ws_xpixel, g.ws_col),
                                     cellHeight: Self.cell(g.ws_ypixel, g.ws_row))))
        if let theme { client.send(.control(.theme(id: id, theme: theme))) }
    }

    func send(_ bytes: ArraySlice<UInt8>) {
        if let local { local.send(bytes); return }
        guard isRunning, !bytes.isEmpty else { return }
        client.send(.input(id: id, bytes: Array(bytes)))
    }

    func resize(_ size: winsize) {
        if let local { local.resize(size); return }
        windowSize.set(size)              // the observer tells the agent
    }

    func foregroundJob() -> PTYForegroundJob { local?.foregroundJob() ?? foreground }

    /// Stop the process, keep the agent's session (a reconnect respawns it).
    func terminate() {
        if let local { local.terminate(); return }
        guard isRunning else { return }
        isRunning = false
        client.send(.control(.hangup(id: id)))
    }

    /// The tab is closed: end the process and the agent's session.
    func close() {
        if let local { local.terminate(); return }
        isRunning = false
        if existsInAgent { client.send(.control(.close(id: id))) }
        existsInAgent = false
        client.unregister(id)
    }

    /// The colors the app draws with, for the agent's OSC 10/11/12 replies.
    func setTheme(_ theme: AgentTheme) {
        guard theme != self.theme else { return }
        self.theme = theme
        if local == nil, existsInAgent { client.send(.control(.theme(id: id, theme: theme))) }
    }

    // MARK: From the agent

    func received(_ frame: AgentFrame) {
        guard local == nil else { return }
        switch frame {
        case let .output(_, offset, bytes):
            if let expected = expectedOffset, offset != expected {
                // Lost or duplicated output: start over from a fresh snapshot.
                terminalLog.error("agent session \(self.id): output at \(offset), expected \(expected); re-attaching")
                expectedOffset = nil
                attach()
                return
            }
            expectedOffset = offset + UInt64(bytes.count)
            onOutput?(bytes[...])
        case let .snapshotReady(_, offset, bytes):
            expectedOffset = offset
            onSnapshotReady?(bytes)
        case let .snapshotHistory(_, _, bytes):
            onSnapshotHistory?(bytes)
        case .control(.spawned(_, let pid)):
            self.pid = pid
            pendingStart = nil
        case .control(.foreground(_, let job)):
            switch job {
            case .none: foreground = .none
            case .child: foreground = .child
            case .job(let name): foreground = .job(pgid: -1, name: name.map { ForegroundProcess.identify(reportedName: $0) })
            }
        case .control(.exited(_, let code)):
            guard isRunning else { return }
            isRunning = false
            pid = 0
            onExit?(.exited(code))
        case .control(.failure(_, let message)):
            terminalLog.error("agent session \(self.id): \(message, privacy: .public)")
            if message == "no such session" {
                // The agent forgot it (it restarted): a fresh one next time.
                existsInAgent = false
                if isRunning { isRunning = false; onExit?(.exited(-1)) }
            }
        default:
            break
        }
    }

    /// The agent never answered: run this session's process here.
    func agentUnavailable() {
        guard local == nil else { return }
        let start = pendingStart
        let p = PTYProcess()
        p.onOutput = { [weak self] in self?.onOutput?($0) }
        p.onExit = { [weak self] in self?.onExit?($0) }
        if let size = windowSize.current { p.resize(size) }
        local = p
        existsInAgent = false
        if let start {
            do { try start() } catch { isRunning = false; onExit?(.exited(127)) }
        } else if isRunning {
            isRunning = false                   // an attach: nothing to attach to
            onExit?(.exited(-1))
        }
    }

    /// The agent went away: its processes went with it.
    func agentLost() {
        existsInAgent = false
        guard isRunning else { return }
        isRunning = false
        pid = 0
        onExit?(.signaled(SIGHUP))
    }

    private func startLocally(executable: String, args: [String], environment: [String],
                              execName: String?, currentDirectory: String?, size: winsize?) throws {
        try local?.start(executable: executable, args: args, environment: environment, execName: execName,
                         currentDirectory: currentDirectory, windowSize: size ?? windowSize.current)
    }

    private nonisolated static func cell(_ px: UInt16, _ n: UInt16) -> UInt32 {
        n == 0 ? 0 : UInt32(px) / UInt32(n)
    }
}
