import Foundation

/// The session agent's wire protocol (docs/design/wireline-agent.md §4), shared
/// by `wireline-agent` and the app.
///
/// A connection is a stream of frames: `u32 length (big-endian) | u8 kind |
/// payload`, where length counts the kind byte and the payload. Control
/// messages are JSON (easy to extend and to read in a log); the hot paths —
/// keystrokes, PTY output, snapshot pieces — are binary.
public enum AgentProtocol {
    /// Bumped on an incompatible change; part of the socket's file name, so
    /// an older agent keeps serving its own sessions beside a newer one.
    public static let version = 1
    public static let socketName = "sessions-v\(version).sock"

    /// `~/Library/Application Support/Wireline/sessions`. Not `Wireline/agent.sock`:
    /// that's the Touch ID ssh-agent.
    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wireline/sessions", isDirectory: true)
    }

    public static var socketPath: String { directory.appendingPathComponent(socketName).path }

    /// Frames larger than this are a broken peer, not data.
    public static let maxFrame = 64 << 20
}

/// How to start a session's process (or restart it in place).
public struct AgentSpawnSpec: Codable, Equatable, Sendable {
    public var executable: String
    public var args: [String]
    public var environment: [String]
    public var execName: String?
    public var currentDirectory: String?
    public var cols: UInt16
    public var rows: UInt16
    public var cellWidth: UInt32
    public var cellHeight: UInt32
    /// Scrollback the agent's terminal keeps (the app's `scrollback-limit`).
    public var scrollbackBytes: Int?
    /// Files to delete when the session ends (askpass scripts).
    public var cleanup: [String]

    public init(executable: String, args: [String] = [], environment: [String] = [], execName: String? = nil,
                currentDirectory: String? = nil, cols: UInt16 = 80, rows: UInt16 = 24,
                cellWidth: UInt32 = 0, cellHeight: UInt32 = 0, scrollbackBytes: Int? = nil, cleanup: [String] = []) {
        self.executable = executable; self.args = args; self.environment = environment; self.execName = execName
        self.currentDirectory = currentDirectory; self.cols = cols; self.rows = rows
        self.cellWidth = cellWidth; self.cellHeight = cellHeight
        self.scrollbackBytes = scrollbackBytes; self.cleanup = cleanup
    }
}

/// What the agent reports about a session.
public struct AgentSessionInfo: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case running, exited }
    public var id: UUID
    public var state: State
    public var exitCode: Int32?
    public var pid: Int32
    /// OSC 0/2 title and OSC 7 directory, as the agent's terminal last saw them.
    public var title: String?
    public var directory: String?
    /// Somebody is attached right now.
    public var attached: Bool

    public init(id: UUID, state: State, exitCode: Int32? = nil, pid: Int32 = 0,
                title: String? = nil, directory: String? = nil, attached: Bool = false) {
        self.id = id; self.state = state; self.exitCode = exitCode; self.pid = pid
        self.title = title; self.directory = directory; self.attached = attached
    }
}

/// The terminal colors the agent uses to answer OSC 10/11/12 queries, as
/// `#rrggbb` — the attached app's theme.
public struct AgentTheme: Codable, Equatable, Sendable {
    public var foreground: String
    public var background: String
    public var cursor: String?
    public init(foreground: String, background: String, cursor: String? = nil) {
        self.foreground = foreground; self.background = background; self.cursor = cursor
    }
}

/// Who owns the session's terminal (local shells' busy state).
public enum AgentForeground: Codable, Equatable, Sendable {
    case none, child
    case job(name: String?)
}

/// JSON control messages, both directions.
public enum AgentControl: Codable, Equatable, Sendable {
    // client → agent
    case hello(proto: Int, client: String)
    case list
    /// Start a new session (`id` chosen by the client) and attach to it.
    case spawn(id: UUID, spec: AgentSpawnSpec, keepAliveSeconds: Double?)
    /// Restart an exited session's process in place (same screen).
    case respawn(id: UUID, spec: AgentSpawnSpec)
    /// Become the session's client: the agent answers with a snapshot, then output.
    case attach(id: UUID, cols: UInt16, rows: UInt16, cellWidth: UInt32, cellHeight: UInt32)
    case detach(id: UUID)
    case resize(id: UUID, cols: UInt16, rows: UInt16, cellWidth: UInt32, cellHeight: UInt32)
    case theme(id: UUID, theme: AgentTheme)
    /// How long a session lives with nobody attached (nil: until it ends).
    case keepAlive(id: UUID, seconds: Double?)
    /// End the process (SIGHUP, then SIGKILL) and forget the session.
    case close(id: UUID)

    // agent → client
    case welcome(proto: Int, agentVersion: String, snapshotFormat: UInt16)
    case sessions([AgentSessionInfo])
    case spawned(id: UUID, pid: Int32)
    case foreground(id: UUID, job: AgentForeground)
    case exited(id: UUID, code: Int32)
    case failure(id: UUID?, message: String)
}

/// One frame.
public enum AgentFrame: Equatable, Sendable {
    case control(AgentControl)
    /// client → agent: bytes for the session's process.
    case input(id: UUID, bytes: [UInt8])
    /// agent → client: PTY output; `offset` is the session's output byte count
    /// before these bytes, so the client can check nothing went missing.
    case output(id: UUID, offset: UInt64, bytes: [UInt8])
    /// agent → client on attach: the snapshot through READY, cut at `offset`.
    case snapshotReady(id: UUID, offset: UInt64, bytes: [UInt8])
    /// agent → client after `snapshotReady`: history records; `last` with FINISH.
    case snapshotHistory(id: UUID, last: Bool, bytes: [UInt8])

    enum Kind: UInt8 { case control = 1, input = 0x10, output, snapshotReady, snapshotHistory }

    public func encoded() -> [UInt8] {
        var body: [UInt8]
        switch self {
        case .control(let c):
            body = [Kind.control.rawValue] + ((try? JSONEncoder().encode(c)).map { [UInt8]($0) } ?? [])
        case let .input(id, bytes):
            body = [Kind.input.rawValue] + id.bytes + bytes
        case let .output(id, offset, bytes):
            body = [Kind.output.rawValue] + id.bytes + offset.bigEndianBytes + bytes
        case let .snapshotReady(id, offset, bytes):
            body = [Kind.snapshotReady.rawValue] + id.bytes + offset.bigEndianBytes + bytes
        case let .snapshotHistory(id, last, bytes):
            body = [Kind.snapshotHistory.rawValue] + id.bytes + [last ? 1 : 0] + bytes
        }
        return UInt32(body.count).bigEndianBytes + body
    }

    public enum DecodeError: Error, Equatable { case tooLarge(Int), malformed }

    /// Decode one frame body (kind byte + payload).
    static func decode(body: ArraySlice<UInt8>) throws -> AgentFrame {
        guard let first = body.first, let kind = Kind(rawValue: first) else { throw DecodeError.malformed }
        let p = body.dropFirst()
        func uuid(_ s: ArraySlice<UInt8>) throws -> UUID {
            guard s.count >= 16 else { throw DecodeError.malformed }
            return UUID(bytes: s.prefix(16))
        }
        func u64(_ s: ArraySlice<UInt8>) throws -> UInt64 {
            guard s.count >= 8 else { throw DecodeError.malformed }
            return s.prefix(8).reduce(0) { $0 << 8 | UInt64($1) }
        }
        switch kind {
        case .control:
            guard let c = try? JSONDecoder().decode(AgentControl.self, from: Data(p)) else { throw DecodeError.malformed }
            return .control(c)
        case .input:
            return .input(id: try uuid(p), bytes: Array(p.dropFirst(16)))
        case .output:
            return .output(id: try uuid(p), offset: try u64(p.dropFirst(16)), bytes: Array(p.dropFirst(24)))
        case .snapshotReady:
            return .snapshotReady(id: try uuid(p), offset: try u64(p.dropFirst(16)), bytes: Array(p.dropFirst(24)))
        case .snapshotHistory:
            guard p.count >= 17 else { throw DecodeError.malformed }
            return .snapshotHistory(id: try uuid(p), last: p[p.startIndex + 16] != 0, bytes: Array(p.dropFirst(17)))
        }
    }
}

/// Reassembles frames from a byte stream that arrives in arbitrary pieces.
public struct AgentFrameReader {
    private var buffer: [UInt8] = []
    private var start = 0

    public init() {}

    /// Add bytes; returns every frame now complete. Throws on a frame that
    /// can't be valid (the connection should be dropped).
    public mutating func feed(_ bytes: some Collection<UInt8>) throws -> [AgentFrame] {
        buffer.append(contentsOf: bytes)
        var frames: [AgentFrame] = []
        while buffer.count - start >= 4 {
            let len = buffer[start..<start + 4].reduce(0) { $0 << 8 | Int($1) }
            guard len > 0, len <= AgentProtocol.maxFrame else { throw AgentFrame.DecodeError.tooLarge(len) }
            guard buffer.count - start - 4 >= len else { break }
            frames.append(try AgentFrame.decode(body: buffer[(start + 4)..<(start + 4 + len)]))
            start += 4 + len
        }
        // Compact once the consumed prefix dominates.
        if start > 0, start >= buffer.count / 2 {
            buffer.removeFirst(start)
            start = 0
        }
        return frames
    }
}

private extension UUID {
    var bytes: [UInt8] { withUnsafeBytes(of: uuid) { Array($0) } }
    init(bytes: ArraySlice<UInt8>) {
        var u: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &u) { $0.copyBytes(from: bytes) }
        self.init(uuid: u)
    }
}

private extension FixedWidthInteger {
    var bigEndianBytes: [UInt8] { withUnsafeBytes(of: bigEndian) { Array($0) } }
}
