import XCTest
@testable import WirelineCore

final class AgentProtocolTests: XCTestCase {
    private let id = UUID()

    private var samples: [AgentFrame] {
        [
            .control(.hello(proto: 1, client: "Wireline 1.3")),
            .control(.spawn(id: id, spec: AgentSpawnSpec(executable: "/bin/zsh", args: ["-l"], environment: ["A=1"],
                                                         execName: "-zsh", cols: 120, rows: 40, cleanup: ["/tmp/x"]),
                            keepAliveSeconds: nil)),
            .control(.sessions([AgentSessionInfo(id: id, state: .exited, exitCode: 1, pid: 42, title: "t", directory: "/d")])),
            .control(.foreground(id: id, job: .job(name: "vim"))),
            .control(.failure(id: nil, message: "nope")),
            .input(id: id, bytes: Array("ls\r".utf8)),
            .output(id: id, offset: 1 << 40 | 7, bytes: [0x1b, 0x5b, 0x41]),
            .output(id: id, offset: 0, bytes: []),
            .snapshotReady(id: id, offset: 12345, bytes: Array("GHOSTSNP".utf8)),
            .snapshotHistory(id: id, last: true, bytes: [1, 2, 3]),
        ]
    }

    func testRoundTrip() throws {
        var reader = AgentFrameReader()
        let wire = samples.flatMap { $0.encoded() }
        XCTAssertEqual(try reader.feed(wire), samples)
    }

    func testReassemblesArbitraryPieces() throws {
        let wire = samples.flatMap { $0.encoded() }
        var reader = AgentFrameReader()
        var got: [AgentFrame] = []
        var i = 0, step = 1
        while i < wire.count {
            let end = min(wire.count, i + step)
            got += try reader.feed(wire[i..<end])
            i = end
            step = step % 7 + 1
        }
        XCTAssertEqual(got, samples)
    }

    func testRejectsBrokenFrames() {
        var reader = AgentFrameReader()
        XCTAssertThrowsError(try reader.feed([0xff, 0xff, 0xff, 0xff]))
        var r2 = AgentFrameReader()
        XCTAssertThrowsError(try r2.feed([0, 0, 0, 2, 0x99, 0]))          // unknown kind
        var r3 = AgentFrameReader()
        XCTAssertThrowsError(try r3.feed([0, 0, 0, 5, 0x10, 1, 2, 3, 4]))  // input without a full id
    }
}
