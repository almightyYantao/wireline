import Foundation
import XCTest
@testable import WirelineCore

@MainActor
final class PTYProcessTests: XCTestCase {
    private var output: [UInt8] = []
    private var exits: [PTYTermination] = []
    private var text: String { String(decoding: output, as: UTF8.self) }

    private func make() -> PTYProcess {
        let p = PTYProcess()
        p.onOutput = { [unowned self] in output += $0 }
        p.onExit = { [unowned self] in exits.append($0) }
        return p
    }

    private static let size = winsize(ws_row: 30, ws_col: 100, ws_xpixel: 0, ws_ypixel: 0)
    private static let env = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin", "TERM=xterm-256color", "LANG=en_US.UTF-8"]

    private func sh(_ p: PTYProcess, _ script: String, env: [String] = env, argv0: String? = nil,
                    cwd: String? = nil, size: winsize = size) throws {
        try p.start(executable: "/bin/sh", args: ["-c", script], environment: env,
                    execName: argv0, currentDirectory: cwd, windowSize: size)
    }

    /// Spin the main run loop (deliveries are main-queue blocks).
    @discardableResult
    private func wait(_ timeout: TimeInterval = 10, until done: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if done() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return done()
    }

    private func openFDs() -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd")) ?? []).count
    }

    func testEchoRoundTrip() throws {
        let p = make()
        try sh(p, "read line; echo \"got:$line\"")
        XCTAssertTrue(p.isRunning)
        p.send(ArraySlice("hello pty\n".utf8))
        XCTAssertTrue(wait { !exits.isEmpty })
        XCTAssertTrue(text.contains("got:hello pty"), text)
        XCTAssertEqual(exits, [.exited(0)])
        XCTAssertFalse(p.isRunning)
        XCTAssertEqual(p.pid, 0)
    }

    func testExitStatus() throws {
        let p = make()
        try sh(p, "exit 7")
        XCTAssertTrue(wait { exits.count == 1 })
        try sh(p, "kill -TERM $$")
        XCTAssertTrue(wait { exits.count == 2 })
        XCTAssertEqual(exits, [.exited(7), .signaled(SIGTERM)])
        XCTAssertEqual(exits.map(\.code), [7, 128 + SIGTERM])
    }

    func testEnvironmentDirectoryAndArgv0() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = make()
        // With no operands after the command string, `$0` is argv[0].
        try sh(p, "echo \"[$0][$WL_FOO][$(pwd -P)][$(tty)]\"", env: Self.env + ["WL_FOO=bar baz"],
               argv0: "wl-argv0", cwd: dir.path)
        XCTAssertTrue(wait { !exits.isEmpty })
        let real = String(cString: realpath(dir.path, nil))
        XCTAssertTrue(text.contains("[wl-argv0][bar baz][\(real)][/dev/ttys"), text)
        // A missing directory is ignored, not fatal.
        try sh(p, "pwd", cwd: "/nonexistent/wireline")
        XCTAssertTrue(wait { exits.count == 2 })
        XCTAssertEqual(exits.last, .exited(0))
    }

    func testSpawnFailure() {
        let p = make()
        XCTAssertThrowsError(try p.start(executable: "/nonexistent/wl", args: [], environment: [],
                                         windowSize: Self.size))
        XCTAssertFalse(p.isRunning)
    }

    /// 1 MiB in many sends while the child echoes it straight back: both
    /// directions back up (EAGAIN, partial writes, reader backpressure) and
    /// every byte must come back in order.
    func testBigWriteOrdering() throws {
        let p = make()
        let n = 1 << 20
        try sh(p, "stty raw -echo && echo READY && head -c \(n) && echo && echo DONE")
        XCTAssertTrue(wait { text.contains("READY\n") })
        output.removeAll()
        var data = [UInt8](repeating: 0, count: n)
        for i in 0..<n { data[i] = UInt8(truncatingIfNeeded: (i &* 31) ^ (i >> 9)) }
        // Raw mode: no signals, no flow control, no output processing — any byte goes.
        var i = 0
        while i < n {
            let len = min(n - i, 1 + (i % 50_000))
            p.send(data[i ..< i + len])
            i += len
        }
        XCTAssertTrue(wait(30) { !exits.isEmpty })
        XCTAssertEqual(exits, [.exited(0)])
        XCTAssertGreaterThanOrEqual(output.count, n)
        XCTAssertTrue(Array(output.prefix(n)) == data, "echoed bytes differ")
        XCTAssertTrue(String(decoding: output.suffix(from: n), as: UTF8.self).contains("DONE"))
    }

    /// Output written just before exiting is all delivered, before the status.
    func testOutputDrainedBeforeExit() throws {
        let p = make()
        var countAtExit = -1
        p.onExit = { [unowned self] in countAtExit = output.count; exits.append($0) }
        try sh(p, "stty -opost; head -c 300000 /dev/zero | tr '\\0' a; exit 3")
        XCTAssertTrue(wait { !exits.isEmpty })
        XCTAssertEqual(exits, [.exited(3)])
        XCTAssertEqual(countAtExit, 300_000)
        XCTAssertTrue(output.allSatisfy { $0 == UInt8(ascii: "a") })
    }

    func testResize() throws {
        let p = make()
        try sh(p, "stty size; read x; stty size")
        XCTAssertTrue(wait { text.contains("30 100") }, text)
        p.resize(winsize(ws_row: 41, ws_col: 123, ws_xpixel: 0, ws_ypixel: 0))
        p.send(ArraySlice("\n".utf8))
        XCTAssertTrue(wait { !exits.isEmpty })
        XCTAssertTrue(text.contains("41 123"), text)
    }

    /// The child leads a session whose controlling terminal is the PTY, so
    /// the shell's jobs show up as the foreground process group.
    func testForegroundJob() throws {
        let p = make()
        try p.start(executable: "/bin/sh", args: ["-i"], environment: Self.env + ["PS1=wl$ "],
                    windowSize: Self.size)
        XCTAssertTrue(wait { text.contains("wl$ ") }, text)
        XCTAssertEqual(p.foregroundJob(), .child)
        p.send(ArraySlice("sleep 3\n".utf8))
        XCTAssertTrue(wait(5) {
            if case .job(_, "sleep") = p.foregroundJob() { return true } else { return false }
        })
        p.send(ArraySlice([0x03]))                      // ^C: the tty signals the job
        XCTAssertTrue(wait(5) { p.foregroundJob() == .child })
        p.send(ArraySlice("exit 4\n".utf8))
        XCTAssertTrue(wait { !exits.isEmpty })
        XCTAssertEqual(exits, [.exited(4)])
        XCTAssertEqual(p.foregroundJob(), .none)
    }

    func testRestartAfterExit() throws {
        let p = make()
        try sh(p, "echo one")
        XCTAssertTrue(wait { exits.count == 1 })
        XCTAssertFalse(p.isRunning)
        try sh(p, "echo two; exit 2")
        XCTAssertTrue(p.isRunning)
        XCTAssertTrue(wait { exits.count == 2 })
        XCTAssertEqual(exits, [.exited(0), .exited(2)])
        XCTAssertTrue(text.contains("one") && text.contains("two"), text)
    }

    /// terminate(): nothing more is delivered, the child is reaped, its fds
    /// close, and a new child starts at once (reconnect).
    func testTerminateAndRestart() throws {
        let p = make()
        try sh(p, "echo started; sleep 100")
        XCTAssertTrue(wait { text.contains("started") })
        let old = p.pid
        p.terminate()
        XCTAssertFalse(p.isRunning)
        try sh(p, "echo replacement")
        XCTAssertTrue(wait { !exits.isEmpty })
        XCTAssertEqual(exits, [.exited(0)], "only the new child reports")
        XCTAssertTrue(wait(5) { kill(old, 0) == -1 && errno == ESRCH }, "old child reaped")
    }

    /// A child that ignores SIGHUP gets SIGKILL after the grace period.
    func testTerminateEscalatesToKill() throws {
        let p = make()
        p.terminateGrace = 0.3
        try sh(p, "trap '' HUP; echo armed; while :; do sleep 0.1; done")
        XCTAssertTrue(wait { text.contains("armed") })
        let pid = p.pid
        p.terminate()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        XCTAssertEqual(kill(pid, 0), 0, "still alive within the grace period")
        XCTAssertTrue(wait(5) { kill(pid, 0) == -1 && errno == ESRCH }, "killed and reaped")
        XCTAssertTrue(exits.isEmpty)
    }

    func testNoFDLeak() throws {
        let before = openFDs()
        for round in 0..<5 {
            let p = make()
            try sh(p, "echo round \(round)")
            XCTAssertTrue(wait { exits.count == round + 1 })
        }
        do {
            let p = make()
            try sh(p, "sleep 100")
            p.terminate()
        }
        do {    // dropped without terminate: deinit stops it
            let p = make()
            try sh(p, "sleep 100")
        }
        XCTAssertTrue(wait(5) { openFDs() == before }, "fds before \(before), after \(openFDs())")
    }
}
