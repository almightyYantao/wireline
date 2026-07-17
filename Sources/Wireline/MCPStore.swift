import Foundation
import Observation
import WirelineCore

/// A user-configured MCP server. Secrets (env var values) live in the Keychain,
/// referenced here only by name — nothing sensitive is written to disk.
struct MCPServerConfig: Identifiable, Codable, Sendable, Equatable {
    var id = UUID()
    var name: String
    var command: String
    var args: [String] = []
    /// Names of environment variables whose values are stored in the Keychain
    /// under account `"<id>:<key>"`.
    var envKeys: [String] = []
    var enabled: Bool = true
}

/// A tool bound to the server that advertises it.
struct MCPToolRef: Identifiable, Sendable, Equatable {
    let serverID: UUID
    let serverName: String
    let tool: MCPToolInfo
    var id: String { "\(serverName).\(tool.name)" }

    /// Conservative read-only judgement: trust an explicit hint, otherwise assume
    /// the tool may mutate state (so it needs confirmation / is blocked in sandbox).
    var isReadOnly: Bool { tool.readOnlyHint == true }
}

/// A pending MCP tool call awaiting user confirmation (mutating tools).
struct PendingMCPCall: Identifiable, Equatable {
    var id = UUID()
    var server: String
    var tool: String
    var argsJSON: String
}

enum MCPConnState: Equatable {
    case stopped
    case connecting
    case connected(tools: Int)
    case failed(String)
}

/// Registry of MCP servers: persists configs, owns the live `MCPClient`
/// connections, and exposes the aggregated tool catalog to the AI layer.
@Observable
@MainActor
final class MCPStore {
    static let shared = MCPStore()

    private(set) var servers: [MCPServerConfig]
    /// Connection state per server id (observable, drives the settings UI).
    private(set) var state: [UUID: MCPConnState] = [:]
    /// Flattened catalog of tools across all connected servers.
    private(set) var catalog: [MCPToolRef] = []

    private var clients: [UUID: MCPClient] = [:]
    private let fileURL: URL
    private let keychain = KeychainService(service: "com.wireline.mcp")

    /// Master switch mirrored in AIConfig-style UserDefaults.
    var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "mcp.enabled") }
    }

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wireline", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("mcp_servers.json")
        enabled = UserDefaults.standard.bool(forKey: "mcp.enabled")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([MCPServerConfig].self, from: data) {
            servers = decoded
        } else {
            servers = []
        }
    }

    // MARK: config CRUD

    func add(_ s: MCPServerConfig) { servers.append(s); persist() }

    func update(_ s: MCPServerConfig) {
        if let i = servers.firstIndex(where: { $0.id == s.id }) { servers[i] = s; persist() }
    }

    func remove(_ s: MCPServerConfig) {
        for key in s.envKeys { try? keychain.deletePassword(for: "\(s.id):\(key)") }
        servers.removeAll { $0.id == s.id }
        state[s.id] = nil
        persist()
        Task { await disconnect(s.id) }   // stops the client and rebuilds the catalog
    }

    private func persist() {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted]
        if let data = try? enc.encode(servers) { try? data.write(to: fileURL, options: .atomic) }
    }

    // MARK: env secrets (Keychain)

    func setEnvValue(_ value: String, key: String, server: UUID) {
        try? keychain.setPassword(value, for: "\(server):\(key)")
    }
    func envValue(key: String, server: UUID) -> String {
        (try? keychain.password(for: "\(server):\(key)")) ?? nil ?? ""
    }
    func hasEnvValue(key: String, server: UUID) -> Bool {
        keychain.hasPassword(for: "\(server):\(key)")
    }

    // MARK: connections

    /// Connect every enabled server (call at launch / when master switch flips on).
    func connectEnabled() async {
        guard enabled else { return }
        for s in servers where s.enabled { await connect(s.id) }
    }

    func connect(_ id: UUID) async {
        guard let s = servers.first(where: { $0.id == id }) else { return }
        await disconnect(id)
        state[id] = .connecting
        let client = MCPClient()
        clients[id] = client
        var env: [String: String] = [:]
        for key in s.envKeys { env[key] = envValue(key: key, server: id) }
        do {
            try await client.start(command: s.command, args: s.args, env: env)
            let count = await client.tools.count
            state[id] = .connected(tools: count)
        } catch {
            clients[id] = nil
            state[id] = .failed((error as? MCPError)?.description ?? error.localizedDescription)
        }
        await rebuildCatalog()
    }

    func disconnect(_ id: UUID) async {
        if let c = clients[id] { await c.stop() }
        clients[id] = nil
        if state[id] != nil { state[id] = .stopped }
        await rebuildCatalog()
    }

    func disconnectAll() async {
        for id in clients.keys { await disconnect(id) }
    }

    private func rebuildCatalog() async {
        var out: [MCPToolRef] = []
        for s in servers {
            guard let c = clients[s.id] else { continue }
            let tools = await c.tools
            out += tools.map { MCPToolRef(serverID: s.id, serverName: s.name, tool: $0) }
        }
        catalog = out
    }

    // MARK: AI-facing

    /// Look up a tool by the server name + tool name the model produced.
    func find(server: String, tool: String) -> MCPToolRef? {
        catalog.first {
            $0.serverName.caseInsensitiveCompare(server) == .orderedSame &&
            $0.tool.name.caseInsensitiveCompare(tool) == .orderedSame
        }
    }

    /// Run a tool call, returning its textual result.
    func callTool(server: String, tool: String, argsJSON: String) async throws -> String {
        guard let ref = find(server: server, tool: tool),
              let client = clients[ref.serverID] else {
            throw MCPError.notRunning
        }
        return try await client.callTool(name: ref.tool.name, argumentsJSON: argsJSON)
    }

    /// Whether any tools are currently available to offer the model.
    var hasTools: Bool { enabled && !catalog.isEmpty }
}
