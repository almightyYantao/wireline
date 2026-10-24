import XCTest
import WirelineCore
@testable import Wireline

/// P4: tools that load on demand, and the job output buffer.
@MainActor
final class MCPToolsetTests: XCTestCase {

    override func setUp() async throws {
        PrivacyContext.passwordsForTesting = []
        AIConfig.shared.privacyLevel = .secrets
        MCPServerSettings.shared.enabled = true
    }

    override func tearDown() async throws {
        PrivacyContext.passwordsForTesting = nil
        MCPServerSettings.shared.enabled = false
    }

    private func names(_ conn: MCPServerConnection) -> Set<String> {
        Set(MCPServerTools.tools(for: conn).compactMap { $0["name"] as? String })
    }

    func testLoadingAddsToolsAndTellsTheClient() async {
        var sent: [String] = []
        let conn = MCPServerConnection { sent.append($0) }
        XCTAssertTrue(names(conn).contains("load_tools"))
        XCTAssertFalse(names(conn).contains("file_list"))
        XCTAssertFalse(names(conn).contains("call_loaded_tool"))

        let r = MCPServerTools.loadTools("files", conn: conn)
        XCTAssertFalse(r.isError)
        XCTAssertTrue(r.text.contains("file_delete"), "schemas come back for clients that don't refresh")
        XCTAssertTrue(names(conn).isSuperset(of: ["file_list", "file_upload", "call_loaded_tool"]))
        XCTAssertFalse(names(conn).contains("exec_start"))
        XCTAssertEqual(sent.compactMap { MCPBridge.decode($0)?["method"] as? String }, ["notifications/tools/list_changed"])

        _ = MCPServerTools.loadTools("all", conn: conn)
        XCTAssertTrue(names(conn).isSuperset(of: ["exec_start", "forward_create", "snippet_run", "host_add", "host_note_add"]))
        XCTAssertTrue(MCPServerTools.loadTools("bogus", conn: conn).isError)
    }

    func testEveryToolsetToolIsDispatched() {
        // A definition without a handler would answer "Unknown tool".
        for set in MCPServerTools.toolsets.map(\.name) {
            for d in MCPServerTools.toolsetDefinitions(set) {
                let name = d["name"] as! String
                XCTAssertTrue(MCPServerTools.isToolsetTool(name), name)
            }
        }
        XCTAssertFalse(MCPServerTools.isToolsetTool("session_exec"))
    }

    func testCallLoadedToolOnlyReachesToolsetTools() async {
        let conn = MCPServerConnection { _ in }
        _ = await conn.respond(to: ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [:]])
        let reply = await conn.respond(to: ["jsonrpc": "2.0", "id": 2, "method": "tools/call",
                                            "params": ["name": "call_loaded_tool",
                                                       "arguments": ["name": "file_write", "arguments": [:]]]])
        let result = reply?["result"] as? [String: Any]
        XCTAssertEqual(result?["isError"] as? Bool, true)
    }

    func testJobBufferKeepsTheTailAndReportsWhatWasSkipped() {
        let job = MCPJob(alias: "x", command: "true")
        job.append(Data("hello ".utf8))
        var r = job.read(since: nil)
        XCTAssertEqual(r.text, "hello ")
        XCTAssertEqual(r.next, 6)
        job.append(Data("world".utf8))
        r = job.read(since: nil)                 // continues where the last read stopped
        XCTAssertEqual(r.text, "world")
        XCTAssertEqual(job.read(since: 0).text, "hello world")

        job.append(Data(repeating: 0x41, count: MCPJob.cap))
        r = job.read(since: 0)
        XCTAssertEqual(r.skipped, 11)
        XCTAssertEqual(r.text.count, 64 * 1024)
        XCTAssertFalse(r.running)                // never started
    }
}
