import Foundation

/// A tool advertised by an MCP server, flattened from `tools/list`.
public struct MCPToolInfo: Codable, Sendable, Identifiable, Equatable {
    public var name: String
    public var description: String
    /// Raw JSON of the tool's `inputSchema` (kept as a string so it stays Sendable
    /// and can be injected verbatim into the model prompt).
    public var inputSchemaJSON: String
    /// From `annotations.readOnlyHint`; nil when the server doesn't declare it.
    public var readOnlyHint: Bool?
    /// From `annotations.destructiveHint`.
    public var destructiveHint: Bool?

    public var id: String { name }

    public init(name: String, description: String, inputSchemaJSON: String,
                readOnlyHint: Bool?, destructiveHint: Bool?) {
        self.name = name
        self.description = description
        self.inputSchemaJSON = inputSchemaJSON
        self.readOnlyHint = readOnlyHint
        self.destructiveHint = destructiveHint
    }
}

public enum MCPError: Error, CustomStringConvertible, Sendable {
    case launch(String)
    case notRunning
    case transport(String)
    case rpc(code: Int, message: String)
    case timeout
    case decode(String)

    public var description: String {
        switch self {
        case .launch(let m):        return "启动 MCP server 失败：\(m)"
        case .notRunning:           return "MCP server 未运行。"
        case .transport(let m):     return "MCP 传输错误：\(m)"
        case .rpc(let c, let m):    return "MCP 调用出错 (\(c))：\(m)"
        case .timeout:              return "MCP 调用超时。"
        case .decode(let m):        return "MCP 响应解析失败：\(m)"
        }
    }
}

/// One MCP server connection over stdio, speaking JSON-RPC 2.0 (newline-delimited).
/// Model-agnostic: the app translates tool calls to/from the AI's text protocol,
/// so nothing here depends on the LLM endpoint.
///
/// Target protocol version: 2025-06-18.
public actor MCPClient {
    public let protocolVersion = "2025-06-18"

    private var process: Process?
    private var stdin: FileHandle?
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var readTask: Task<Void, Never>?

    public private(set) var tools: [MCPToolInfo] = []
    public private(set) var isRunning = false

    public init() {}

    // MARK: lifecycle

    /// Spawn the server, perform the `initialize` handshake, and load its tools.
    /// `env` is merged onto the current environment (used to inject secrets).
    public func start(command: String, args: [String], env: [String: String]) async throws {
        guard !isRunning else { return }

        let proc = Process()
        // Resolve bare command names via /usr/bin/env so `npx`, `uvx`, etc. work.
        if command.hasPrefix("/") {
            proc.executableURL = URL(fileURLWithPath: command)
            proc.arguments = args
        } else {
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc.arguments = [command] + args
        }
        var merged = ProcessInfo.processInfo.environment
        for (k, v) in env { merged[k] = v }
        proc.environment = merged

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do {
            try proc.run()
        } catch {
            throw MCPError.launch(error.localizedDescription)
        }

        process = proc
        stdin = inPipe.fileHandleForWriting
        isRunning = true
        startReadLoop(outPipe.fileHandleForReading)

        // Drain stderr in the background so the pipe never fills and blocks the child.
        let errHandle = errPipe.fileHandleForReading
        Task.detached { for try await _ in errHandle.bytes.lines {} }

        try await handshake()
        try await refreshTools()
    }

    public func stop() {
        readTask?.cancel()
        readTask = nil
        try? stdin?.close()
        process?.terminate()
        process = nil
        stdin = nil
        isRunning = false
        failAll(MCPError.notRunning)
    }

    // MARK: JSON-RPC

    private func handshake() async throws {
        let params: [String: Any] = [
            "protocolVersion": protocolVersion,
            "capabilities": [:],
            "clientInfo": ["name": "Wireline", "version": "1.0"]
        ]
        _ = try await request(method: "initialize", params: params)
        // Fire-and-forget notification that we're ready.
        try notify(method: "notifications/initialized", params: [:])
    }

    /// Reload the tool catalog from the server.
    public func refreshTools() async throws {
        let data = try await request(method: "tools/list", params: [:])
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["tools"] as? [[String: Any]] else {
            throw MCPError.decode("tools/list 结果缺少 tools 数组")
        }
        tools = list.map { t in
            let schema = t["inputSchema"] as? [String: Any] ?? [:]
            let schemaJSON = (try? JSONSerialization.data(withJSONObject: schema))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            let ann = t["annotations"] as? [String: Any]
            return MCPToolInfo(
                name: (t["name"] as? String) ?? "?",
                description: (t["description"] as? String) ?? "",
                inputSchemaJSON: schemaJSON,
                readOnlyHint: ann?["readOnlyHint"] as? Bool,
                destructiveHint: ann?["destructiveHint"] as? Bool
            )
        }
    }

    /// Call a tool and return its textual result (concatenated text content).
    public func callTool(name: String, argumentsJSON: String, timeout: TimeInterval = 60) async throws -> String {
        let arguments = (try? JSONSerialization.jsonObject(
            with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        let data = try await request(method: "tools/call",
                                     params: ["name": name, "arguments": arguments],
                                     timeout: timeout)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPError.decode("tools/call 结果不是对象")
        }
        let isError = (obj["isError"] as? Bool) ?? false
        let parts = (obj["content"] as? [[String: Any]]) ?? []
        let text = parts.compactMap { part -> String? in
            if let t = part["text"] as? String { return t }
            if let type = part["type"] as? String { return "[\(type) content]" }
            return nil
        }.joined(separator: "\n")
        let body = text.isEmpty ? "(工具无文本输出)" : text
        return isError ? "⚠️ 工具报告错误：\n\(body)" : body
    }

    // MARK: transport internals

    private func request(method: String, params: [String: Any],
                         timeout: TimeInterval = 30) async throws -> Data {
        guard isRunning, let stdin else { throw MCPError.notRunning }
        let id = nextID; nextID += 1
        let message: [String: Any] = [
            "jsonrpc": "2.0", "id": id, "method": method, "params": params
        ]
        let line = try JSONSerialization.data(withJSONObject: message) + Data("\n".utf8)

        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { [weak self] in
                guard let self else { throw MCPError.notRunning }
                return try await withCheckedThrowingContinuation { cont in
                    Task { await self.enqueue(id: id, cont: cont, line: line, handle: stdin) }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw MCPError.timeout
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw MCPError.timeout }
            return result
        }
    }

    private func enqueue(id: Int, cont: CheckedContinuation<Data, Error>,
                         line: Data, handle: FileHandle) {
        pending[id] = cont
        do { try handle.write(contentsOf: line) }
        catch {
            pending[id] = nil
            cont.resume(throwing: MCPError.transport(error.localizedDescription))
        }
    }

    private func notify(method: String, params: [String: Any]) throws {
        guard let stdin else { throw MCPError.notRunning }
        let message: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        let line = try JSONSerialization.data(withJSONObject: message) + Data("\n".utf8)
        try stdin.write(contentsOf: line)
    }

    private func startReadLoop(_ handle: FileHandle) {
        readTask = Task { [weak self] in
            do {
                for try await line in handle.bytes.lines {
                    await self?.receive(line: line)
                    if Task.isCancelled { break }
                }
            } catch { /* pipe closed / cancelled */ }
            await self?.handleEOF()
        }
    }

    private func receive(line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any]
        else { return }
        // Responses carry an id; notifications from the server don't — ignore those.
        guard let id = obj["id"] as? Int, let cont = pending[id] else { return }
        pending[id] = nil
        if let err = obj["error"] as? [String: Any] {
            let code = (err["code"] as? Int) ?? -1
            let msg = (err["message"] as? String) ?? "unknown"
            cont.resume(throwing: MCPError.rpc(code: code, message: msg))
            return
        }
        let result = obj["result"] ?? [:]
        if let data = try? JSONSerialization.data(withJSONObject: result) {
            cont.resume(returning: data)
        } else {
            cont.resume(throwing: MCPError.decode("无法序列化 result"))
        }
    }

    private func handleEOF() {
        isRunning = false
        failAll(MCPError.transport("MCP server 连接已断开"))
    }

    private func failAll(_ error: Error) {
        for (_, cont) in pending { cont.resume(throwing: error) }
        pending.removeAll()
    }
}
