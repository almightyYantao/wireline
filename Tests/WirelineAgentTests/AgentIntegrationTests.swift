import XCTest
import Darwin
import WirelineCore
@testable import WirelineAgent

/// `wireline-agent serve` as a real process, driven over its socket the way
/// the app will: sessions outlive their client, a new client attaches to the
/// state they reached, the agent answers the program's queries.
@MainActor
final class AgentIntegrationTests: XCTestCase {
    private var dir: String!
    private var socketPath: String { dir + "/s.sock" }
    private var agent: Process?

    private var agentBinary: URL {
        Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("wireline-agent")
    }

    override func setUp() async throws {
        // Short: sun_path holds 104 bytes.
        dir = "/tmp/wl-agent-\(UUID().uuidString.prefix(8))"
        agent = try startAgent(idleExit: 30)
    }

    override func tearDown() async throws {
        agent?.terminate()
        agent?.waitUntilExit()
        try? FileManager.default.removeItem(atPath: dir)
    }

    private func startAgent(idleExit: Double) throws -> Process {
        let p = Process()
        p.executableURL = agentBinary
        p.arguments = ["serve", "--socket", socketPath, "--idle-exit", "\(idleExit)", "--foreground"]
        // Not the test's stdout: an agent left behind would hold `swift test`'s pipe open.
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        XCTAssertTrue(wait(5) { (try? AgentConnection.connect(path: self.socketPath)).map { close($0); return true } ?? false },
                      "agent listening")
        return p
    }

    @discardableResult
    private func wait(_ timeout: TimeInterval, until done: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if done() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return done()
    }

    /// A client that records everything it receives.
    final class Client {
        let conn: AgentConnection
        var frames: [AgentFrame] = []
        var closed = false
        init(path: String) throws {
            conn = AgentConnection(fd: try AgentConnection.connect(path: path), queue: .main)
            conn.onFrame = { [unowned self] in frames.append($0) }
            conn.onClose = { [unowned self] in closed = true }
            conn.start()
        }
        func send(_ c: AgentControl) { conn.send(.control(c)) }
        var controls: [AgentControl] { frames.compactMap { if case .control(let c) = $0 { c } else { nil } } }
        func output(_ id: UUID) -> String {
            String(decoding: frames.flatMap { f -> [UInt8] in
                if case let .output(fid, _, b) = f, fid == id { return b } else { return [] }
            }, as: UTF8.self)
        }
        /// Output frames must be contiguous, starting at `from`.
        func checkOffsets(_ id: UUID, from start: UInt64) -> Bool {
            var next = start
            for case let .output(fid, offset, b) in frames where fid == id {
                guard offset == next else { return false }
                next += UInt64(b.count)
            }
            return true
        }
    }

    private func connect() throws -> Client {
        let c = try Client(path: socketPath)
        c.send(.hello(proto: AgentProtocol.version, client: "tests"))
        XCTAssertTrue(wait(5) { c.controls.contains { if case .welcome = $0 { true } else { false } } }, "welcome")
        return c
    }

    private func shell(_ script: String? = nil) -> AgentSpawnSpec {
        AgentSpawnSpec(executable: "/bin/sh", args: script.map { ["-c", $0] } ?? ["-i"],
                       environment: ["PS1=wl$ ", "TERM=xterm-256color", "PATH=/usr/bin:/bin", "HOME=\(NSHomeDirectory())"],
                       currentDirectory: "/tmp", cols: 80, rows: 24)
    }

    func testSessionOutlivesClientAndReattachRestoresIt() throws {
        let id = UUID()
        let c1 = try connect()
        c1.send(.spawn(id: id, spec: shell(), keepAliveSeconds: nil))
        XCTAssertTrue(wait(5) { c1.output(id).contains("wl$ ") }, "prompt: \(c1.output(id))")
        c1.conn.send(.input(id: id, bytes: Array("echo one-\("$((1+1))")\r".utf8)))
        XCTAssertTrue(wait(5) { c1.output(id).contains("one-2") })
        XCTAssertTrue(c1.checkOffsets(id, from: 0))
        c1.conn.close()                                   // the app quits

        let c2 = try connect()
        c2.send(.list)
        XCTAssertTrue(wait(5) { c2.controls.contains { if case .sessions = $0 { true } else { false } } })
        guard case .sessions(let list)? = c2.controls.last(where: { if case .sessions = $0 { true } else { false } }) else { return XCTFail() }
        XCTAssertEqual(list.map(\.id), [id])
        XCTAssertEqual(list.first?.state, .running)
        XCTAssertEqual(list.first?.attached, false)

        // It keeps running with nobody watching.
        c2.conn.send(.input(id: id, bytes: Array("echo two-\("$((2+1))")\r".utf8)))
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        c2.send(.attach(id: id, cols: 100, rows: 30, cellWidth: 8, cellHeight: 16))
        XCTAssertTrue(wait(5) { c2.frames.contains { if case .snapshotHistory(_, true, _) = $0 { true } else { false } } }, "snapshot")
        var snap: [UInt8] = [], cut: UInt64 = 0
        for f in c2.frames {
            if case let .snapshotReady(_, offset, b) = f { snap += b; cut = offset }
            if case let .snapshotHistory(_, _, b) = f { snap += b }
        }
        let restored = try XCTUnwrap(VTTerminal(snapshot: snap), "snapshot decodes")
        let text = restored.plainText()
        XCTAssertTrue(text.contains("one-2"), text)
        XCTAssertTrue(text.contains("two-3"), "output while detached is in the snapshot: \(text)")
        XCTAssertGreaterThan(cut, 0)

        // Live again, continuing from the cut.
        c2.conn.send(.input(id: id, bytes: Array("echo three-\("$((3+1))")\r".utf8)))
        XCTAssertTrue(wait(5) { c2.output(id).contains("three-4") })
        XCTAssertTrue(c2.checkOffsets(id, from: cut), "offsets continue from the snapshot cut")

        c2.send(.close(id: id))
        c2.send(.list)
        XCTAssertTrue(wait(5) {
            if case .sessions(let l)? = c2.controls.last(where: { if case .sessions = $0 { true } else { false } }) { return l.isEmpty }
            return false
        }, "closed session is gone")
    }

    func testAgentAnswersQueries() throws {
        let id = UUID()
        let c = try connect()
        // Ask for a device status report (ESC [ 5 n → ESC [ 0 n) and print what came back.
        let script = #"stty -icanon -echo min 1; printf '\033[5n'; x=$(dd bs=1 count=4 2>/dev/null | od -An -c | tr -d ' \n'); echo "reply[$x]""#
        c.send(.spawn(id: id, spec: shell(script), keepAliveSeconds: nil))
        XCTAssertTrue(wait(5) { c.output(id).contains("reply[") }, c.output(id))
        XCTAssertTrue(c.output(id).contains(#"reply[033[0n]"#), c.output(id))
    }

    func testExitedSessionRespawnsInPlace() throws {
        let id = UUID()
        let c = try connect()
        c.send(.spawn(id: id, spec: shell("echo bye; exit 3"), keepAliveSeconds: nil))
        XCTAssertTrue(wait(5) { c.controls.contains(.exited(id: id, code: 3)) }, "\(c.controls)")
        c.send(.respawn(id: id, spec: shell("echo again")))
        XCTAssertTrue(wait(5) { c.output(id).contains("again") })
        XCTAssertTrue(c.output(id).contains("bye"))
        XCTAssertTrue(c.checkOffsets(id, from: 0), "one continuous stream across the restart")
    }

    func testRejectsOtherProtocolVersions() throws {
        let c = try Client(path: socketPath)
        c.send(.hello(proto: 999, client: "future"))
        XCTAssertTrue(wait(5) { c.closed })
        XCTAssertTrue(c.controls.contains { if case .failure = $0 { true } else { false } })
    }

    func testSingleInstanceAndIdleExit() throws {
        let second = try startAgent(idleExit: 30)       // same socket: steps aside at once
        XCTAssertTrue(wait(5) { !second.isRunning })
        XCTAssertEqual(second.terminationStatus, 0)
        XCTAssertEqual(agent?.isRunning, true)

        agent?.terminate(); agent?.waitUntilExit()
        let idle = try startAgent(idleExit: 0.5)       // nothing to do: leaves on its own
        agent = idle
        XCTAssertTrue(wait(5) { !idle.isRunning }, "idle agent exits")
    }
}
