import XCTest
@testable import WirelineCore

/// What an MCP client may do without the user's OK, per mode.
final class MCPPolicyTests: XCTestCase {

    func testReadOnlyCommandsAlwaysRun() {
        for mode in MCPAccessMode.allCases {
            XCTAssertEqual(MCPPolicy.command("df -h", mode: mode), .allow, "\(mode)")
            XCTAssertEqual(MCPPolicy.command("uptime", mode: mode, hostCount: 40), .allow, "\(mode) fleet")
        }
    }

    func testWritesPerMode() {
        let cmd = "systemctl restart nginx"
        if case .deny = MCPPolicy.command(cmd, mode: .readOnly) {} else { XCTFail("read-only should deny") }
        XCTAssertEqual(MCPPolicy.command(cmd, mode: .confirm), .ask(dangerous: false))
        XCTAssertEqual(MCPPolicy.command(cmd, mode: .trust), .allow)
    }

    func testDangerousAlwaysAsks() {
        XCTAssertEqual(MCPPolicy.command("rm -rf /var/www", mode: .trust), .ask(dangerous: true))
        XCTAssertEqual(MCPPolicy.command("reboot", mode: .confirm), .ask(dangerous: true))
    }

    func testWideFleetWritesAskEvenInTrust() {
        XCTAssertEqual(MCPPolicy.command("apt-get update", mode: .trust, hostCount: MCPPolicy.wideFleet), .allow)
        XCTAssertEqual(MCPPolicy.command("apt-get update", mode: .trust, hostCount: MCPPolicy.wideFleet + 1), .ask(dangerous: false))
    }

    func testUnfilledPlaceholderIsRefused() {
        if case .deny = MCPPolicy.command("systemctl restart «service»", mode: .trust) {} else { XCTFail() }
    }

    func testFileWrite() {
        if case .deny = MCPPolicy.fileWrite(mode: .readOnly) {} else { XCTFail() }
        XCTAssertEqual(MCPPolicy.fileWrite(mode: .confirm), .ask(dangerous: false))
        XCTAssertEqual(MCPPolicy.fileWrite(mode: .trust), .allow)
    }

    func testAlwaysAskAndMinor() {
        if case .deny = MCPPolicy.alwaysAsk(mode: .readOnly) {} else { XCTFail() }
        XCTAssertEqual(MCPPolicy.alwaysAsk(mode: .trust), .ask(dangerous: false))
        XCTAssertEqual(MCPPolicy.alwaysAsk(mode: .confirm, dangerous: true), .ask(dangerous: true))
        if case .deny = MCPPolicy.minor(mode: .readOnly) {} else { XCTFail() }
        XCTAssertEqual(MCPPolicy.minor(mode: .confirm), .allow)
    }

    func testDiff() {
        let old = "a\nb\nc\nd\ne\nf\ng\nh\ni\nj"
        let new = "a\nb\nc\nd\nE\nf\ng\nh\ni\nj\nk"
        XCTAssertEqual(LineDiff.unified(old: old, new: new, context: 1), "  d\n- e\n+ E\n  f\n…\n  j\n+ k")
        XCTAssertEqual(LineDiff.summary(old: old, new: new), "+2 −1")
        XCTAssertEqual(LineDiff.unified(old: old, new: old), "")
        XCTAssertEqual(LineDiff.unified(old: "", new: "x"), "- \n+ x")
    }
}
