import Foundation
import WirelineCore

/// The tools that start hidden (docs/design/mcp-server.md §2.2): a client
/// calls `load_tools` for a set, which joins its list (and a
/// `tools/list_changed` goes out). Clients that don't refresh can reach them
/// through `call_loaded_tool`.
extension MCPServerTools {
    static let toolsets: [(name: String, summary: String)] = [
        ("files", "list / stat / mkdir / rename / delete remote files; upload and download between this Mac and a host"),
        ("jobs", "long-running or streaming commands on a host: exec_start, exec_poll, exec_stop"),
        ("forwards", "SSH port forwards (tunnels): list, create, start, stop"),
        ("snippets", "the user's saved command snippets: list, run one in a session"),
        ("hosts_admin", "add or edit hosts in ~/.ssh/config, and Wireline's notes about a host")
    ]

    static var loaderDefinition: [String: Any] {
        ["name": "load_tools",
         "description": "Add more Wireline tools to this conversation. Sets: "
            + toolsets.map { "\($0.name) (\($0.summary))" }.joined(separator: "; ") + "; all.",
         "inputSchema": ["type": "object",
                         "properties": ["toolset": ["type": "string", "enum": toolsets.map(\.name) + ["all"]]],
                         "required": ["toolset"]],
         "annotations": ["readOnlyHint": true, "openWorldHint": false]]
    }

    static var callLoadedDefinition: [String: Any] {
        ["name": "call_loaded_tool",
         "description": "Call a tool added by load_tools, for clients whose tool list didn't refresh. Pass its name and arguments.",
         "inputSchema": ["type": "object",
                         "properties": ["name": ["type": "string"], "arguments": ["type": "object"]],
                         "required": ["name"]],
         "annotations": ["readOnlyHint": false, "openWorldHint": false]]
    }

    /// What `tools/list` shows this connection.
    static func tools(for conn: MCPServerConnection) -> [[String: Any]] {
        let loaded = toolsets.map(\.name).filter { conn.loadedToolsets.contains($0) }
        guard !loaded.isEmpty else { return definitions }
        return definitions + loaded.flatMap(toolsetDefinitions) + [callLoadedDefinition]
    }

    static func toolsetDefinitions(_ set: String) -> [[String: Any]] {
        func obj(_ p: [String: Any], _ r: [String]) -> [String: Any] { ["type": "object", "properties": p, "required": r] }
        func t(_ name: String, _ d: String, _ schema: [String: Any], readOnly: Bool, destructive: Bool = false) -> [String: Any] {
            ["name": name, "description": d, "inputSchema": schema,
             "annotations": ["readOnlyHint": readOnly, "destructiveHint": destructive, "openWorldHint": false]]
        }
        let str: [String: Any] = ["type": "string"], int: [String: Any] = ["type": "integer"]
        switch set {
        case "files":
            return [
                t("file_list", "List a directory on a host (ls -la).", obj(["alias": str, "path": str], ["alias", "path"]), readOnly: true),
                t("file_stat", "Details of one path on a host.", obj(["alias": str, "path": str], ["alias", "path"]), readOnly: true),
                t("file_mkdir", "Create a directory (and its parents) on a host.", obj(["alias": str, "path": str], ["alias", "path"]), readOnly: false),
                t("file_rename", "Rename or move a path on a host; refuses to overwrite.", obj(["alias": str, "from": str, "to": str], ["alias", "from", "to"]), readOnly: false),
                t("file_delete", "Delete a file, or a directory with recursive=true. Always asks the user.",
                  obj(["alias": str, "path": str, "recursive": ["type": "boolean"]], ["alias", "path"]), readOnly: false, destructive: true),
                t("file_upload", "Copy a file or directory from this Mac to a host (scp). Always asks the user.",
                  obj(["local_path": str, "alias": str, "remote_path": str], ["local_path", "alias", "remote_path"]), readOnly: false),
                t("file_download", "Copy a file or directory from a host to this Mac (scp). Always asks the user.",
                  obj(["alias": str, "remote_path": str, "local_path": str], ["alias", "remote_path", "local_path"]), readOnly: false)
            ]
        case "jobs":
            return [
                t("exec_start", "Start a command on a host in the background (tail -f, a build, a long script). Returns a job id; read it with exec_poll.",
                  obj(["alias": str, "command": str], ["alias", "command"]), readOnly: false, destructive: true),
                t("exec_poll", "New output of a job since `since` (the `next` of the last poll; default: where the last poll stopped), and whether it is still running.",
                  obj(["job_id": str, "since": int], ["job_id"]), readOnly: true),
                t("exec_stop", "Stop a job.", obj(["job_id": str], ["job_id"]), readOnly: false)
            ]
        case "forwards":
            return [
                t("forward_list", "Port forwards Wireline knows, and whether each is running.", obj([:], []), readOnly: true),
                t("forward_create", "Create a port forward on this Mac's loopback: kind local (ssh -L, default) reaches remote_host:remote_port from the host; kind dynamic (ssh -D) is a SOCKS proxy. Starts it unless start=false.",
                  obj(["alias": str, "local_port": int, "remote_host": str, "remote_port": int,
                       "kind": ["type": "string", "enum": ["local", "dynamic"]], "start": ["type": "boolean"]],
                      ["alias", "local_port"]), readOnly: false),
                t("forward_start", "Start a port forward by id.", obj(["id": str], ["id"]), readOnly: false),
                t("forward_stop", "Stop a port forward by id.", obj(["id": str], ["id"]), readOnly: false)
            ]
        case "snippets":
            return [
                t("snippet_list", "The user's saved snippets: id, title, command, parameters.", obj(["query": str], []), readOnly: true),
                t("snippet_run", "Run a snippet in a session like session_exec, filling its {{parameters}} from `values` (or their saved / default values).",
                  obj(["snippet": ["type": "string", "description": "id or title"], "session_id": str,
                       "values": ["type": "object", "additionalProperties": ["type": "string"]]], ["snippet", "session_id"]),
                  readOnly: false, destructive: true)
            ]
        case "hosts_admin":
            let fields: [String: Any] = ["alias": str, "hostname": str, "user": str, "port": int, "group": str,
                                         "description": str, "jump": ["type": "string", "description": "ProxyJump alias"]]
            return [
                t("host_add", "Add an SSH host to ~/.ssh/config. Always asks the user.", obj(fields, ["alias", "hostname"]), readOnly: false),
                t("host_update", "Change an SSH host's fields in ~/.ssh/config (only those given; \"\" clears). Always asks the user.",
                  obj(fields, ["alias"]), readOnly: false),
                t("host_note_add", "Remember a stable fact about a host (Wireline's own AI uses these too).",
                  obj(["alias": str, "note": str], ["alias", "note"]), readOnly: false),
                t("host_note_remove", "Forget one of a host's notes (exact text).", obj(["alias": str, "note": str], ["alias", "note"]), readOnly: false)
            ]
        default:
            return []
        }
    }

    static func isToolsetTool(_ name: String) -> Bool {
        toolsets.contains { toolsetDefinitions($0.name).contains { $0["name"] as? String == name } }
    }

    // MARK: load_tools / call_loaded_tool

    static func loadTools(_ set: String?, conn: MCPServerConnection) -> Outcome {
        let names = toolsets.map(\.name)
        guard let set, set == "all" || names.contains(set) else {
            return .error("Unknown toolset \(set ?? "(missing)"). One of: \((names + ["all"]).joined(separator: ", ")).")
        }
        let adding = set == "all" ? names : [set]
        conn.loadedToolsets.formUnion(adding)
        conn.notify("notifications/tools/list_changed")
        let defs = adding.flatMap(toolsetDefinitions).map { d -> [String: Any] in
            ["name": d["name"] ?? "", "description": d["description"] ?? "", "inputSchema": d["inputSchema"] ?? [:]]
        }
        return Outcome(text: "Loaded \(adding.joined(separator: ", ")). Call these directly once your tool list refreshes, "
                       + "or through call_loaded_tool(name, arguments):\n" + json(defs))
    }

    // MARK: Dispatch

    static func runToolset(_ name: String, _ args: [String: Any], conn: MCPServerConnection,
                           hosts: HostStore, sessions: SessionStore) async -> Outcome? {
        let host = MCPServerHost.shared
        switch name {
        case "file_list":      return await remoteRead(hosts, args, script: { "ls -la -- \(shellQuote($0))" })
        case "file_stat":      return await remoteRead(hosts, args, script: { "stat -- \(shellQuote($0)) 2>/dev/null || ls -ld -- \(shellQuote($0))" })
        case "file_mkdir":     return await fileMkdir(hosts, args, conn: conn)
        case "file_rename":    return await fileRename(hosts, args, conn: conn)
        case "file_delete":    return await fileDelete(hosts, args, conn: conn)
        case "file_upload":    return await transfer(hosts, args, upload: true, conn: conn)
        case "file_download":  return await transfer(hosts, args, upload: false, conn: conn)
        case "exec_start":     return await execStart(hosts, args, conn: conn)
        case "exec_poll":      return execPoll(args, conn: conn)
        case "exec_stop":      return execStop(args, conn: conn)
        case "forward_list":   return forwardList(host.forwards)
        case "forward_create": return await forwardCreate(hosts, host.forwards, args, conn: conn)
        case "forward_start":  return await forwardStart(hosts, host.forwards, args, conn: conn)
        case "forward_stop":   return forwardStop(host.forwards, args)
        case "snippet_list":   return snippetList(host.snippets, query: args["query"] as? String)
        case "snippet_run":    return await snippetRun(host.snippets, sessions, args, conn: conn)
        case "host_add":       return await hostAdd(hosts, args, conn: conn)
        case "host_update":    return await hostUpdate(hosts, args, conn: conn)
        case "host_note_add", "host_note_remove": return hostNote(hosts, args, add: name == "host_note_add")
        default:               return nil
        }
    }

    private static var mode: MCPAccessMode { MCPServerSettings.shared.mode }
    private static var loc: Localizer { Localizer.shared }

    /// `go` from the gate, or the outcome that stops the call.
    private static func pass(_ g: Gate) -> (audit: String?, stop: Outcome?) {
        switch g {
        case .go(let a): return (a, nil)
        case .stop(let o): return (nil, o)
        }
    }

    // MARK: files

    private static func sshHost(_ hosts: HostStore, _ alias: Any?) -> Result<Host, Outcome> {
        guard let alias = alias as? String, let h = hosts.hosts.first(where: { $0.alias == alias }) else {
            return .failure(.error("Unknown host alias \(alias as? String ?? "(missing)"). Use hosts_list for the aliases."))
        }
        return h.isRDP ? .failure(.error("\(alias) is a remote desktop; this needs an SSH host.")) : .success(h)
    }

    private static func remote(_ alias: String, _ script: String, timeout: Int = 30) async -> FleetResult {
        await FleetRunner.run(command: "sh -c " + shellQuote(script), on: [alias], timeout: timeout).first
            ?? FleetResult(alias: alias, output: "(no result)", exitCode: -1)
    }

    private static func done(_ r: FleetResult, _ ok: String, audit: String) -> Outcome {
        withAudit(r.ok ? Outcome(text: ok + (r.output.isEmpty ? "" : "\n" + r.output))
                       : .error("Failed (exit \(r.exitCode)): " + String(r.output.suffix(2000))), audit)
    }

    private static func remoteRead(_ hosts: HostStore, _ args: [String: Any], script: (String) -> String) async -> Outcome {
        let h: Host
        switch sshHost(hosts, args["alias"]) { case .success(let x): h = x; case .failure(let o): return o }
        guard let path = args["path"] as? String, !path.isEmpty else { return .error("path is required") }
        let r = await remote(h.alias, script(path))
        return r.ok ? Outcome(text: String(r.output.suffix(40000))) : .error("Failed (exit \(r.exitCode)): " + String(r.output.suffix(2000)))
    }

    private static func fileMkdir(_ hosts: HostStore, _ args: [String: Any], conn: MCPServerConnection) async -> Outcome {
        let h: Host
        switch sshHost(hosts, args["alias"]) { case .success(let x): h = x; case .failure(let o): return o }
        guard let path = args["path"] as? String, !path.isEmpty else { return .error("path is required") }
        let (audit, stop) = pass(await gate(MCPPolicy.change(mode: mode), key: "mkdir|\(h.alias)|\(path)", conn: conn) {
            MCPApproval(client: conn.clientName, title: loc.t("在 \(h.alias) 上新建目录", "Create a directory on \(h.alias)"),
                        subject: path, dangerous: false, canAlwaysAllow: false)
        })
        if let stop { return stop }
        return done(await remote(h.alias, "mkdir -p -- \(shellQuote(path))"), "Created \(h.alias):\(path).", audit: audit!)
    }

    private static func fileRename(_ hosts: HostStore, _ args: [String: Any], conn: MCPServerConnection) async -> Outcome {
        let h: Host
        switch sshHost(hosts, args["alias"]) { case .success(let x): h = x; case .failure(let o): return o }
        guard let from = args["from"] as? String, let to = args["to"] as? String, !from.isEmpty, !to.isEmpty else {
            return .error("from and to are required")
        }
        let (audit, stop) = pass(await gate(MCPPolicy.change(mode: mode), key: "mv|\(h.alias)|\(from)|\(to)", conn: conn) {
            MCPApproval(client: conn.clientName, title: loc.t("在 \(h.alias) 上重命名", "Rename on \(h.alias)"),
                        subject: "\(from)\n→ \(to)", dangerous: false, canAlwaysAllow: false)
        })
        if let stop { return stop }
        let script = "[ -e \(shellQuote(to)) ] && { echo 'target exists'; exit 3; }; mv -- \(shellQuote(from)) \(shellQuote(to))"
        return done(await remote(h.alias, script), "Renamed \(h.alias):\(from) → \(to).", audit: audit!)
    }

    private static func fileDelete(_ hosts: HostStore, _ args: [String: Any], conn: MCPServerConnection) async -> Outcome {
        let h: Host
        switch sshHost(hosts, args["alias"]) { case .success(let x): h = x; case .failure(let o): return o }
        guard let path = args["path"] as? String, !path.isEmpty else { return .error("path is required") }
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: " /"))
        guard !trimmed.isEmpty, !["~", ".", "..", "*"].contains(trimmed) else { return .refused("Refusing to delete \(path).") }
        let recursive = args["recursive"] as? Bool ?? false
        let (audit, stop) = pass(await gate(MCPPolicy.alwaysAsk(mode: mode, dangerous: recursive), key: "rm|\(h.alias)|\(path)", conn: conn) {
            MCPApproval(client: conn.clientName,
                        title: recursive ? loc.t("删除 \(h.alias) 上的目录及其全部内容", "Delete a directory and everything in it on \(h.alias)")
                                         : loc.t("删除 \(h.alias) 上的文件", "Delete a file on \(h.alias)"),
                        subject: path, dangerous: recursive, canAlwaysAllow: false)
        })
        if let stop { return stop }
        let script = recursive ? "rm -rf -- \(shellQuote(path))"
                               : "[ -d \(shellQuote(path)) ] && { echo 'is a directory (pass recursive=true)'; exit 3; }; rm -f -- \(shellQuote(path))"
        return done(await remote(h.alias, script), "Deleted \(h.alias):\(path).", audit: audit!)
    }

    private static func transfer(_ hosts: HostStore, _ args: [String: Any], upload: Bool, conn: MCPServerConnection) async -> Outcome {
        let h: Host
        switch sshHost(hosts, args["alias"]) { case .success(let x): h = x; case .failure(let o): return o }
        guard let local = args["local_path"] as? String, let remotePath = args["remote_path"] as? String,
              !local.isEmpty, !remotePath.isEmpty else { return .error("local_path and remote_path are required") }
        let localPath = (local as NSString).expandingTildeInPath
        if upload, !FileManager.default.fileExists(atPath: localPath) { return .error("\(local) doesn't exist on this Mac.") }
        let (audit, stop) = pass(await gate(MCPPolicy.alwaysAsk(mode: mode), key: "xfer", conn: conn) {
            MCPApproval(client: conn.clientName,
                        title: upload ? loc.t("把本机文件上传到 \(h.alias)", "Upload from this Mac to \(h.alias)")
                                      : loc.t("从 \(h.alias) 下载到本机", "Download from \(h.alias) to this Mac"),
                        subject: upload ? "\(localPath)\n→ \(h.alias):\(remotePath)" : "\(h.alias):\(remotePath)\n→ \(localPath)",
                        dangerous: false, canAlwaysAllow: false)
        })
        if let stop { return stop }
        let r = upload ? await FleetRunner.upload(localPath: localPath, to: h.alias, remotePath: remotePath)
                       : await FleetRunner.download(from: h.alias, remotePath: remotePath, localPath: localPath)
        return withAudit(r.ok ? Outcome(text: r.output) : .error(r.output), audit!)
    }

    // MARK: jobs

    private static func execStart(_ hosts: HostStore, _ args: [String: Any], conn: MCPServerConnection) async -> Outcome {
        let h: Host
        switch sshHost(hosts, args["alias"]) { case .success(let x): h = x; case .failure(let o): return o }
        guard let command = (args["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty else {
            return .error("command is required")
        }
        guard conn.jobs.values.filter(\.isRunning).count < 10 else { return .refused("At most 10 running jobs per client; exec_stop one.") }
        let verdict = MCPPolicy.command(command, mode: mode)
        let (audit, stop) = pass(await gate(verdict, key: "exec|\(h.alias)|\(command)", conn: conn) {
            MCPApproval(client: conn.clientName, title: loc.t("在 \(h.alias) 上后台运行", "Run in the background on \(h.alias)"),
                        subject: command, dangerous: verdict == .ask(dangerous: true),
                        canAlwaysAllow: verdict != .ask(dangerous: true))
        })
        if let stop { return stop }
        let id = "job\(conn.jobs.count + 1)"
        let job = MCPJob(alias: h.alias, command: command)
        guard job.start() else { return .error("Couldn't start ssh for \(h.alias).") }
        conn.jobs[id] = job
        return withAudit(Outcome(text: json(["job_id": id, "host": h.alias, "running": true])), audit!)
    }

    private static func execPoll(_ args: [String: Any], conn: MCPServerConnection) -> Outcome {
        guard let id = args["job_id"] as? String, let job = conn.jobs[id] else {
            return .error("No job \(args["job_id"] as? String ?? "(missing)") on this connection.")
        }
        let r = job.read(since: int(args["since"]))
        var out: [String: Any] = ["job_id": id, "running": r.running, "next": r.next, "output": r.text]
        if let code = r.exitCode { out["exit_code"] = Int(code) }
        if r.skipped > 0 { out["skipped_bytes"] = r.skipped }
        return Outcome(text: json(out))
    }

    private static func execStop(_ args: [String: Any], conn: MCPServerConnection) -> Outcome {
        guard let id = args["job_id"] as? String, let job = conn.jobs[id] else {
            return .error("No job \(args["job_id"] as? String ?? "(missing)") on this connection.")
        }
        job.stop()
        return Outcome(text: "Stopped \(id).")
    }

    // MARK: forwards

    private static func forwardState(_ store: ForwardStore, _ f: PortForward) -> String {
        if store.isRunning(f) { return "running" }
        if case .failed(let why)? = store.states[f.id] { return "failed: " + why }
        return "stopped"
    }

    private static func forwardList(_ store: ForwardStore?) -> Outcome {
        guard let store else { return .error("Wireline is still starting; retry shortly.") }
        let list: [[String: Any]] = store.forwards.map { f in
            var d: [String: Any] = ["id": f.id.uuidString, "kind": f.kind.rawValue, "host": f.hostAlias,
                                    "local_port": f.localPort, "state": forwardState(store, f)]
            if f.kind != .dynamic { d["remote_host"] = f.remoteHost; d["remote_port"] = f.remotePort }
            if let b = f.bindAddress { d["bind"] = b }
            if let l = f.label { d["label"] = l }
            return d
        }
        return Outcome(text: list.isEmpty ? "No port forwards." : json(list))
    }

    private static func forwardCreate(_ hosts: HostStore, _ store: ForwardStore?, _ args: [String: Any],
                                      conn: MCPServerConnection) async -> Outcome {
        guard let store else { return .error("Wireline is still starting; retry shortly.") }
        let h: Host
        switch sshHost(hosts, args["alias"]) { case .success(let x): h = x; case .failure(let o): return o }
        let kind: PortForward.Kind = (args["kind"] as? String) == "dynamic" ? .dynamic : .local
        guard let lp = int(args["local_port"]), (1024...65535).contains(lp) else { return .error("local_port must be 1024–65535.") }
        let rh = (args["remote_host"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "127.0.0.1"
        let rp = int(args["remote_port"]) ?? 0
        guard kind == .dynamic || (1...65535).contains(rp) else { return .error("remote_port is required for a local forward.") }
        if store.forwards.contains(where: { $0.localPort == lp && store.isRunning($0) }) {
            return .error("Local port \(lp) is already used by a running forward.")
        }
        let what = kind == .dynamic ? "SOCKS 127.0.0.1:\(lp) → \(h.alias)" : "127.0.0.1:\(lp) → \(h.alias) → \(rh):\(rp)"
        let (audit, stop) = pass(await gate(MCPPolicy.change(mode: mode), key: "fwd|\(what)", conn: conn) {
            MCPApproval(client: conn.clientName, title: loc.t("新建端口转发", "Create a port forward"),
                        subject: what, dangerous: false, canAlwaysAllow: false)
        })
        if let stop { return stop }
        // Loopback only: a tunnel an AI asked for is never reachable from the LAN.
        let f = PortForward(kind: kind, hostAlias: h.alias, localPort: lp, remoteHost: rh, remotePort: rp,
                            bindAddress: "127.0.0.1", label: "MCP · " + conn.clientName)
        store.add(f)
        if args["start"] as? Bool ?? true {
            store.start(f, store: hosts)
            try? await Task.sleep(for: .milliseconds(800))
        }
        return withAudit(Outcome(text: json(["id": f.id.uuidString, "forward": what, "state": forwardState(store, f)])), audit!)
    }

    private static func forward(_ store: ForwardStore?, _ args: [String: Any]) -> Result<(ForwardStore, PortForward), Outcome> {
        guard let store else { return .failure(.error("Wireline is still starting; retry shortly.")) }
        guard let id = (args["id"] as? String).flatMap(UUID.init(uuidString:)), let f = store.forwards.first(where: { $0.id == id }) else {
            return .failure(.error("No port forward with id \(args["id"] as? String ?? "(missing)"). forward_list shows them."))
        }
        return .success((store, f))
    }

    private static func forwardStart(_ hosts: HostStore, _ store: ForwardStore?, _ args: [String: Any],
                                     conn: MCPServerConnection) async -> Outcome {
        let (s, f): (ForwardStore, PortForward)
        switch forward(store, args) { case .success(let x): (s, f) = x; case .failure(let o): return o }
        let (audit, stop) = pass(await gate(MCPPolicy.change(mode: mode), key: "fwd-start|\(f.id)", conn: conn) {
            MCPApproval(client: conn.clientName, title: loc.t("启动端口转发", "Start a port forward"),
                        subject: "\(f.label ?? f.hostAlias): \(f.localPort) → \(f.hostAlias)", dangerous: false, canAlwaysAllow: true)
        })
        if let stop { return stop }
        s.start(f, store: hosts)
        try? await Task.sleep(for: .milliseconds(800))
        return withAudit(Outcome(text: "\(f.id.uuidString): \(forwardState(s, f))"), audit!)
    }

    private static func forwardStop(_ store: ForwardStore?, _ args: [String: Any]) -> Outcome {
        let (s, f): (ForwardStore, PortForward)
        switch forward(store, args) { case .success(let x): (s, f) = x; case .failure(let o): return o }
        s.stop(f)
        return withAudit(Outcome(text: "Stopped \(f.id.uuidString)."), "auto")
    }

    // MARK: snippets

    private static func snippetList(_ store: SnippetStore?, query: String?) -> Outcome {
        guard let store else { return .error("Wireline is still starting; retry shortly.") }
        let q = query?.trimmingCharacters(in: .whitespaces) ?? ""
        let picked = store.snippets.filter { q.isEmpty || $0.allTitles.localizedCaseInsensitiveContains(q) || $0.command.localizedCaseInsensitiveContains(q) }
        let list: [[String: Any]] = picked.map { s in
            var d: [String: Any] = ["id": s.id.uuidString, "title": s.title(chinese: loc.isChinese), "command": s.command,
                                    "platform": s.platform.rawValue]
            if !s.parameters.isEmpty {
                d["parameters"] = s.parameters.map { p -> [String: Any] in
                    var x: [String: Any] = ["name": p.name]
                    if let v = s.lastValues[p.name] ?? p.defaultValue { x["value"] = v }
                    return x
                }
            }
            return d
        }
        return Outcome(text: list.isEmpty ? "No snippets match." : json(list))
    }

    private static func snippetRun(_ store: SnippetStore?, _ sessions: SessionStore, _ args: [String: Any],
                                   conn: MCPServerConnection) async -> Outcome {
        guard let store else { return .error("Wireline is still starting; retry shortly.") }
        guard let key = args["snippet"] as? String,
              let s = UUID(uuidString: key).flatMap({ id in store.snippets.first { $0.id == id } }) ?? store.find(named: key) else {
            return .error("No snippet \(args["snippet"] as? String ?? "(missing)"). snippet_list shows them.")
        }
        let given = (args["values"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
        var values: [String: String] = [:]
        for p in s.parameters { values[p.name] = given[p.name] ?? s.lastValues[p.name] ?? p.defaultValue }
        let missing = s.parameters.map(\.name).filter { (values[$0] ?? "").isEmpty }
        guard missing.isEmpty else { return .error("Give values for: \(missing.joined(separator: ", ")).") }
        var exec = args
        exec["command"] = s.filled(with: values)
        let outcome = await sessionExec(sessions, exec, conn: conn)
        if !outcome.isError { store.recordUse(s.id, values: values) }
        return outcome
    }

    // MARK: hosts_admin

    private static func hostAdd(_ hosts: HostStore, _ args: [String: Any], conn: MCPServerConnection) async -> Outcome {
        guard let alias = (args["alias"] as? String)?.trimmingCharacters(in: .whitespaces), !alias.isEmpty,
              alias.rangeOfCharacter(from: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "*?!#"))) == nil else {
            return .error("alias is required (no spaces or *?!#).")
        }
        guard !hosts.hosts.contains(where: { $0.alias == alias }) else { return .error("\(alias) already exists; use host_update.") }
        guard let hostname = (args["hostname"] as? String)?.trimmingCharacters(in: .whitespaces), !hostname.isEmpty else {
            return .error("hostname is required")
        }
        var h = Host(alias: alias, hostname: hostname)
        apply(args, to: &h)
        let block = describe(h)
        let (audit, stop) = pass(await gate(MCPPolicy.alwaysAsk(mode: mode), key: "host-add|\(alias)", conn: conn) {
            MCPApproval(client: conn.clientName, title: loc.t("在 ~/.ssh/config 里新增主机", "Add a host to ~/.ssh/config"),
                        subject: alias, detail: block.split(separator: "\n").map { "+ " + $0 }.joined(separator: "\n"),
                        dangerous: false, canAlwaysAllow: false)
        })
        if let stop { return stop }
        hosts.upsert(h, password: nil)
        return withAudit(Outcome(text: "Added \(alias).\n" + block), audit!)
    }

    private static func hostUpdate(_ hosts: HostStore, _ args: [String: Any], conn: MCPServerConnection) async -> Outcome {
        guard let alias = args["alias"] as? String, let old = hosts.hosts.first(where: { $0.alias == alias }) else {
            return .error("Unknown host alias \(args["alias"] as? String ?? "(missing)").")
        }
        var h = old
        apply(args, to: &h)
        let before = describe(old), after = describe(h)
        guard before != after else { return Outcome(text: "Nothing to change.") }
        let (audit, stop) = pass(await gate(MCPPolicy.alwaysAsk(mode: mode), key: "host-update|\(alias)", conn: conn) {
            MCPApproval(client: conn.clientName, title: loc.t("修改 ~/.ssh/config 里的主机", "Change a host in ~/.ssh/config"),
                        subject: alias, detail: LineDiff.unified(old: before, new: after), dangerous: false, canAlwaysAllow: false)
        })
        if let stop { return stop }
        hosts.upsert(h, password: nil, originalAlias: alias)
        return withAudit(Outcome(text: "Updated \(alias).\n" + after), audit!)
    }

    /// Fields given in `args` onto `h`; "" clears an optional one.
    private static func apply(_ args: [String: Any], to h: inout Host) {
        func opt(_ key: String) -> String?? {
            guard let v = args[key] as? String else { return nil }
            let t = v.trimmingCharacters(in: .whitespaces)
            return .some(t.isEmpty ? nil : t)
        }
        if let v = opt("hostname"), let v { h.hostname = v }
        if let v = opt("user") { h.user = v }
        if let v = opt("group") { h.group = v }
        if let v = opt("description") { h.descriptionText = v }
        if let v = opt("jump") { h.proxyJump = v }
        if args["port"] != nil { h.port = int(args["port"]).flatMap { (1...65535).contains($0) ? $0 : nil } }
    }

    private static func describe(_ h: Host) -> String {
        var lines = ["Host \(h.alias)"]
        if let v = h.hostname { lines.append("  HostName \(v)") }
        if let v = h.user { lines.append("  User \(v)") }
        if let v = h.port { lines.append("  Port \(v)") }
        if let v = h.proxyJump { lines.append("  ProxyJump \(v)") }
        if let v = h.group { lines.append("  # group: \(v)") }
        if let v = h.descriptionText { lines.append("  # description: \(v)") }
        return lines.joined(separator: "\n")
    }

    private static func hostNote(_ hosts: HostStore, _ args: [String: Any], add: Bool) -> Outcome {
        guard let alias = args["alias"] as? String, hosts.hosts.contains(where: { $0.alias == alias }) else {
            return .error("Unknown host alias \(args["alias"] as? String ?? "(missing)").")
        }
        guard let note = (args["note"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty else {
            return .error("note is required")
        }
        if case .deny(let why) = MCPPolicy.minor(mode: mode) { return .refused(why) }
        if add { HostMemoryStore.shared.add(note, for: alias) } else { HostMemoryStore.shared.remove(note, for: alias) }
        return withAudit(Outcome(text: (add ? "Noted for \(alias): " : "Forgot for \(alias): ") + note), "auto")
    }
}

/// A command left running on a host for an MCP client (`exec_start`). Output
/// is kept up to `cap` bytes; older bytes are dropped and reported as skipped.
final class MCPJob: @unchecked Sendable {
    let alias: String
    let command: String
    private let lock = NSLock()
    private var buffer = Data()
    /// Stream offset of `buffer`'s first byte.
    private var base = 0
    private var lastRead = 0
    private var exitCode: Int32?
    private var process: Process?
    static let cap = 2 << 20

    init(alias: String, command: String) {
        self.alias = alias
        self.command = command
    }

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return exitCode == nil && process != nil }

    func start() -> Bool {
        let p = FleetRunner.spawn(command: command, on: alias, onOutput: { [weak self] data in
            self?.append(data)
        }, onExit: { [weak self] code in
            guard let self else { return }
            self.lock.lock(); self.exitCode = code; self.lock.unlock()
        })
        lock.lock(); process = p; lock.unlock()
        return p != nil
    }

    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)
        if buffer.count > Self.cap {
            let drop = buffer.count - Self.cap
            // A fresh, zero-based Data: removeFirst would leave a slice whose
            // indices no longer start at 0.
            buffer = buffer.subdata(in: (buffer.startIndex + drop)..<buffer.endIndex)
            base += drop
        }
    }

    struct Read { var text: String; var next: Int; var running: Bool; var exitCode: Int32?; var skipped: Int }

    /// Output from `since` (default: where the last read stopped), at most 64 KB.
    func read(since: Int?) -> Read {
        lock.lock(); defer { lock.unlock() }
        let end = base + buffer.count
        var from = min(max(since ?? lastRead, 0), end)
        let skipped = max(0, base - from)
        from = max(from, base)
        let to = min(end, from + 64 * 1024)
        let slice = buffer.subdata(in: (from - base)..<(to - base))
        lastRead = to
        return Read(text: String(decoding: slice, as: UTF8.self), next: to,
                    running: exitCode == nil && process != nil, exitCode: exitCode, skipped: skipped)
    }

    func stop() {
        lock.lock(); let p = process; lock.unlock()
        if let p, p.isRunning { p.terminate() }
    }
}
