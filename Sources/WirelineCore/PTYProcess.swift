import Foundation
import Dispatch
import os

/// How a PTY child ended.
public enum PTYTermination: Sendable, Equatable {
    case exited(Int32)
    case signaled(Int32)

    /// Shell-style status: the exit code, or 128 + the signal.
    public var code: Int32 {
        switch self {
        case .exited(let c): c
        case .signaled(let s): 128 + s
        }
    }

    init(waitStatus s: Int32) {
        // <sys/wait.h>'s WIFEXITED / WEXITSTATUS / WTERMSIG are macros Swift can't import.
        let low = s & 0x7f
        self = low == 0 ? .exited((s >> 8) & 0xff) : .signaled(low)
    }
}

/// What owns the terminal right now (see `PTYProcess.foregroundJob`).
public enum PTYForegroundJob: Equatable, Sendable {
    /// No child, or its PTY is gone.
    case none
    /// The child itself (a shell at its prompt).
    case child
    /// Another process group — a job the shell is running.
    case job(pgid: pid_t, name: String?)
}

public struct PTYSpawnError: Error, Equatable {
    public let errno: Int32
}

/// A child process in a pseudo-terminal: Wireline's replacement for SwiftTerm's
/// `LocalProcess`.
///
/// Threads: the public API is main-actor. Each child gets a private serial
/// queue that owns the master fd — it reads (a read source), writes (a write
/// queue that waits out `EAGAIN` and partial writes, in order), and watches
/// for exit (a process source). Output reaches main through a `PTYMailbox`,
/// coalesced and in order; the exit status follows the last byte the child
/// wrote. `windowSize` keeps its own `dup` of the master for ioctls (window
/// size, foreground group), behind a lock, so neither main nor a renderer's
/// thread ever touches an fd the queue may be closing.
///
/// Spawning: `forkpty` (new session, the slave as controlling terminal — so
/// the shell gets SIGWINCH and job control), then in the child only a
/// prepared `posix_spawn(POSIX_SPAWN_SETEXEC)` that execs with default signals,
/// an empty mask and no fds but 0–2. No Swift code runs between fork and exec.
@MainActor
public final class PTYProcess {
    /// Output from the child, in order, on main.
    public var onOutput: ((ArraySlice<UInt8>) -> Void)?
    /// The child exited — after every byte of its output was delivered. Not
    /// called for a child stopped with `terminate()`.
    public var onExit: ((PTYTermination) -> Void)?

    public private(set) var isRunning = false
    /// The child's pid (0 when none). It leads its own session and process group.
    public private(set) var pid: pid_t = 0

    /// How long `terminate()` waits after SIGHUP before SIGKILL.
    public var terminateGrace: TimeInterval = 2

    /// The PTY's window size, settable from any thread; it outlives each
    /// child, so the next one starts at the latest size.
    public nonisolated let windowSize = PTYWindowSize()

    private var child: PTYChild?

    public init() {}

    /// Start `executable` in a new PTY. A no-op while a child is running.
    /// - Parameters:
    ///   - args: arguments after argv[0].
    ///   - execName: argv[0] (e.g. `-zsh` for a login shell); the executable path if nil.
    ///   - currentDirectory: ignored when it isn't a directory.
    ///   - size: the window size to start at (stored as `windowSize`); nil
    ///     keeps the last size set, or 80×24.
    public func start(executable: String, args: [String], environment: [String],
                      execName: String? = nil, currentDirectory: String? = nil,
                      windowSize size: winsize? = nil) throws {
        guard !isRunning else { return }
        if let size { windowSize.set(size) }
        let initial = windowSize.current ?? winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        let (pid, master) = try PTYSpawn.spawn(
            executable: executable, argv: [execName ?? executable] + args, env: environment,
            cwd: currentDirectory, size: initial)
        let mailbox = PTYMailbox()
        let child = PTYChild(pid: pid, fd: master, mailbox: mailbox, grace: terminateGrace,
                             notify: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.drain(mailbox) } }
        })
        self.child = child
        self.pid = pid
        windowSize.attach(fd: fcntl(master, F_DUPFD_CLOEXEC, 0), spawnedAt: initial)
        isRunning = true
        child.queue.async { child.activate() }
    }

    /// Bytes for the child, written in call order however the PTY backs up.
    public func send(_ bytes: ArraySlice<UInt8>) {
        guard let child, !bytes.isEmpty else { return }
        let copy = Array(bytes)
        child.queue.async { child.write(copy) }
    }

    /// TIOCSWINSZ (the child gets SIGWINCH). Same as `windowSize.set`.
    public func resize(_ size: winsize) { windowSize.set(size) }

    /// Who owns the terminal: the child itself, or a job it started.
    public func foregroundJob() -> PTYForegroundJob {
        guard let pgid = windowSize.withFD({ tcgetpgrp($0) }), pgid > 0 else { return .none }
        guard pgid != pid else { return .child }
        var buf = [CChar](repeating: 0, count: 64)
        let name = proc_name(pgid, &buf, UInt32(buf.count)) > 0
            ? String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) : nil
        return .job(pgid: pgid, name: name)
    }

    /// Stop the child: SIGHUP and hang up the PTY now, SIGKILL after
    /// `terminateGrace`. It's still reaped (no zombie) and its fds closed, but
    /// nothing more is delivered — `start` can run a new child right away.
    public func terminate() {
        guard let child else { return }
        detach()
        child.queue.async { child.terminate() }
    }

    private func detach() {
        child = nil
        isRunning = false
        pid = 0
        windowSize.detach()
    }

    /// Largest slice handed to `onOutput` at once, so a flood doesn't stall main.
    private static let maxDelivery = 256 * 1024

    private func drain(_ mailbox: PTYMailbox) {
        guard let child, child.mailbox === mailbox else { return }   // a terminated child's leftovers
        let batch = mailbox.take(max: Self.maxDelivery)
        if batch.resumeReading { child.queue.async { child.resumeReading() } }
        if !batch.bytes.isEmpty { onOutput?(batch.bytes[...]) }
        guard self.child === child else { return }                    // terminated from onOutput
        if batch.more {
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.drain(mailbox) } }
        } else if let exit = batch.exit {
            detach()
            onExit?(exit)
        }
    }

    deinit {
        if let child { child.queue.async { child.terminate() } }
        windowSize.detach()
    }
}

/// A PTY's window size: the latest size and an fd to apply it with, under one
/// lock, so it can be set from any thread (main, or a renderer's IO thread
/// that must resize the PTY in step with its grid) while children come and go.
public final class PTYWindowSize: Sendable {
    private struct State {
        var fd: Int32 = -1
        var size: winsize?
        var observer: (@Sendable (winsize) -> Void)?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    /// The last size set.
    public var current: winsize? { state.withLock { $0.size } }

    /// Remember `size` and give it to the running child's PTY, if any (TIOCSWINSZ
    /// only signals the child when the size actually changes).
    public func set(_ size: winsize) {
        state.withLock { s in
            s.size = size
            Self.apply(s)
            s.observer?(size)
        }
    }

    /// Hear every size set, on the setter's thread, under the lock (so in
    /// order) — for a PTY that lives in another process (the session agent).
    /// Must not block or call back into this object.
    public func observe(_ observer: (@Sendable (winsize) -> Void)?) {
        state.withLock { $0.observer = observer }
    }

    /// A new child's master (a dup this owns). If the size moved since the PTY
    /// was opened at `spawnedAt`, apply the newer one.
    func attach(fd: Int32, spawnedAt: winsize) {
        state.withLock { s in
            if s.fd >= 0 { close(s.fd) }
            s.fd = fd
            if let size = s.size, !Self.same(size, spawnedAt) { Self.apply(s) }
        }
    }

    func detach() {
        state.withLock { s in
            if s.fd >= 0 { close(s.fd) }
            s.fd = -1
        }
    }

    /// Run an ioctl-style query against the PTY; nil when there's no child.
    func withFD<T: Sendable>(_ body: @Sendable (Int32) -> T) -> T? {
        state.withLock { s in s.fd >= 0 ? body(s.fd) : nil }
    }

    private static func apply(_ s: State) {
        guard s.fd >= 0, var ws = s.size else { return }
        _ = ioctl(s.fd, TIOCSWINSZ, &ws)
    }

    private static func same(_ a: winsize, _ b: winsize) -> Bool {
        a.ws_row == b.ws_row && a.ws_col == b.ws_col && a.ws_xpixel == b.ws_xpixel && a.ws_ypixel == b.ws_ypixel
    }
}

// MARK: - Child (its queue)

/// The queue → main channel: output chunks, then the exit status. Coalesced:
/// at most one main-queue drain is scheduled at a time.
final class PTYMailbox: Sendable {
    /// Past this much undelivered output the reader pauses; the kernel buffer
    /// fills and the child blocks in write(), as in any terminal.
    static let highWater = 4 * 1024 * 1024
    static let lowWater = 1024 * 1024

    private struct State {
        var chunks: [[UInt8]] = []
        var bytes = 0
        var exit: PTYTermination?
        var scheduled = false
        var readerPaused = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Queue side. Returns whether a drain must be scheduled, and whether the
    /// reader should pause.
    func post(_ chunk: [UInt8]) -> (schedule: Bool, pause: Bool) {
        state.withLock { s in
            s.chunks.append(chunk)
            s.bytes += chunk.count
            let pause = s.bytes >= Self.highWater
            if pause { s.readerPaused = true }
            defer { s.scheduled = true }
            return (!s.scheduled, pause)
        }
    }

    /// Queue side: the last thing posted.
    func finish(_ exit: PTYTermination) -> Bool {
        state.withLock { s in
            s.exit = exit
            defer { s.scheduled = true }
            return !s.scheduled
        }
    }

    /// Main side.
    func take(max: Int) -> (bytes: [UInt8], exit: PTYTermination?, more: Bool, resumeReading: Bool) {
        state.withLock { s in
            var out: [UInt8] = []
            var n = 0
            while n < s.chunks.count, out.isEmpty || out.count + s.chunks[n].count <= max {
                if out.isEmpty { out = s.chunks[n] } else { out += s.chunks[n] }
                n += 1
            }
            s.chunks.removeFirst(n)
            s.bytes -= out.count
            let more = !s.chunks.isEmpty
            if !more { s.scheduled = false }
            let resume = s.readerPaused && s.bytes <= Self.lowWater
            if resume { s.readerPaused = false }
            return (out, more ? nil : s.exit, more, resume)
        }
    }
}

/// One child and its master fd. Every method runs on `queue`; the state is
/// also behind a lock (uncontended) so the compiler can check it.
final class PTYChild: Sendable {
    let pid: pid_t
    let mailbox: PTYMailbox
    let queue = DispatchQueue(label: "wireline.pty", qos: .userInteractive)
    private let fd: Int32
    private let grace: TimeInterval
    private let notify: @Sendable () -> Void

    private struct State {
        var read: (any DispatchSourceRead)?
        var readSuspended = false
        var readEOF = false
        var write: (any DispatchSourceWrite)?
        var writeSuspended = false
        var pending: [UInt8] = []
        var pendingHead = 0
        var exitSource: (any DispatchSourceProcess)?
        var killTimer: (any DispatchSourceTimer)?
        var liveSources = 0
        var ioShutDown = false
        var exited = false
        /// `terminate()` ran: nothing more goes to main.
        var detached = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    private static let readSize = 64 * 1024

    init(pid: pid_t, fd: Int32, mailbox: PTYMailbox, grace: TimeInterval, notify: @escaping @Sendable () -> Void) {
        self.pid = pid
        self.fd = fd
        self.mailbox = mailbox
        self.grace = grace
        self.notify = notify
    }

    func activate() {
        dispatchPrecondition(condition: .onQueue(queue))
        let read = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let write = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        let exit = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        // The sources hold the child (their handlers capture it) until cancelled.
        read.setEventHandler { self.readAvailable() }
        write.setEventHandler { self.flushWrites() }
        for source in [read, write] as [any DispatchSourceProtocol] {
            source.setCancelHandler { self.sourceCancelled() }
        }
        exit.setEventHandler { self.reap() }
        state.withLock { s in
            s.read = read
            s.write = write
            s.exitSource = exit
            s.liveSources = 2
            s.writeSuspended = true
        }
        read.activate()
        write.activate()
        write.suspend()             // until a write hits EAGAIN
        exit.activate()
        reap()                      // it may have exited before the source was armed
    }

    // MARK: Output

    private func readAvailable() {
        var buf = [UInt8](repeating: 0, count: Self.readSize)
        let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        if n > 0 {
            buf.removeSubrange(n...)
            let detached = state.withLock { $0.detached }
            guard !detached else { return }
            let (schedule, pause) = mailbox.post(buf)
            if schedule { notify() }
            if pause { pauseReading() }
        } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
            // EOF / EIO: nobody has the slave open any more. Stop reading; the
            // exit (process source) still comes.
            state.withLock { s in
                s.readEOF = true
                if !s.readSuspended, let r = s.read { r.suspend(); s.readSuspended = true }
            }
        }
    }

    private func pauseReading() {
        state.withLock { s in
            if !s.readSuspended, let r = s.read { r.suspend(); s.readSuspended = true }
        }
    }

    /// Main drained the backlog below the low-water mark.
    func resumeReading() {
        dispatchPrecondition(condition: .onQueue(queue))
        state.withLock { s in
            guard s.readSuspended, !s.readEOF, !s.ioShutDown, let r = s.read else { return }
            r.resume(); s.readSuspended = false
        }
    }

    // MARK: Input

    func write(_ bytes: [UInt8]) {
        dispatchPrecondition(condition: .onQueue(queue))
        let ok = state.withLock { s in
            guard !s.ioShutDown else { return false }
            s.pending += bytes
            return true
        }
        if ok { flushWrites() }
    }

    /// Write what's queued, in order; on EAGAIN wait for the write source.
    private func flushWrites() {
        state.withLock { s in
            guard !s.ioShutDown else { return }
            while s.pendingHead < s.pending.count {
                let n = s.pending.withUnsafeBytes { p in
                    Darwin.write(fd, p.baseAddress! + s.pendingHead, p.count - s.pendingHead)
                }
                if n > 0 { s.pendingHead += n; continue }
                if n < 0, errno == EINTR { continue }
                if n < 0, errno == EAGAIN {
                    // Compact what's been written, then wait for room.
                    if s.pendingHead > 0 { s.pending.removeFirst(s.pendingHead); s.pendingHead = 0 }
                    if s.writeSuspended, let w = s.write { w.resume(); s.writeSuspended = false }
                    return
                }
                break       // EIO etc.: the child is gone; drop the rest
            }
            s.pending.removeAll(); s.pendingHead = 0
            if !s.writeSuspended, let w = s.write { w.suspend(); s.writeSuspended = true }
        }
    }

    // MARK: Exit

    /// The process source fired (or `activate` checks): reap it if it exited,
    /// deliver the output still in the PTY, then the status.
    private func reap() {
        var status: Int32 = 0
        var r: pid_t
        repeat { r = waitpid(pid, &status, WNOHANG) } while r < 0 && errno == EINTR
        guard r != 0 else { return }    // still running
        let detached: Bool? = state.withLock { s in
            guard !s.exited else { return nil }
            s.exited = true
            return s.detached
        }
        guard let detached else { return }
        if !detached {
            // Whatever the child wrote before exiting is in the PTY buffer now.
            // Bounded: a leftover background job might keep writing.
            var drained = 0
            while drained < 4 * 1024 * 1024 {
                var buf = [UInt8](repeating: 0, count: Self.readSize)
                let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { break }
                buf.removeSubrange(n...)
                drained += n
                if mailbox.post(buf).schedule { notify() }
            }
            let exit = r > 0 ? PTYTermination(waitStatus: status) : .exited(-1)   // -1: reaped elsewhere (ECHILD)
            if mailbox.finish(exit) { notify() }
        }
        shutDownIO()
        state.withLock { s in
            s.killTimer?.cancel(); s.killTimer = nil
            s.exitSource?.cancel(); s.exitSource = nil
        }
    }

    /// SIGHUP now (and hang up the PTY), SIGKILL after the grace period.
    func terminate() {
        dispatchPrecondition(condition: .onQueue(queue))
        let proceed = state.withLock { s in
            guard !s.detached else { return false }
            s.detached = true
            return !s.exited
        }
        shutDownIO()
        guard proceed else { return }
        kill(pid, SIGHUP)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + grace)
        timer.setEventHandler {
            let alive = self.state.withLock { !$0.exited }
            if alive { kill(self.pid, SIGKILL) }
        }
        state.withLock { $0.killTimer = timer }
        timer.activate()
    }

    /// Stop reading and writing; the fd closes once both sources are cancelled.
    private func shutDownIO() {
        state.withLock { s in
            guard !s.ioShutDown else { return }
            s.ioShutDown = true
            s.pending = []; s.pendingHead = 0
            if let r = s.read { r.cancel(); if s.readSuspended { r.resume() } }
            if let w = s.write { w.cancel(); if s.writeSuspended { w.resume() } }
            s.readSuspended = false; s.writeSuspended = false
            s.read = nil; s.write = nil
        }
    }

    private func sourceCancelled() {
        let last = state.withLock { s in
            s.liveSources -= 1
            return s.liveSources == 0
        }
        if last { close(fd) }
    }
}

// MARK: - Spawn

enum PTYSpawn {
    /// A new PTY with `executable` on its slave as session leader and the slave
    /// as its controlling terminal. Returns the child's pid and the master fd
    /// (non-blocking, close-on-exec).
    ///
    /// `forkpty` makes the session and the controlling terminal (`login_tty`:
    /// setsid + TIOCSCTTY) — `posix_spawn` alone can't: its file actions run
    /// before POSIX_SPAWN_SETSID, so the slave it opens never becomes the
    /// controlling tty, and the shell then gets no SIGWINCH and no job control.
    /// The forked child then only calls a `posix_spawn` prepared here with
    /// POSIX_SPAWN_SETEXEC — it replaces itself in place with default signal
    /// handlers, an empty mask, no fds but 0–2, and the working directory set —
    /// or `_exit(127)`. Everything it touches is allocated before the fork, so
    /// no allocator, lock or Swift runtime call runs between fork and exec.
    static func spawn(executable: String, argv: [String], env: [String], cwd: String?,
                      size: winsize) throws -> (pid: pid_t, master: Int32) {
        // Fail here for the usual mistake; anything else exits 127 in the child.
        guard access(executable, X_OK) == 0 else { throw PTYSpawnError(errno: errno) }
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETEXEC | POSIX_SPAWN_CLOEXEC_DEFAULT
                                              | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        var all = sigset_t(), none = sigset_t()
        sigfillset(&all); sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attr, &all)
        posix_spawnattr_setsigmask(&attr, &none)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for fd: Int32 in 0...2 { posix_spawn_file_actions_addinherit_np(&actions, fd) }
        if let cwd, isDirectory(cwd) {
            if #available(macOS 26, *) {
                posix_spawn_file_actions_addchdir(&actions, cwd)
            } else {
                posix_spawn_file_actions_addchdir_np(&actions, cwd)
            }
        }

        let cExecutable = strdup(executable)
        let cArgv = cStrings(argv), cEnv = cStrings(env)
        let childPid = UnsafeMutablePointer<pid_t>.allocate(capacity: 1)
        defer {
            free(cExecutable)
            freeCStrings(cArgv); freeCStrings(cEnv)
            childPid.deallocate()
        }

        var master: Int32 = -1
        var ws = size
        let pid = forkpty(&master, nil, nil, &ws)
        if pid == 0 {
            // The child: nothing but the exec (see above).
            _ = posix_spawn(childPid, cExecutable, &actions, &attr, cArgv, cEnv)
            _exit(127)
        }
        guard pid > 0 else { throw PTYSpawnError(errno: errno) }
        // Not inherited by anything else this app spawns.
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        let flags = fcntl(master, F_GETFL)
        _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)
        return (pid, master)
    }

    private static func cStrings(_ strings: [String]) -> UnsafeMutablePointer<UnsafeMutablePointer<CChar>?> {
        let p = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: strings.count + 1)
        for (i, s) in strings.enumerated() { p[i] = strdup(s) }
        p[strings.count] = nil
        return p
    }

    private static func freeCStrings(_ p: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) {
        var i = 0
        while let s = p[i] { free(s); i += 1 }
        p.deallocate()
    }

    private static func isDirectory(_ path: String) -> Bool {
        var st = stat()
        return stat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }
}
