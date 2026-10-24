import Foundation

/// The pieces both ends of Wireline's own MCP server share: the app listens on
/// a Unix socket, and `wireline-mcp` (what Claude Code / Codex launch over
/// stdio) relays newline-delimited JSON-RPC between the two.
/// See docs/design/mcp-server.md.
public enum MCPBridge {
    /// Part of the socket's file name: a newer app can serve beside an older one.
    public static let version = 1

    /// `~/Library/Application Support/Wireline/mcp`.
    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wireline/mcp", isDirectory: true)
    }

    public static var socketPath: String { directory.appendingPathComponent("mcp-v\(version).sock").path }

    public static let bundleID = "com.wireline.app"

    /// Newest first. A client asking for one of these gets it; anything else
    /// gets the newest, per the spec.
    public static let protocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    public static func negotiate(_ requested: String?) -> String {
        requested.flatMap { protocolVersions.contains($0) ? $0 : nil } ?? protocolVersions[0]
    }

    // MARK: JSON-RPC

    /// One message as a line (no trailing newline).
    public static func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]),
              let s = String(data: data, encoding: .utf8) else {
            return #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"encoding failed"}}"#
        }
        return s
    }

    public static func decode(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    public static func result(id: Any, _ result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    public static func error(id: Any?, code: Int, _ message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
    }

    public static func notification(_ method: String) -> [String: Any] {
        ["jsonrpc": "2.0", "method": method]
    }

    /// A `tools/call` result: one text block.
    public static func toolText(_ text: String, isError: Bool = false) -> [String: Any] {
        ["content": [["type": "text", "text": text]], "isError": isError]
    }

    public static let methodNotFound = -32601
    public static let invalidParams = -32602
    public static let parseError = -32700

    // MARK: Framing

    /// Splits a byte stream into lines. A line longer than `maxLine` is a
    /// broken peer, not a message.
    public struct LineSplitter {
        public static let maxLine = 32 << 20
        private var buffer: [UInt8] = []
        public struct Overflow: Error {}

        public init() {}

        public mutating func feed<C: Collection>(_ bytes: C) throws -> [String] where C.Element == UInt8 {
            buffer.append(contentsOf: bytes)
            var lines: [String] = []
            var start = 0
            while let nl = buffer[start...].firstIndex(of: 0x0A) {
                var line = buffer[start..<nl]
                if line.last == 0x0D { line = line.dropLast() }
                if !line.isEmpty { lines.append(String(decoding: line, as: UTF8.self)) }
                start = nl + 1
            }
            buffer.removeFirst(start)
            if buffer.count > Self.maxLine { throw Overflow() }
            return lines
        }
    }

    // MARK: When the app can't be reached

    public static var statusTool: [String: Any] { [
        "name": "wireline_status",
        "description": "Explains why Wireline's tools are unavailable right now and what the user should do.",
        "inputSchema": ["type": "object", "properties": [String: Any]()],
        "annotations": ["readOnlyHint": true]
    ] }

    /// What `wireline-mcp` answers by itself when it can't reach the app:
    /// a valid server whose only tool explains `reason`, so the client can tell
    /// the user instead of reporting a dead server. Nil for notifications.
    public static func offlineReply(to line: String, reason: String) -> String? {
        guard let msg = decode(line) else {
            return encode(error(id: nil, code: parseError, "invalid JSON"))
        }
        guard let id = msg["id"], let method = msg["method"] as? String else { return nil }
        let params = msg["params"] as? [String: Any]
        switch method {
        case "initialize":
            return encode(result(id: id, [
                "protocolVersion": negotiate(params?["protocolVersion"] as? String),
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "wireline", "version": "offline"],
                "instructions": reason
            ]))
        case "ping":
            return encode(result(id: id, [:]))
        case "tools/list":
            return encode(result(id: id, ["tools": [statusTool]]))
        case "tools/call":
            return encode(result(id: id, toolText(reason, isError: true)))
        default:
            return encode(error(id: id, code: methodNotFound, "method not found: \(method)"))
        }
    }
}
