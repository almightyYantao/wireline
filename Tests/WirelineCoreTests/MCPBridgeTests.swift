import XCTest
@testable import WirelineCore

/// The wire between `wireline-mcp` and the app: line framing, and what the
/// shim says by itself when the app can't be reached.
final class MCPBridgeTests: XCTestCase {

    func testSplitsLinesAcrossChunks() throws {
        var s = MCPBridge.LineSplitter()
        XCTAssertEqual(try s.feed(Array(#"{"a":1}"#.utf8) + [0x0A] + Array(#"{"b""#.utf8)), [#"{"a":1}"#])
        XCTAssertEqual(try s.feed(Array(#":2}"#.utf8) + [0x0D, 0x0A, 0x0A]), [#"{"b":2}"#])
        XCTAssertEqual(try s.feed([UInt8]()), [])
    }

    func testKeepsMultibyteCharactersWhole() throws {
        var s = MCPBridge.LineSplitter()
        let bytes = Array("{\"t\":\"主机\"}\n".utf8)
        var out: [String] = []
        for b in bytes { out += try s.feed([b]) }
        XCTAssertEqual(out, ["{\"t\":\"主机\"}"])
    }

    func testOverlongLineIsAnError() {
        var s = MCPBridge.LineSplitter()
        XCTAssertThrowsError(try s.feed([UInt8](repeating: 0x41, count: MCPBridge.LineSplitter.maxLine + 1)))
    }

    func testNegotiatesProtocolVersion() {
        XCTAssertEqual(MCPBridge.negotiate("2025-03-26"), "2025-03-26")
        XCTAssertEqual(MCPBridge.negotiate("1999-01-01"), MCPBridge.protocolVersions[0])
        XCTAssertEqual(MCPBridge.negotiate(nil), MCPBridge.protocolVersions[0])
    }

    private func reply(_ line: String) -> [String: Any]? {
        MCPBridge.offlineReply(to: line, reason: "app not running").flatMap(MCPBridge.decode)
    }

    func testOfflineServerExplainsItself() {
        let initialize = reply(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#)
        let result = initialize?["result"] as? [String: Any]
        XCTAssertEqual(result?["protocolVersion"] as? String, "2025-06-18")
        XCTAssertEqual(result?["instructions"] as? String, "app not running")

        let list = reply(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)?["result"] as? [String: Any]
        let tools = list?["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.compactMap { $0["name"] as? String }, ["wireline_status"])

        let call = reply(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"wireline_status"}}"#)?["result"] as? [String: Any]
        XCTAssertEqual(call?["isError"] as? Bool, true)
        let text = (call?["content"] as? [[String: Any]])?.first?["text"] as? String
        XCTAssertEqual(text, "app not running")
    }

    func testOfflineServerIgnoresNotificationsAndRejectsUnknownMethods() {
        XCTAssertNil(MCPBridge.offlineReply(to: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, reason: "x"))
        let err = reply(#"{"jsonrpc":"2.0","id":9,"method":"resources/list"}"#)?["error"] as? [String: Any]
        XCTAssertEqual(err?["code"] as? Int, MCPBridge.methodNotFound)
        XCTAssertNotNil(reply("not json")?["error"])
    }
}
