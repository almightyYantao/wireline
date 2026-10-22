import Foundation
import XCTest
import WirelineCore
@testable import Wireline

/// The connect panel's model against a real `/usr/bin/ssh -v -E`: the log
/// file is tailed, the failing step found, ssh's own error echoed for the
/// terminal, and the log file removed afterwards. Uses only addresses that
/// fail without touching the network or any credentials.
@MainActor
final class ConnectProgressTests: XCTestCase {
    private func attempt(_ args: [String]) throws -> (ConnectProgress, [String], String) {
        let progress = ConnectProgress()
        var echoed: [String] = []
        progress.onUserFacingLine = { echoed.append($0) }
        let path = try XCTUnwrap(progress.begin())
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = ["-v", "-E", path, "-F", "/dev/null", "-o", "BatchMode=yes",
                       "-o", "ConnectTimeout=2"] + args + ["true"]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        let deadline = Date().addingTimeInterval(10)
        while p.isRunning, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        progress.processExited()
        return (progress, echoed, path)
    }

    func testRefusedFailsAtConnect() throws {
        let (progress, echoed, path) = try attempt(["-p", "1", "127.0.0.1"])
        XCTAssertEqual(progress.parser.status, .failed(.connect, .refused))
        XCTAssertEqual(progress.phase, .failed)
        XCTAssertTrue(progress.logsExpanded)
        XCTAssertEqual(progress.rows.first?.entry, .init(.resolve, "destination = 127.0.0.1:1"))
        XCTAssertEqual(progress.rows.last?.entry.isError, true)
        XCTAssertEqual(echoed, ["ssh: connect to host 127.0.0.1 port 1: Connection refused"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testUnresolvableFailsAtResolve() throws {
        let (progress, echoed, _) = try attempt(["nonexistent-host.invalid"])
        XCTAssertEqual(progress.parser.status, .failed(.resolve, .unresolvable))
        XCTAssertEqual(echoed.count, 1)
    }

    func testStopRemovesLogAndHides() throws {
        let progress = ConnectProgress()
        let path = try XCTUnwrap(progress.begin())
        XCTAssertEqual(progress.phase, .pending)
        progress.stop()
        XCTAssertEqual(progress.phase, .idle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }
}
