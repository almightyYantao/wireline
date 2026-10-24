import Foundation
import Observation
import WirelineCore

/// Settings for Wireline's own MCP server (what Claude Code / Codex reach
/// through `wireline-mcp`). Off by default.
@Observable
@MainActor
final class MCPServerSettings {
    static let shared = MCPServerSettings()

    var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "mcp.server.enabled")
            if enabled != oldValue { MCPServerHost.shared.toolsChanged() }
        }
    }

    /// What runs without asking (`MCPPolicy`). Default: confirm.
    var mode: MCPAccessMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "mcp.server.mode") }
    }

    private init() {
        enabled = UserDefaults.standard.bool(forKey: "mcp.server.enabled")
        mode = MCPAccessMode(rawValue: UserDefaults.standard.string(forKey: "mcp.server.mode") ?? "") ?? .confirm
    }
}

/// Listens on `MCPBridge.socketPath` for as long as the app runs, enabled or
/// not: while off, a client sees only `wireline_status`, which tells the user
/// where to switch it on (and switching on refreshes the client's tool list).
@Observable
@MainActor
final class MCPServerHost {
    static let shared = MCPServerHost()

    @ObservationIgnored weak var hosts: HostStore?
    @ObservationIgnored weak var sessions: SessionStore?
    @ObservationIgnored weak var snippets: SnippetStore?
    @ObservationIgnored weak var forwards: ForwardStore?
    @ObservationIgnored private var listenFD: Int32 = -1
    @ObservationIgnored private var acceptSource: DispatchSourceRead?
    @ObservationIgnored private var clients: [ObjectIdentifier: (AgentConnection, MCPServerConnection)] = [:]
    /// Why the socket couldn't be opened, if it couldn't.
    private(set) var lastError: String?

    /// How many MCP clients are connected right now (Settings shows it).
    private(set) var clientCount = 0

    func start(path: String = MCPBridge.socketPath) {
        guard listenFD < 0 else { return }
        // Another Wireline (a dev build beside the installed one) already
        // serves: listening would unlink its socket out from under its clients.
        if let fd = try? AgentConnection.connect(path: path) {
            close(fd)
            lastError = "another Wireline is already serving \(path)"
            return
        }
        do {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            listenFD = try AgentConnection.listen(path: path)
        } catch {
            lastError = "\(error)"
            return
        }
        let src = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: .main)
        src.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.acceptAll() } }
        acceptSource = src
        src.resume()
    }

    func attach(hosts: HostStore, sessions: SessionStore, snippets: SnippetStore, forwards: ForwardStore) {
        self.hosts = hosts
        self.sessions = sessions
        self.snippets = snippets
        self.forwards = forwards
    }

    private func acceptAll() {
        while true {
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else { return }
            let conn = AgentConnection(fd: fd, queue: .main)
            // Same user, and `wireline-mcp` signed like us.
            guard conn.peerUID == getuid(), PeerIdentity.check(fd: fd) == .trusted else {
                conn.close()
                continue
            }
            let server = MCPServerConnection { [weak conn] line in
                conn?.send(bytes: Array(line.utf8) + [0x0A])
            }
            var splitter = MCPBridge.LineSplitter()
            let key = ObjectIdentifier(conn)
            conn.onBytes = { [weak conn] bytes in
                MainActor.assumeIsolated {
                    do {
                        for line in try splitter.feed(bytes) { server.receive(line) }
                    } catch {
                        conn?.close()
                    }
                }
            }
            conn.onClose = { [weak self] in
                MainActor.assumeIsolated {
                    server.closed()
                    self?.clients[key] = nil
                    self?.clientCount = self?.clients.count ?? 0
                }
            }
            clients[key] = (conn, server)
            clientCount = clients.count
            conn.start()
        }
    }

    /// The tool list depends on the switch: tell every client to re-read it.
    func toolsChanged() {
        for (_, server) in clients.values { server.notify("notifications/tools/list_changed") }
    }
}

/// One MCP client: the JSON-RPC session over one socket connection. Its
/// privacy scope is the connection: placeholders it hands out resolve only for
/// it, and only until it disconnects.
@MainActor
final class MCPServerConnection {
    private let send: (String) -> Void
    private(set) var clientName = "unknown"
    /// Fixed at `initialize`; a change in Settings makes calls fail until the
    /// client reconnects, rather than silently switching protection.
    private var level: PrivacyPolicy.Level?
    private var masker: PrivacyMasker?
    /// "Don't ask again" answers, by request key; this connection only.
    var alwaysAllowed: Set<String> = []
    /// Sessions this client opened: the only ones it may close.
    var opened: Set<UUID> = []
    /// Toolsets `load_tools` added to this connection's list.
    var loadedToolsets: Set<String> = []
    /// Background commands (`exec_start`), by id.
    var jobs: [String: MCPJob] = [:]

    init(send: @escaping (String) -> Void) {
        self.send = send
    }

    func receive(_ line: String) {
        guard let msg = MCPBridge.decode(line) else {
            send(MCPBridge.encode(MCPBridge.error(id: nil, code: MCPBridge.parseError, "invalid JSON")))
            return
        }
        Task {
            if let reply = await respond(to: msg) { send(MCPBridge.encode(reply)) }
        }
    }

    private(set) var isClosed = false

    /// The client went away: its background commands and unanswered
    /// approvals go with it.
    func closed() {
        isClosed = true
        for job in jobs.values { job.stop() }
        jobs = [:]
        MCPApprovalCenter.shared.withdraw(owner: ObjectIdentifier(self))
    }

    func notify(_ method: String) {
        send(MCPBridge.encode(MCPBridge.notification(method)))
    }

    /// The reply to one message; nil for notifications and responses.
    func respond(to msg: [String: Any]) async -> [String: Any]? {
        guard let method = msg["method"] as? String, let id = msg["id"] else { return nil }
        let params = msg["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            if let info = params["clientInfo"] as? [String: Any], let name = info["name"] as? String { clientName = name }
            let level = AIConfig.shared.privacyLevel
            self.level = level
            masker = PrivacyContext.masker(level)
            return MCPBridge.result(id: id, [
                "protocolVersion": MCPBridge.negotiate(params["protocolVersion"] as? String),
                "capabilities": ["tools": ["listChanged": true]],
                "serverInfo": ["name": "wireline",
                               "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"],
                "instructions": MCPServerTools.instructions(masking: masker != nil)
            ])
        case "ping":
            return MCPBridge.result(id: id, [:])
        case "tools/list":
            return MCPBridge.result(id: id, ["tools": MCPServerSettings.shared.enabled
                                             ? MCPServerTools.tools(for: self) : [MCPBridge.statusTool]])
        case "tools/call":
            guard let name = params["name"] as? String else {
                return MCPBridge.error(id: id, code: MCPBridge.invalidParams, "missing tool name")
            }
            return MCPBridge.result(id: id, await call(name, params["arguments"] as? [String: Any] ?? [:]))
        default:
            return MCPBridge.error(id: id, code: MCPBridge.methodNotFound, "method not found: \(method)")
        }
    }

    /// Restore → run → mask. Restoring comes first so every check sees (and the
    /// user is shown) the real values.
    private func call(_ name: String, _ arguments: [String: Any]) async -> [String: Any] {
        guard MCPServerSettings.shared.enabled else {
            return MCPBridge.toolText(MCPServerTools.disabledText, isError: true)
        }
        guard level == AIConfig.shared.privacyLevel else {
            return MCPBridge.toolText("Wireline 的 AI 脱敏设置已变更，请重新连接这个 MCP server 后再试。"
                                      + " / Wireline's AI privacy setting changed; reconnect this MCP server.", isError: true)
        }
        if let masker { PrivacyContext.refresh(masker) }
        let args = restore(arguments)
        if let stale = staleText(args) {
            return MCPBridge.toolText("参数里的占位符 \(stale) 无法还原（不属于本次连接），未执行。请重新读取需要的值。"
                                      + " / Placeholder \(stale) doesn't belong to this connection; not run.", isError: true)
        }
        let outcome = await MCPServerTools.run(name, args, conn: self)
        MCPAudit.record(.init(time: Date(), client: clientName, tool: name, arguments: MCPAudit.summarize(args),
                              outcome: outcome.isError && outcome.audit == "ok" ? "error" : outcome.audit))
        let text = masker?.mask(outcome.text) ?? outcome.text
        return MCPBridge.toolText(text, isError: outcome.isError)
    }

    private func restore(_ value: [String: Any]) -> [String: Any] {
        guard let masker else { return value }
        func walk(_ v: Any) -> Any {
            switch v {
            case let s as String: return masker.restore(s)
            case let a as [Any]: return a.map(walk)
            case let d as [String: Any]: return d.mapValues(walk)
            default: return v
            }
        }
        return value.mapValues(walk)
    }

    private func staleText(_ value: [String: Any]) -> String? {
        var found: [String] = []
        func walk(_ v: Any) {
            switch v {
            case let s as String: found += PrivacyMasker.placeholders(in: s)
            case let a as [Any]: a.forEach(walk)
            case let d as [String: Any]: d.values.forEach(walk)
            default: break
            }
        }
        value.values.forEach(walk)
        return found.isEmpty ? nil : Array(Set(found)).sorted().joined(separator: ", ")
    }
}
