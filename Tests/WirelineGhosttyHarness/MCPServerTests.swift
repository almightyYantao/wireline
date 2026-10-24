import XCTest
import WirelineCore
@testable import Wireline

/// Wireline's MCP server: the protocol, the off switch, privacy on the way in
/// and out, and a real round trip through `wireline-mcp`.
@MainActor
final class MCPServerTests: XCTestCase {

    override func setUp() async throws {
        PrivacyContext.passwordsForTesting = ["Tr0ub4dor&3"]
        AIConfig.shared.privacyLevel = .secrets
        MCPServerSettings.shared.enabled = true
    }

    override func tearDown() async throws {
        PrivacyContext.passwordsForTesting = nil
        MCPServerSettings.shared.enabled = false
    }

    private func request(_ id: Int, _ method: String, _ params: [String: Any] = [:]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
    }

    private func initialized() async -> MCPServerConnection {
        let c = MCPServerConnection { _ in }
        _ = await c.respond(to: request(1, "initialize", ["protocolVersion": "2025-06-18",
                                                           "clientInfo": ["name": "claude-code", "version": "1"]]))
        return c
    }

    private func text(_ reply: [String: Any]?) -> (String, Bool) {
        let result = reply?["result"] as? [String: Any]
        let t = (result?["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        return (t, result?["isError"] as? Bool ?? false)
    }

    func testInitializeAdvertisesToolsAndInstructions() async {
        let c = MCPServerConnection { _ in }
        let reply = await c.respond(to: request(1, "initialize", ["protocolVersion": "2025-03-26",
                                                                   "clientInfo": ["name": "codex"]]))
        let result = reply?["result"] as? [String: Any]
        XCTAssertEqual(result?["protocolVersion"] as? String, "2025-03-26")
        XCTAssertEqual(((result?["capabilities"] as? [String: Any])?["tools"] as? [String: Any])?["listChanged"] as? Bool, true)
        XCTAssertTrue((result?["instructions"] as? String ?? "").contains("placeholders"))
        XCTAssertEqual(c.clientName, "codex")
    }

    func testOffShowsOnlyTheStatusTool() async {
        let c = await initialized()
        let on = (await c.respond(to: request(2, "tools/list"))?["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        XCTAssertEqual(Set(on?.compactMap { $0["name"] as? String } ?? []),
                       ["get_environment", "hosts_list", "session_read", "file_read",
                        "session_exec", "fleet_run", "host_open", "session_close", "file_write", "load_tools"])

        MCPServerSettings.shared.enabled = false
        let off = (await c.respond(to: request(3, "tools/list"))?["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        XCTAssertEqual(off?.compactMap { $0["name"] as? String }, ["wireline_status"])
        let (t, isError) = text(await c.respond(to: request(4, "tools/call", ["name": "hosts_list"])))
        XCTAssertTrue(isError)
        XCTAssertTrue(t.contains("没有开启"))
    }

    func testTogglingNotifiesConnectedClients() async {
        var sent: [String] = []
        let c = MCPServerConnection { sent.append($0) }
        c.notify("notifications/tools/list_changed")
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first.flatMap(MCPBridge.decode)?["method"] as? String, "notifications/tools/list_changed")
    }

    func testNotificationsGetNoReply() async {
        let c = await initialized()
        let none = await c.respond(to: ["jsonrpc": "2.0", "method": "notifications/initialized"])
        XCTAssertNil(none)
    }

    func testPlaceholdersFromElsewhereAreRefused() async {
        let c = await initialized()
        let (t, isError) = text(await c.respond(to: request(5, "tools/call",
            ["name": "file_read", "arguments": ["alias": "web", "path": "/etc/[WLzzzz_SECRET_1]"]])))
        XCTAssertTrue(isError)
        XCTAssertTrue(t.contains("[WLzzzz_SECRET_1]"))
    }

    func testPrivacyChangeNeedsAReconnect() async {
        let c = await initialized()
        AIConfig.shared.privacyLevel = .all
        let (t, isError) = text(await c.respond(to: request(6, "tools/call", ["name": "get_environment"])))
        XCTAssertTrue(isError)
        XCTAssertTrue(t.contains("reconnect"))
    }

    func testUnknownMethod() async {
        let c = await initialized()
        let err = await c.respond(to: request(7, "resources/list"))?["error"] as? [String: Any]
        XCTAssertEqual(err?["code"] as? Int, MCPBridge.methodNotFound)
    }

    // MARK: file_read's remote script, run against this Mac's sh

    private func runLocally(_ command: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", command]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    func testFileReadScriptRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wl-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("it's a \"file\".conf")
        let content = "server {\n  listen 80; # 注释\n}\n"
        try content.write(to: file, atomically: true, encoding: .utf8)

        let out = try runLocally(MCPServerTools.fileReadScript(path: file.path, maxBytes: 100_000))
        let parsed = MCPServerTools.parseFileRead(out)
        XCTAssertEqual(parsed?.size, content.utf8.count)
        XCTAssertEqual(parsed.map { String(decoding: $0.data, as: UTF8.self) }, content)

        let missing = try runLocally(MCPServerTools.fileReadScript(path: dir.appendingPathComponent("nope").path, maxBytes: 10))
        XCTAssertTrue(missing.contains("__WL_ERR__ no such file"))
        let directory = try runLocally(MCPServerTools.fileReadScript(path: dir.path, maxBytes: 10))
        XCTAssertTrue(directory.contains("__WL_ERR__ is a directory"))
    }

    func testCutOffReadDoesNotLookBinary() {
        let data = Data("主机列表".utf8).dropLast(1)          // ends mid-character
        XCTAssertEqual(MCPServerTools.decodeText(data, truncated: true), "主机列")
        XCTAssertNil(MCPServerTools.decodeText(data, truncated: false))
    }

    // MARK: Through the real shim

    /// The built `wireline-mcp`, beside the test bundle.
    private var shimURL: URL {
        Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("wireline-mcp")
    }

    func testRoundTripThroughWirelineMCP() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: shimURL.path), "wireline-mcp not built")
        // Short path: sun_path is 104 bytes.
        let socket = "/tmp/wl-mcp-test-\(getpid()).sock"
        defer { unlink(socket) }
        PeerIdentity.trustAny = true
        defer { PeerIdentity.trustAny = false }
        let server = MCPServerHost()
        server.start(path: socket)
        XCTAssertNil(server.lastError)

        let p = Process()
        p.executableURL = shimURL
        p.environment = ["WIRELINE_MCP_SOCKET": socket, "WIRELINE_AGENT_TRUST_ANY": "1"]
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = FileHandle.nullDevice
        try p.run()
        defer { if p.isRunning { p.terminate() } }

        let lines = [
            MCPBridge.encode(request(1, "initialize", ["protocolVersion": "2025-06-18", "clientInfo": ["name": "test"]])),
            MCPBridge.encode(["jsonrpc": "2.0", "method": "notifications/initialized"]),
            MCPBridge.encode(request(2, "tools/list"))
        ]
        stdin.fileHandleForWriting.write(Data((lines.joined(separator: "\n") + "\n").utf8))

        // Read two replies; the server runs on this (main) actor, so yield while waiting.
        let reader = stdout.fileHandleForReading
        var buffer = Data()
        let deadline = Date().addingTimeInterval(10)
        while buffer.split(separator: 0x0A).count < 2, Date() < deadline {
            let chunk = await Task.detached { reader.availableData }.value
            if chunk.isEmpty { break }
            buffer.append(chunk)
        }
        let replies = buffer.split(separator: 0x0A).compactMap { MCPBridge.decode(String(decoding: $0, as: UTF8.self)) }
        XCTAssertEqual(replies.count, 2)
        XCTAssertEqual(((replies.first?["result"] as? [String: Any])?["serverInfo"] as? [String: Any])?["name"] as? String,
                       "wireline")
        let tools = (replies.last?["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.count, MCPServerTools.definitions.count)
        stdin.fileHandleForWriting.closeFile()
    }

    func testShimAnswersOfflineWhenNothingListens() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: shimURL.path), "wireline-mcp not built")
        let p = Process()
        p.executableURL = shimURL
        p.environment = ["WIRELINE_MCP_SOCKET": "/tmp/wl-mcp-nobody-\(getpid()).sock"]
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = FileHandle.nullDevice
        try p.run()
        stdin.fileHandleForWriting.write(Data((MCPBridge.encode(request(1, "tools/list")) + "\n").utf8))
        stdin.fileHandleForWriting.closeFile()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let reply = MCPBridge.decode(String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        let tools = (reply?["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.compactMap { $0["name"] as? String }, ["wireline_status"])
    }
}
