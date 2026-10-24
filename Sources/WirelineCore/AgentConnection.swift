import Foundation
import Darwin

/// One end of a session-agent socket: frames in and out over a non-blocking
/// Unix socket, on one dispatch queue. Writes are buffered and drained as the
/// peer reads; a peer that lets more than `maxBuffered` pile up is dropped
/// (a stuck client must not grow the agent without bound).
///
/// Every method and callback runs on `queue`.
public final class AgentConnection: @unchecked Sendable {
    public let fd: Int32
    private let queue: DispatchQueue
    private var reader = AgentFrameReader()
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var writeSuspended = true
    private var pending: [UInt8] = []
    private var pendingStart = 0
    public private(set) var isOpen = true

    public var onFrame: ((AgentFrame) -> Void)?
    /// The peer hung up, broke the protocol, or fell too far behind.
    public var onClose: (() -> Void)?
    public var maxBuffered = 256 << 20

    /// Take over a connected socket.
    public init(fd: Int32, queue: DispatchQueue) {
        self.fd = fd
        self.queue = queue
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit {
        // Dropped without close(): libdispatch traps on releasing a suspended source.
        readSource?.cancel()
        if let ws = writeSource {
            if writeSuspended { ws.resume() }
            ws.cancel()
        }
        if isOpen { Darwin.close(fd) }
    }

    public func start() {
        let rs = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        rs.setEventHandler { [weak self] in self?.readAvailable() }
        readSource = rs
        rs.resume()
        let ws = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        ws.setEventHandler { [weak self] in self?.flush() }
        writeSource = ws               // resumed only while something waits
    }

    public func send(_ frame: AgentFrame) {
        guard isOpen else { return }
        pending.append(contentsOf: frame.encoded())
        if pending.count - pendingStart > maxBuffered { close(); return }
        flush()
    }

    public func close() {
        guard isOpen else { return }
        isOpen = false
        readSource?.cancel()
        if let ws = writeSource {
            if writeSuspended { ws.resume() }   // a suspended source can't be cancelled cleanly
            ws.cancel()
        }
        readSource = nil
        writeSource = nil
        Darwin.close(fd)
        pending = []
        let cb = onClose
        onClose = nil
        onFrame = nil
        cb?()
    }

    /// The peer's uid (Unix sockets only).
    public var peerUID: uid_t? {
        var uid: uid_t = 0, gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 ? uid : nil
    }

    private func readAvailable() {
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while isOpen {
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                do {
                    for frame in try reader.feed(buf[0..<n]) {
                        onFrame?(frame)
                        if !isOpen { return }
                    }
                } catch {
                    close()
                    return
                }
            } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
                close()
                return
            } else if errno == EAGAIN {
                return
            }
        }
    }

    private func flush() {
        while isOpen, pendingStart < pending.count {
            let n = pending.withUnsafeBytes {
                write(fd, $0.baseAddress! + pendingStart, pending.count - pendingStart)
            }
            if n > 0 {
                pendingStart += n
            } else if n < 0, errno == EINTR {
                continue
            } else if n < 0, errno == EAGAIN {
                if writeSuspended { writeSuspended = false; writeSource?.resume() }
                return
            } else {
                close()
                return
            }
        }
        guard isOpen else { return }
        pending.removeAll(keepingCapacity: pending.count < 1 << 20)
        pendingStart = 0
        if !writeSuspended { writeSuspended = true; writeSource?.suspend() }
    }

    // MARK: Sockets

    public struct SocketError: Error, CustomStringConvertible {
        public let call: String
        public let code: Int32
        public var description: String { "\(call): \(String(cString: strerror(code)))" }
    }

    /// Connect to the agent's socket at `path`.
    public static func connect(path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError(call: "socket", code: errno) }
        var addr = try address(path)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard ok == 0 else {
            let e = errno
            Darwin.close(fd)
            throw SocketError(call: "connect", code: e)
        }
        return fd
    }

    /// Bind and listen on `path` (replacing a stale socket file).
    public static func listen(path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError(call: "socket", code: errno) }
        unlink(path)
        var addr = try address(path)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard ok == 0 else { let e = errno; Darwin.close(fd); throw SocketError(call: "bind", code: e) }
        chmod(path, 0o600)
        guard Darwin.listen(fd, 16) == 0 else { let e = errno; Darwin.close(fd); throw SocketError(call: "listen", code: e) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        return fd
    }

    private static func address(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { throw SocketError(call: "socket path too long", code: ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return addr
    }
}
