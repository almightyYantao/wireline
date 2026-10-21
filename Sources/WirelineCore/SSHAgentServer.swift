import Foundation
import Darwin

/// One key the agent can sign with. The private key is NOT held in memory: it is
/// loaded on demand via `loadKey`, and only after the authorizer said yes — so
/// key material only leaves the Keychain when the user has just approved a use.
public struct SSHAgentIdentity: Sendable {
    public let publicKeyBlob: Data
    public let comment: String
    public let loadKey: @Sendable () throws -> SSHPrivateKey

    public init(publicKeyBlob: Data, comment: String, loadKey: @escaping @Sendable () throws -> SSHPrivateKey) {
        self.publicKeyBlob = publicKeyBlob
        self.comment = comment
        self.loadKey = loadKey
    }

    public var fingerprint: String { SSHPrivateKey.fingerprint(of: publicKeyBlob) }
}

public enum SSHAgentServerError: Error, CustomStringConvertible {
    case pathTooLong(String)
    case inUse(String)
    case posix(String, Int32)

    public var description: String {
        switch self {
        case .pathTooLong(let p): return "Agent socket path too long: \(p)"
        case .inUse(let p): return "Another agent is already listening on \(p)"
        case .posix(let call, let err): return "\(call) failed: \(String(cString: strerror(err)))"
        }
    }
}

/// A minimal ssh-agent speaking the OpenSSH agent protocol over a Unix socket.
///
/// - REQUEST_IDENTITIES → our protected keys, merged with the upstream agent's
///   (the user's original `SSH_AUTH_SOCK`), so their existing keys never vanish.
/// - SIGN_REQUEST for one of our keys → `authorize(comment, fingerprint)`, then
///   sign in-process. For any other key → forwarded upstream.
/// - Anything else (add/remove identity, extensions, …) → forwarded upstream if
///   there is one, else FAILURE.
///
/// Each client connection is served on its own GCD thread with blocking I/O; the
/// async authorizer is bridged with a semaphore (never on the Swift cooperative
/// pool, so a long Touch ID prompt can't starve other tasks).
public final class SSHAgentServer: @unchecked Sendable {
    public typealias Authorizer = @Sendable (_ comment: String, _ fingerprint: String) async -> Bool

    public let socketPath: String
    public let upstreamPath: String?
    private let authorize: Authorizer

    private let lock = NSLock()
    private var identities: [SSHAgentIdentity] = []
    private var source: DispatchSourceRead?
    private let acceptQueue = DispatchQueue(label: "com.wireline.agent.accept")

    /// `sun_path` is 104 bytes on Darwin, including the trailing NUL.
    public static let maxSocketPathLength = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1

    public init(socketPath: String, upstreamPath: String?, authorize: @escaping Authorizer) {
        self.socketPath = socketPath
        // Never forward to ourselves (e.g. app launched from a shell already
        // pointing SSH_AUTH_SOCK at this socket) — that would loop forever.
        self.upstreamPath = (upstreamPath?.isEmpty ?? true) || upstreamPath == socketPath ? nil : upstreamPath
        self.authorize = authorize
    }

    public func setIdentities(_ ids: [SSHAgentIdentity]) {
        lock.lock(); identities = ids; lock.unlock()
    }

    private func snapshot() -> [SSHAgentIdentity] {
        lock.lock(); defer { lock.unlock() }
        return identities
    }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return source != nil
    }

    // MARK: - Lifecycle

    public func start() throws {
        guard !isRunning else { return }
        guard socketPath.utf8.count <= Self.maxSocketPathLength else {
            throw SSHAgentServerError.pathTooLong(socketPath)
        }
        let fm = FileManager.default
        let dir = (socketPath as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        chmod(dir, 0o700)

        // A socket file left by a crashed run is stale; one with a live listener
        // is someone else's agent — refuse rather than hijack it.
        if fm.fileExists(atPath: socketPath) {
            if let probe = try? Self.connect(to: socketPath) {
                close(probe)
                throw SSHAgentServerError.inUse(socketPath)
            }
            unlink(socketPath)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SSHAgentServerError.posix("socket", errno) }
        var addr = try Self.address(socketPath)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { let e = errno; close(fd); throw SSHAgentServerError.posix("bind", e) }
        chmod(socketPath, 0o600)
        guard listen(fd, 64) == 0 else {
            let e = errno; close(fd); unlink(socketPath); throw SSHAgentServerError.posix("listen", e)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        src.setEventHandler { [weak self] in
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }   // EAGAIN: drained
                _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
                var on: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                guard let self else { close(client); return }
                DispatchQueue.global(qos: .userInitiated).async { self.serve(client) }
            }
        }
        src.setCancelHandler { close(fd) }
        lock.lock(); source = src; lock.unlock()
        src.resume()
    }

    public func stop() {
        lock.lock()
        let src = source
        source = nil
        lock.unlock()
        guard let src else { return }
        src.cancel()
        unlink(socketPath)
    }

    deinit { stop() }

    // MARK: - Connection handling

    /// Per-client state: a lazily-opened connection to the upstream agent, kept
    /// for the client's lifetime so stateful upstream requests stay coherent.
    private final class Upstream {
        let path: String?
        var fd: Int32 = -1
        init(path: String?) { self.path = path }

        func request(_ msg: Data) -> Data? {
            guard let path else { return nil }
            if fd < 0 {
                guard let c = try? SSHAgentServer.connect(to: path) else { return nil }
                fd = c
            }
            guard SSHAgentServer.writeMessage(fd, msg), let reply = SSHAgentServer.readMessage(fd) else {
                close(); return nil
            }
            return reply
        }

        func close() {
            if fd >= 0 { Darwin.close(fd); fd = -1 }
        }
    }

    private func serve(_ fd: Int32) {
        let upstream = Upstream(path: upstreamPath)
        defer { upstream.close(); close(fd) }
        while let msg = Self.readMessage(fd), !msg.isEmpty {
            let reply = handle(msg, upstream: upstream)
            guard Self.writeMessage(fd, reply) else { return }
        }
    }

    private static let failureReply = Data([SSHAgentMessage.failure])

    private func handle(_ msg: Data, upstream: Upstream) -> Data {
        switch msg[msg.startIndex] {
        case SSHAgentMessage.requestIdentities:
            return identitiesAnswer(upstream: upstream)
        case SSHAgentMessage.signRequest:
            return sign(msg, upstream: upstream)
        default:
            return upstream.request(msg) ?? Self.failureReply
        }
    }

    private func identitiesAnswer(upstream: Upstream) -> Data {
        var entries: [(blob: Data, comment: String)] = snapshot().map { ($0.publicKeyBlob, $0.comment) }
        let own = Set(entries.map(\.blob))
        if let reply = upstream.request(Data([SSHAgentMessage.requestIdentities])),
           reply.first == SSHAgentMessage.identitiesAnswer {
            var r = SSHWireReader(reply.dropFirst())
            if let n = try? r.readUInt32() {
                for _ in 0..<n {
                    guard let blob = try? r.readString(), let comment = try? r.readString() else { break }
                    if !own.contains(blob) {
                        entries.append((blob, String(decoding: comment, as: UTF8.self)))
                    }
                }
            }
        }
        var w = SSHWireWriter()
        w.writeByte(SSHAgentMessage.identitiesAnswer)
        w.writeUInt32(UInt32(entries.count))
        for e in entries { w.writeString(e.blob); w.writeString(e.comment) }
        return w.data
    }

    private func sign(_ msg: Data, upstream: Upstream) -> Data {
        var r = SSHWireReader(msg.dropFirst())
        guard let blob = try? r.readString(), let payload = try? r.readString() else {
            return Self.failureReply
        }
        let flags = (try? r.readUInt32()) ?? 0
        guard let identity = snapshot().first(where: { $0.publicKeyBlob == blob }) else {
            return upstream.request(msg) ?? Self.failureReply
        }
        let authorize = self.authorize
        let comment = identity.comment, fingerprint = identity.fingerprint
        let allowed = Self.runBlocking { await authorize(comment, fingerprint) }
        guard allowed,
              let key = try? identity.loadKey(), key.publicKeyBlob == blob,
              let signature = try? key.sign(payload, flags: flags) else {
            return Self.failureReply
        }
        var w = SSHWireWriter()
        w.writeByte(SSHAgentMessage.signResponse)
        w.writeString(signature)
        return w.data
    }

    // MARK: - Plumbing

    private final class Box: @unchecked Sendable { var value = false }

    /// Wait on the calling (GCD) thread for an async result.
    private static func runBlocking(_ op: @escaping @Sendable () async -> Bool) -> Bool {
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Task {
            box.value = await op()
            done.signal()
        }
        done.wait()
        return box.value
    }

    static func address(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count <= maxSocketPathLength else { throw SSHAgentServerError.pathTooLong(path) }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }

    static func connect(to path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SSHAgentServerError.posix("socket", errno) }
        var addr = try address(path)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else { let e = errno; close(fd); throw SSHAgentServerError.posix("connect", e) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    private static func readFully(_ fd: Int32, _ count: Int) -> Data? {
        var buf = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress! + got, count - got) }
            if n > 0 { got += n }
            else if n < 0 && errno == EINTR { continue }
            else { return nil }
        }
        return Data(buf)
    }

    /// One length-prefixed agent message (without the length), or nil on EOF,
    /// error, or an oversized frame (which also ends the connection).
    static func readMessage(_ fd: Int32) -> Data? {
        guard let header = readFully(fd, 4) else { return nil }
        let len = header.reduce(0) { $0 << 8 | Int($1) }
        guard len <= SSHAgentMessage.maxMessageSize else { return nil }
        return len == 0 ? Data() : readFully(fd, len)
    }

    static func writeMessage(_ fd: Int32, _ body: Data) -> Bool {
        var w = SSHWireWriter()
        w.writeString(body)
        let frame = [UInt8](w.data)
        var sent = 0
        while sent < frame.count {
            let n = frame.withUnsafeBytes { write(fd, $0.baseAddress! + sent, frame.count - sent) }
            if n > 0 { sent += n }
            else if n < 0 && errno == EINTR { continue }
            else { return false }
        }
        return true
    }
}

/// Process-wide "is Wireline's agent running, and where" — read by every place
/// that spawns ssh/scp/sftp so the child gets `SSH_AUTH_SOCK` pointed at us.
public enum SSHAgentEnvironment {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var path: String?
    }
    private static let state = State()

    public static var socketPath: String? {
        get { state.lock.lock(); defer { state.lock.unlock() }; return state.path }
        set { state.lock.lock(); state.path = newValue; state.lock.unlock() }
    }

    /// Point a child environment at our agent (no-op while it isn't running).
    public static func apply(to env: inout [String: String]) {
        if let p = socketPath { env["SSH_AUTH_SOCK"] = p }
    }

    /// Same, for `KEY=value` arrays (SwiftTerm's PTY environment).
    public static func apply(to env: inout [String]) {
        guard let p = socketPath else { return }
        env.removeAll { $0.hasPrefix("SSH_AUTH_SOCK=") }
        env.append("SSH_AUTH_SOCK=\(p)")
    }
}
