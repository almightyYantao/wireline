import Foundation
import WirelineCore

/// One session in the agent: the process in its PTY, the headless terminal
/// that has seen every byte it printed, and the client (if any) watching it.
///
/// Main actor, like `PTYProcess`: the agent is single-threaded, so the PTY
/// output, the terminal, and an attach's snapshot cut are always in order —
/// a snapshot at offset N is exactly the state after the first N bytes.
@MainActor
final class AgentSession {
    let id: UUID
    private(set) var spec: AgentSpawnSpec
    private let process = PTYProcess()
    private let vt: VTTerminal
    /// PTY output bytes so far (fed to `vt`, and to the client as offsets).
    private(set) var offset: UInt64 = 0
    private(set) var exitCode: Int32?
    /// The attached client's connection.
    private(set) weak var client: AgentConnection?
    /// With nobody attached, end after this long (nil: never).
    var keepAlive: Double? { didSet { scheduleKeepAlive() } }
    private var keepAliveWork: DispatchWorkItem?
    private var lastForeground: AgentForeground?
    /// Released (process gone and nobody will ask for it again).
    var onRelease: ((AgentSession) -> Void)?

    /// An exited session nobody looks at is kept this long, then released.
    static let exitedRetention: TimeInterval = 24 * 3600

    init?(id: UUID, spec: AgentSpawnSpec, keepAlive: Double?) {
        guard let vt = VTTerminal(cols: spec.cols, rows: spec.rows) else { return nil }
        self.id = id
        self.spec = spec
        self.vt = vt
        self.keepAlive = keepAlive
        if let bytes = spec.scrollbackBytes { vt.setScrollback(bytes: bytes) }
        vt.resize(cols: spec.cols, rows: spec.rows, cellWidth: spec.cellWidth, cellHeight: spec.cellHeight)
        // The agent answers the program's queries: clients don't (their
        // surfaces run with replies off), and nobody may be attached.
        vt.onReply = { [weak self] bytes in self?.process.send(bytes[...]) }
        process.onOutput = { [weak self] in self?.received($0) }
        process.onExit = { [weak self] in self?.exited($0.code) }
    }

    var pid: Int32 { process.pid }
    var isRunning: Bool { process.isRunning }

    var info: AgentSessionInfo {
        AgentSessionInfo(id: id, state: process.isRunning ? .running : .exited, exitCode: exitCode, pid: process.pid,
                         title: vt.title, directory: vt.reportedDirectory, attached: client != nil)
    }

    func start() throws {
        exitCode = nil
        try process.start(executable: spec.executable, args: spec.args, environment: spec.environment,
                          execName: spec.execName, currentDirectory: spec.currentDirectory,
                          windowSize: winsize(ws_row: spec.rows, ws_col: spec.cols,
                                              ws_xpixel: UInt16(clamping: UInt32(spec.cols) * spec.cellWidth),
                                              ws_ypixel: UInt16(clamping: UInt32(spec.rows) * spec.cellHeight)))
    }

    /// Restart an exited session's process in place: same terminal, same offsets.
    func respawn(_ spec: AgentSpawnSpec) throws {
        guard !process.isRunning else { return }
        self.spec = spec
        try start()
    }

    // MARK: Client

    /// Become `conn`'s session; it gets the state at this exact point
    /// (snapshot through READY, then history), then live output.
    func attach(_ conn: AgentConnection, cols: UInt16, rows: UInt16, cellWidth: UInt32, cellHeight: UInt32) {
        if let old = client, old !== conn {
            old.send(.control(.failure(id: id, message: "attached elsewhere")))
        }
        client = conn
        keepAliveWork?.cancel(); keepAliveWork = nil
        // Size first, so the snapshot is already at the client's grid.
        resize(cols: cols, rows: rows, cellWidth: cellWidth, cellHeight: cellHeight)
        guard let snap = vt.snapshot(), let parts = try? SnapshotFraming.split(snap) else {
            conn.send(.control(.failure(id: id, message: "couldn't snapshot the terminal")))
            return
        }
        conn.send(.snapshotReady(id: id, offset: offset, bytes: parts.ready))
        for (i, chunk) in parts.history.enumerated() {
            conn.send(.snapshotHistory(id: id, last: i == parts.history.count - 1, bytes: chunk))
        }
        lastForeground = nil
        if let exitCode { conn.send(.control(.exited(id: id, code: exitCode))) }
    }

    /// The client that just spawned this session follows it from offset 0.
    func adopt(_ conn: AgentConnection) {
        client = conn
        keepAliveWork?.cancel(); keepAliveWork = nil
    }

    func detach(_ conn: AgentConnection) {
        guard client === conn || client == nil else { return }
        client = nil
        scheduleKeepAlive()
    }

    func input(_ bytes: [UInt8]) { process.send(bytes[...]) }

    func resize(cols: UInt16, rows: UInt16, cellWidth: UInt32, cellHeight: UInt32) {
        guard cols > 0, rows > 0 else { return }
        spec.cols = cols; spec.rows = rows; spec.cellWidth = cellWidth; spec.cellHeight = cellHeight
        vt.resize(cols: cols, rows: rows, cellWidth: cellWidth, cellHeight: cellHeight)
        process.resize(winsize(ws_row: rows, ws_col: cols,
                               ws_xpixel: UInt16(clamping: UInt32(cols) * cellWidth),
                               ws_ypixel: UInt16(clamping: UInt32(rows) * cellHeight)))
    }

    func setTheme(_ theme: AgentTheme) {
        guard let fg = Self.rgb(theme.foreground), let bg = Self.rgb(theme.background) else { return }
        vt.setColors(foreground: fg, background: bg, cursor: theme.cursor.flatMap(Self.rgb))
    }

    /// Who owns the terminal; sent to the client when it changes.
    func pollForeground() {
        guard let client, process.isRunning else { return }
        let fg: AgentForeground
        switch process.foregroundJob() {
        case .none: fg = .none
        case .child: fg = .child
        case .job(let pgid, let name): fg = .job(name: ForegroundName.identify(pgid) ?? name)
        }
        guard fg != lastForeground else { return }
        lastForeground = fg
        client.send(.control(.foreground(id: id, job: fg)))
    }

    /// End the process but keep the session (its screen) for a respawn.
    func hangup() {
        process.terminate()
        cleanUp()
    }

    /// End it now: the process (SIGHUP, then SIGKILL) and the session.
    func close() {
        keepAliveWork?.cancel(); keepAliveWork = nil
        process.terminate()
        cleanUp()
        onRelease?(self)
    }

    // MARK: PTY

    private func received(_ bytes: ArraySlice<UInt8>) {
        bytes.withUnsafeBufferPointer { vt.write($0) }
        client?.send(.output(id: id, offset: offset, bytes: Array(bytes)))
        offset += UInt64(bytes.count)
    }

    private func exited(_ code: Int32) {
        exitCode = code
        cleanUp()
        client?.send(.control(.exited(id: id, code: code)))
        scheduleKeepAlive()
    }

    private func cleanUp() {
        for path in spec.cleanup { try? FileManager.default.removeItem(atPath: path) }
    }

    /// Detached: end a running session after `keepAlive`, forget an exited
    /// one after `exitedRetention`.
    private func scheduleKeepAlive() {
        keepAliveWork?.cancel(); keepAliveWork = nil
        guard client == nil else { return }
        let delay: TimeInterval
        if process.isRunning {
            guard let keepAlive else { return }
            delay = keepAlive
        } else {
            delay = Self.exitedRetention
        }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.client == nil else { return }
                AgentLog.write("session \(self.id) \(self.process.isRunning ? "kept alive long enough" : "exited and unclaimed"), closing")
                self.close()
            }
        }
        keepAliveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private static func rgb(_ hex: String) -> (UInt8, UInt8, UInt8)? {
        let h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        return (UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff))
    }
}

/// A job's program name: `claude`, `node`… (the app's `ForegroundProcess` does
/// the same for in-process PTYs).
enum ForegroundName {
    static func identify(_ pgid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pgid, &buf, UInt32(buf.count)) > 0 else { return nil }
        let path = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return (path as NSString).lastPathComponent
    }
}
