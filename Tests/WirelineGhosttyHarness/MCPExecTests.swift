import XCTest
import WirelineCore
@testable import Wireline

/// P3: approvals, fleet targets, the remote write script and the audit log.
@MainActor
final class MCPExecTests: XCTestCase {

    override func tearDown() async throws {
        MCPApprovalCenter.shared.timeout = 120
        while let a = MCPApprovalCenter.shared.current { MCPApprovalCenter.shared.answer(a.id, .deny) }
    }

    private func approval() -> MCPApproval {
        MCPApproval(client: "test", title: "Run on web", subject: "systemctl restart nginx",
                    dangerous: false, canAlwaysAllow: true)
    }

    /// Answer whatever the center asks next, once it asks.
    private func answerNext(_ d: IslandDecision) {
        Task { @MainActor in
            while MCPApprovalCenter.shared.current == nil { try? await Task.sleep(for: .milliseconds(10)) }
            MCPApprovalCenter.shared.answer(MCPApprovalCenter.shared.current!.id, d)
        }
    }

    func testAllowAndDenyAndDontAskAgain() async {
        let conn = MCPServerConnection { _ in }
        if case .go(let a) = await MCPServerTools.gate(.allow, key: "k", conn: conn, approval) {
            XCTAssertEqual(a, "auto")
        } else { XCTFail("allow should go") }

        if case .stop(let o) = await MCPServerTools.gate(.deny("no"), key: "k", conn: conn, approval) {
            XCTAssertEqual(o.audit, "refused")
        } else { XCTFail("deny should stop") }

        answerNext(.deny)
        if case .stop(let o) = await MCPServerTools.gate(.ask(dangerous: false), key: "k", conn: conn, approval) {
            XCTAssertEqual(o.audit, "denied")
        } else { XCTFail("a denied ask should stop") }

        answerNext(.allowAlways)
        if case .go(let a) = await MCPServerTools.gate(.ask(dangerous: false), key: "k", conn: conn, approval) {
            XCTAssertEqual(a, "approved")
        } else { XCTFail() }
        // Same request again: no question this time.
        if case .go = await MCPServerTools.gate(.ask(dangerous: false), key: "k", conn: conn, approval) {} else { XCTFail() }
        XCTAssertNil(MCPApprovalCenter.shared.current)
        // A dangerous one always asks, even after "always".
        answerNext(.deny)
        if case .stop = await MCPServerTools.gate(.ask(dangerous: true), key: "k", conn: conn, approval) {} else { XCTFail() }
        // And "always" belongs to that connection only.
        answerNext(.deny)
        if case .stop = await MCPServerTools.gate(.ask(dangerous: false), key: "k", conn: MCPServerConnection { _ in }, approval) {} else { XCTFail() }
    }

    func testNoAnswerIsANo() async {
        MCPApprovalCenter.shared.timeout = 0.2
        let decision = await MCPApprovalCenter.shared.ask(approval())
        XCTAssertEqual(decision, .deny)
        XCTAssertNil(MCPApprovalCenter.shared.current)
    }

    func testQuestionsQueueOneAtATime() async {
        let center = MCPApprovalCenter.shared
        let a1 = approval(), a2 = approval()
        let first = Task { await center.ask(a1) }
        let second = Task { await center.ask(a2) }
        while center.queue.count < 2 { try? await Task.sleep(for: .milliseconds(10)) }
        let firstID = center.current!.id
        center.answer(firstID, .allow)
        XCTAssertNotEqual(center.current?.id, firstID)
        center.answer(center.current!.id, .deny)
        let (a, b) = (await first.value, await second.value)
        XCTAssertEqual(Set([a, b]), [.allow, .deny])
    }

    func testResolveTargets() {
        let hosts = [Host(alias: "web1", group: "prod"), Host(alias: "web2", group: "prod"),
                     Host(alias: "db", group: "prod"), Host(alias: "win", group: "prod", hostProtocol: .rdp),
                     Host(alias: "dev")]
        let r = MCPServerTools.resolveTargets(["@prod", "dev", "web1", "nope", "@empty"], hosts: hosts)
        XCTAssertEqual(r.aliases, ["web1", "web2", "db", "dev"])
        XCTAssertEqual(r.unknown, ["nope", "@empty"])
    }

    func testAuditNeverKeepsFileContents() {
        let s = MCPAudit.summarize(["alias": "web", "path": "/etc/app.conf", "content": "password=hunter22\n"])
        XCTAssertFalse(s.contains("hunter22"))
        XCTAssertTrue(s.contains("<18 bytes>"))
    }

    // MARK: file_write's remote script, against this Mac's sh

    private func run(_ command: String, input: String) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", command]
        let stdin = Pipe()
        p.standardInput = stdin
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        p.waitUntilExit()
        return p.terminationStatus
    }

    func testFileWriteScriptKeepsPermissionsAndCreatesFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wl-mcp-w-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let existing = dir.appendingPathComponent("it's.conf")
        try "old\n".write(to: existing, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: existing.path)
        XCTAssertEqual(try run(MCPServerTools.fileWriteScript(path: existing.path), input: "new 内容\n"), 0)
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "new 内容\n")
        let perms = try FileManager.default.attributesOfItem(atPath: existing.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o640)

        let fresh = dir.appendingPathComponent("fresh.txt")
        XCTAssertEqual(try run(MCPServerTools.fileWriteScript(path: fresh.path), input: "hello"), 0)
        XCTAssertEqual(try String(contentsOf: fresh, encoding: .utf8), "hello")

        let blocked = dir.appendingPathComponent("no-such-dir/x")
        XCTAssertNotEqual(try run(MCPServerTools.fileWriteScript(path: blocked.path), input: "x"), 0)
    }
}
