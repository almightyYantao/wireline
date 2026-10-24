import Foundation
import CryptoKit
import WirelineCore

/// The tools Wireline's MCP server offers (docs/design/mcp-server.md §2). Each
/// returns text; `MCPServerConnection` restored its arguments and masks the
/// text before it leaves. Anything that may change something goes through
/// `MCPPolicy` and, when that says so, the user (`MCPApprovalCenter`).
@MainActor
enum MCPServerTools {
    struct Outcome {
        var text: String
        var isError = false
        /// For the audit log: "ok", "auto", "approved", "denied", "refused".
        var audit = "ok"
        static func error(_ text: String) -> Outcome { Outcome(text: text, isError: true) }
        static func refused(_ text: String) -> Outcome { Outcome(text: text, isError: true, audit: "refused") }
    }

    static let disabledText = "Wireline 的对外 MCP 没有开启。请让用户在 Wireline → 设置 → AI → 对外开放（MCP）里打开，然后重试。"
        + " / Wireline's MCP server is switched off. Ask the user to enable it in Wireline → Settings → AI → MCP server, then retry."

    static func instructions(masking: Bool) -> String {
        var s = """
        Wireline is the user's SSH client: it knows every host in their ~/.ssh/config, its group, and what is open right now. \
        Use these tools for anything on those hosts. Call get_environment first. Address hosts by their ssh-config alias \
        (exactly as hosts_list shows it). Don't run ssh from your own shell for these hosts. \
        Prefer fleet_run for more than one host; it needs no open session. Commands that may change something can \
        wait for the user's approval in Wireline. Errors, denials and refusals are final; don't work around them.
        """
        if masking {
            s += """
             Values like [WL…_IP_3], [WL…_HOST_1] or [WL…_SECRET_2] (… is four random characters) are masked placeholders \
            for real addresses, passwords and keys. Pass them back verbatim in arguments when you need the value; Wireline \
            restores them locally. Never guess or alter them.
            """
        }
        return s
    }

    // MARK: Definitions

    private static func schema(_ properties: [String: Any], required: [String] = []) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required]
    }

    private static func readOnly(_ name: String, _ description: String, _ schema: [String: Any]) -> [String: Any] {
        ["name": name, "description": description, "inputSchema": schema,
         "annotations": ["readOnlyHint": true, "openWorldHint": false]]
    }

    private static func acting(_ name: String, _ description: String, _ schema: [String: Any],
                               destructive: Bool = true) -> [String: Any] {
        ["name": name, "description": description, "inputSchema": schema,
         "annotations": ["readOnlyHint": false, "destructiveHint": destructive, "openWorldHint": false]]
    }

    static var definitions: [[String: Any]] {
        [
            readOnly("get_environment",
                     "What is open in Wireline right now: sessions (id, host alias, kind, working directory, busy, foreground program, connection state), the focused one, and the host groups. Call this first.",
                     schema([:])),
            readOnly("hosts_list",
                     "Hosts from the user's ~/.ssh/config: alias, address, user, port, group, description, reachability, open sessions, and remembered notes. Filter by a text query or a group.",
                     schema(["query": ["type": "string", "description": "Case-insensitive match on alias, address, group or description"],
                             "group": ["type": "string", "description": "Only hosts in this group"]])),
            readOnly("session_read",
                     "Recent output of an open session (ANSI stripped; Wireline keeps about the last 20000 characters).",
                     schema(["session_id": ["type": "string", "description": "From get_environment"],
                             "lines": ["type": "integer", "description": "How many trailing lines (default 200, max 2000)"]],
                            required: ["session_id"])),
            readOnly("file_read",
                     "Read a text file on a host over SSH (no open session needed). Returns its size and, when read completely, its sha256.",
                     schema(["alias": ["type": "string", "description": "Host alias from hosts_list"],
                             "path": ["type": "string", "description": "Absolute path, or relative to the login directory"],
                             "max_bytes": ["type": "integer", "description": "Read at most this many bytes (default 100000, max 1000000)"]],
                            required: ["alias", "path"])),
            acting("session_exec",
                   "Run a shell command in an open SSH or local session and return its output and exit code. By default it runs visibly in the user's terminal; visible=false runs it alongside over the same connection without touching the screen. Read-only commands run at once; others may wait for the user's approval.",
                   schema(["session_id": ["type": "string", "description": "From get_environment or host_open"],
                           "command": ["type": "string"],
                           "visible": ["type": "boolean", "description": "Type it into the terminal (default true)"],
                           "timeout": ["type": "integer", "description": "Seconds before giving up (default 600, max 3600)"]],
                          required: ["session_id", "command"])),
            acting("fleet_run",
                   "Run one shell command on many hosts at once, non-interactively (no open session needed), and get each host's exit code and output. Targets are aliases or @group names. Read-only commands run at once; others may wait for the user's approval.",
                   schema(["targets": ["type": "array", "items": ["type": "string"], "description": "Aliases and/or @group names"],
                           "command": ["type": "string"],
                           "timeout": ["type": "integer", "description": "Seconds per host (default 60, max 1800)"]],
                          required: ["targets", "command"])),
            acting("host_open",
                   "Open an SSH session to a host in a new background Wireline tab (the user stays where they are) and wait for it to connect. Returns the session id for session_exec / session_read.",
                   schema(["alias": ["type": "string", "description": "Host alias from hosts_list"]], required: ["alias"]),
                   destructive: false),
            acting("session_close",
                   "Close a session that this client opened with host_open.",
                   schema(["session_id": ["type": "string"]], required: ["session_id"]), destructive: false),
            acting("file_write",
                   "Write a text file on a host over SSH (created if missing). Pass expected_sha256 from file_read to refuse the write if the file changed since. The user sees the diff and may have to approve it.",
                   schema(["alias": ["type": "string"],
                           "path": ["type": "string"],
                           "content": ["type": "string", "description": "The complete new content"],
                           "expected_sha256": ["type": "string", "description": "sha256 file_read returned"]],
                          required: ["alias", "path", "content"]))
        ]
    }

    // MARK: Dispatch

    static func run(_ name: String, _ args: [String: Any], conn: MCPServerConnection) async -> Outcome {
        let host = MCPServerHost.shared
        guard let hosts = host.hosts, let sessions = host.sessions else {
            return .error("Wireline 还在启动，请稍后重试。 / Wireline is still starting; retry shortly.")
        }
        switch name {
        case "get_environment": return environment(hosts, sessions)
        case "hosts_list":      return hostsList(hosts, sessions, query: args["query"] as? String, group: args["group"] as? String)
        case "session_read":    return sessionRead(sessions, id: args["session_id"] as? String, lines: int(args["lines"]))
        case "file_read":       return await fileRead(hosts, alias: args["alias"] as? String, path: args["path"] as? String,
                                                      maxBytes: int(args["max_bytes"]))
        case "session_exec":    return await sessionExec(sessions, args, conn: conn)
        case "fleet_run":       return await fleetRun(hosts, args, conn: conn)
        case "host_open":       return await hostOpen(hosts, sessions, alias: args["alias"] as? String, conn: conn)
        case "session_close":   return sessionClose(sessions, id: args["session_id"] as? String, conn: conn)
        case "file_write":      return await fileWrite(hosts, args, conn: conn)
        default:                return .error("Unknown tool: \(name)")
        }
    }

    // MARK: Approval

    enum Gate {
        case go(audit: String)
        case stop(Outcome)
    }

    /// Apply `verdict`, asking the user when it says so. `key` identifies the
    /// request for "don't ask again on this connection".
    static func gate(_ verdict: MCPVerdict, key: String, conn: MCPServerConnection,
                             _ approval: () -> MCPApproval) async -> Gate {
        switch verdict {
        case .allow:
            return .go(audit: "auto")
        case .deny(let why):
            return .stop(.refused(why))
        case .ask(let dangerous):
            if !dangerous, conn.alwaysAllowed.contains(key) { return .go(audit: "auto (allowed for this connection)") }
            switch await MCPApprovalCenter.shared.ask(approval()) {
            case .allow:
                return .go(audit: "approved")
            case .allowAlways:
                conn.alwaysAllowed.insert(key)
                return .go(audit: "approved")
            case .deny:
                var o = Outcome.error("The user denied this in Wireline (or didn't answer in time). Don't retry it; tell the user what you wanted to do.")
                o.audit = "denied"
                return .stop(o)
            }
        }
    }

    private static func withAudit(_ o: Outcome, _ audit: String) -> Outcome {
        var o = o
        if o.audit == "ok" { o.audit = audit }
        return o
    }

    private static func int(_ v: Any?) -> Int? {
        switch v {
        case let i as Int: return i
        case let d as Double: return Int(d)
        case let s as String: return Int(s)
        default: return nil
        }
    }

    private static func json(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: get_environment

    private static func kindName(_ kind: SessionKind) -> String {
        switch kind {
        case .ssh: return "ssh"
        case .sftp: return "sftp"
        case .localShell: return "local"
        case .rdp: return "rdp"
        }
    }

    private static func stateName(_ s: ConnectionState) -> String {
        switch s {
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .disconnected: return "disconnected"
        }
    }

    private static func environment(_ hosts: HostStore, _ sessions: SessionStore) -> Outcome {
        let list: [[String: Any]] = sessions.sessions.map { s in
            var d: [String: Any] = ["id": s.id.uuidString, "title": s.title, "kind": kindName(s.kind),
                                    "state": stateName(s.connectionState), "busy": s.isBusy]
            if !s.alias.isEmpty { d["host"] = s.alias }
            if let cwd = s.currentDirectory { d["cwd"] = cwd }
            if let fg = s.foregroundName { d["program"] = fg }
            return d
        }
        var groups: [String: [String]] = [:]
        for h in hosts.hosts { groups[h.group ?? "(ungrouped)", default: []].append(h.alias) }
        var out: [String: Any] = [
            "sessions": list,
            "groups": groups,
            "host_count": hosts.hosts.count,
            "privacy": AIConfig.shared.privacyLevel.rawValue
        ]
        if let id = sessions.activeID { out["focused_session"] = id.uuidString }
        return Outcome(text: json(out))
    }

    // MARK: hosts_list

    private static func statusText(_ s: HostStatus?) -> String {
        switch s {
        case .online(let ms)?: return "online (\(ms) ms)"
        case .offline?: return "offline"
        case .checking?: return "checking"
        case .unknown?, nil: return "unknown"
        }
    }

    private static func hostsList(_ hosts: HostStore, _ sessions: SessionStore, query: String?, group: String?) -> Outcome {
        let q = query?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        let g = group?.trimmingCharacters(in: .whitespaces) ?? ""
        let picked = hosts.hosts.filter { h in
            if !g.isEmpty, (h.group ?? "") != g { return false }
            guard !q.isEmpty else { return true }
            return [h.alias, h.hostname ?? "", h.group ?? "", h.descriptionText ?? ""]
                .contains { $0.lowercased().contains(q) }
        }
        let list: [[String: Any]] = picked.map { h in
            var d: [String: Any] = ["alias": h.alias, "protocol": h.hostProtocol.rawValue,
                                    "address": h.connectHostname, "port": h.effectivePort,
                                    "status": statusText(hosts.statuses[h.alias])]
            if let u = h.user { d["user"] = u }
            if let gr = h.group { d["group"] = gr }
            if let desc = h.descriptionText, !desc.isEmpty { d["description"] = desc }
            if let jump = h.proxyJump { d["jump"] = jump }
            let open = sessions.sessions.filter { $0.alias == h.alias && $0.isRunning }.map(\.id.uuidString)
            if !open.isEmpty { d["open_sessions"] = open }
            let notes = HostMemoryStore.shared.facts(for: h.alias)
            if !notes.isEmpty { d["notes"] = notes }
            return d
        }
        if list.isEmpty { return Outcome(text: "No hosts match.") }
        return Outcome(text: json(list))
    }

    // MARK: session_read

    private static func sessionRead(_ sessions: SessionStore, id: String?, lines: Int?) -> Outcome {
        guard let id, let uuid = UUID(uuidString: id), let s = sessions.session(uuid) else {
            return .error("No open session with id \(id ?? "(missing)"). Call get_environment for the current ids.")
        }
        let n = min(max(lines ?? 200, 1), 2000)
        let all = s.recentOutput.split(separator: "\n", omittingEmptySubsequences: false)
        let tail = all.suffix(n).joined(separator: "\n")
        let name = s.alias.isEmpty ? s.title : s.alias
        return Outcome(text: "session \(id) (\(name), \(stateName(s.connectionState)))\n-----\n" + tail)
    }

    // MARK: file_read

    /// `'it'\''s'`: safe inside any POSIX shell.
    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }

    /// The remote side of `file_read`: plain sh (whatever the login shell is),
    /// the content base64-encoded between markers, so ssh's own chatter on the
    /// same stream can't corrupt it and binary files are detectable.
    static func fileReadScript(path: String, maxBytes: Int) -> String {
        let script = """
        f=\(shellQuote(path))
        if [ -d "$f" ]; then echo "__WL_ERR__ is a directory"; exit 3; fi
        if [ ! -e "$f" ]; then echo "__WL_ERR__ no such file"; exit 3; fi
        if [ ! -r "$f" ]; then echo "__WL_ERR__ permission denied"; exit 3; fi
        printf '__WL_SIZE__%s\\n' "$(wc -c < "$f" | tr -d ' ')"
        echo __WL_BEGIN__
        head -c \(maxBytes) "$f" | base64
        echo __WL_END__
        """
        return "sh -c " + shellQuote(script)
    }

    /// Pull the file back out of `fileReadScript`'s output.
    static func parseFileRead(_ output: String) -> (size: Int, data: Data)? {
        guard let b = output.range(of: "__WL_BEGIN__\n"),
              let e = output.range(of: "__WL_END__", range: b.upperBound..<output.endIndex),
              let sizeLine = output.range(of: #"__WL_SIZE__(\d+)"#, options: .regularExpression) else { return nil }
        let size = Int(output[sizeLine].dropFirst("__WL_SIZE__".count)) ?? 0
        let b64 = String(output[b.upperBound..<e.lowerBound])
        guard let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else { return nil }
        return (size, data)
    }

    /// UTF-8 text, or nil for binary. A cut-off read may end mid-character:
    /// drop up to three trailing bytes before calling it binary.
    static func decodeText(_ data: Data, truncated: Bool) -> String? {
        for cut in 0...(truncated ? min(3, data.count) : 0) {
            if let s = String(data: data.dropLast(cut), encoding: .utf8) { return s }
        }
        return nil
    }

    private static func fileRead(_ hosts: HostStore, alias: String?, path: String?, maxBytes: Int?) async -> Outcome {
        guard let alias, let host = hosts.hosts.first(where: { $0.alias == alias }) else {
            return .error("Unknown host alias \(alias ?? "(missing)"). Use hosts_list for the aliases.")
        }
        guard !host.isRDP else { return .error("\(alias) is a remote-desktop host; files are only readable over SSH.") }
        guard let path, !path.isEmpty else { return .error("path is required") }
        let limit = min(max(maxBytes ?? 100_000, 1), 1_000_000)
        let r = await FleetRunner.run(command: fileReadScript(path: path, maxBytes: limit), on: [alias], timeout: 20)
        guard let result = r.first else { return .error("No result from \(alias).") }
        if let err = result.output.range(of: #"__WL_ERR__ .*"#, options: .regularExpression) {
            return .error("\(alias):\(path): " + result.output[err].dropFirst("__WL_ERR__ ".count))
        }
        guard result.ok, let file = parseFileRead(result.output) else {
            return .error("Couldn't read \(alias):\(path) (exit \(result.exitCode)):\n" + String(result.output.suffix(2000)))
        }
        let truncated = file.data.count < file.size
        guard let text = decodeText(file.data, truncated: truncated), !text.contains("\u{0}") else {
            return .error("\(alias):\(path) is a binary file (\(file.size) bytes); only text files can be read.")
        }
        var header = "host: \(alias)\npath: \(path)\nsize: \(file.size) bytes"
        if truncated {
            header += "\ntruncated: first \(file.data.count) bytes only (raise max_bytes for more)"
        } else {
            header += "\nsha256: " + sha256(file.data)
        }
        return Outcome(text: header + "\n-----\n" + text)
    }

    // MARK: session_exec

    private static func sessionExec(_ sessions: SessionStore, _ args: [String: Any], conn: MCPServerConnection) async -> Outcome {
        guard let id = args["session_id"] as? String, let uuid = UUID(uuidString: id), let s = sessions.session(uuid) else {
            return .error("No open session with id \(args["session_id"] as? String ?? "(missing)"). Call get_environment, or host_open one.")
        }
        guard let command = (args["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty else {
            return .error("command is required")
        }
        switch s.kind {
        case .ssh, .localShell: break
        case .sftp, .rdp: return .error("That session is \(kindName(s.kind)); commands run only in SSH and local sessions.")
        }
        guard s.isRunning, s.connectionState == .connected else {
            return .error("That session isn't connected (\(stateName(s.connectionState))). host_open a new one.")
        }
        let visible = args["visible"] as? Bool ?? true
        if visible, s.isBusy {
            let what = s.foregroundName.map { " (\($0))" } ?? ""
            return .error("Something is running in that session\(what); typing a command would go into it. Wait for it, use visible=false, or host_open another session.")
        }
        let target = s.alias.isEmpty ? Localizer.shared.t("本机", "this Mac") : s.alias
        let verdict = MCPPolicy.command(command, mode: MCPServerSettings.shared.mode)
        let gate = await gate(verdict, key: "exec|\(s.alias)|\(command)", conn: conn) {
            MCPApproval(client: conn.clientName, title: Localizer.shared.t("在 \(target) 上执行", "Run on \(target)"),
                        subject: command, dangerous: verdict == .ask(dangerous: true),
                        canAlwaysAllow: verdict != .ask(dangerous: true), sessionID: s.id)
        }
        guard case .go(let audit) = gate else { if case .stop(let o) = gate { return o }; return .error("") }

        let islandID = "mcp-run:" + UUID().uuidString
        IslandCenter.shared.upsert(IslandItem(id: islandID, source: .ai, title: Localizer.shared.t("外部 AI · ", "AI client · ") + conn.clientName,
                                              detail: "\(command) @ \(target)", tone: .working, sessionID: s.id, at: Date()))
        let limit = TimeInterval(min(max(int(args["timeout"]) ?? 600, 5), 3600))
        let output = visible
            ? await s.runInTerminalCapturing(command, idleTimeout: min(120, limit), maxTimeout: limit)
            : await s.runCapturing(command)
        let timedOut = output == "(执行超时)"
        IslandCenter.shared.finish(islandID, success: !timedOut, detail: command, pulse: nil)
        if timedOut {
            return withAudit(.error("Timed out after \(Int(limit)) s (or no output for 120 s). It may still be running in the session; session_read to check."), audit)
        }
        return withAudit(Outcome(text: String(output.suffix(20000))), audit)
    }

    // MARK: fleet_run

    /// Aliases and `@group`s → SSH aliases, in the order given, plus the names
    /// that matched nothing.
    static func resolveTargets(_ targets: [String], hosts: [Host]) -> (aliases: [String], unknown: [String]) {
        var aliases: [String] = [], unknown: [String] = []
        for t in targets.map({ $0.trimmingCharacters(in: .whitespaces) }) where !t.isEmpty {
            let matched: [Host]
            if t.hasPrefix("@") {
                let g = String(t.dropFirst())
                matched = hosts.filter { $0.group == g }
            } else {
                matched = hosts.filter { $0.alias == t }
            }
            let ssh = matched.filter { !$0.isRDP }
            if ssh.isEmpty { unknown.append(t) }
            for h in ssh where !aliases.contains(h.alias) { aliases.append(h.alias) }
        }
        return (aliases, unknown)
    }

    private static func fleetRun(_ hosts: HostStore, _ args: [String: Any], conn: MCPServerConnection) async -> Outcome {
        let raw: [String] = (args["targets"] as? [String]) ?? (args["targets"] as? String).map { [$0] } ?? []
        guard let command = (args["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty else {
            return .error("command is required")
        }
        let (aliases, unknown) = resolveTargets(raw, hosts: hosts.hosts)
        guard unknown.isEmpty else {
            return .error("No SSH hosts match: \(unknown.joined(separator: ", ")). Use aliases from hosts_list, or @group.")
        }
        guard !aliases.isEmpty else { return .error("targets is required") }
        guard aliases.count <= 100 else { return .error("At most 100 hosts per run (\(aliases.count) given).") }

        let verdict = MCPPolicy.command(command, mode: MCPServerSettings.shared.mode, hostCount: aliases.count)
        let gate = await gate(verdict, key: "fleet|\(aliases.joined(separator: ","))|\(command)", conn: conn) {
            MCPApproval(client: conn.clientName,
                        title: Localizer.shared.t("在 \(aliases.count) 台主机上执行", "Run on \(aliases.count) hosts"),
                        subject: command, detail: aliases.joined(separator: "\n"),
                        dangerous: verdict == .ask(dangerous: true), canAlwaysAllow: verdict != .ask(dangerous: true))
        }
        guard case .go(let audit) = gate else { if case .stop(let o) = gate { return o }; return .error("") }

        let islandID = "mcp-fleet:" + UUID().uuidString
        let island = IslandCenter.shared
        island.fleetStarted(islandID, command: command, total: aliases.count)
        var done = 0, failed = 0
        let timeout = min(max(int(args["timeout"]) ?? 60, 5), 1800)
        let results = await FleetRunner.run(command: command, on: aliases, timeout: timeout) { r in
            done += 1
            if !r.ok { failed += 1 }
            island.fleetProgress(islandID, done: done, failed: failed)
        }
        island.fleetFinished(islandID, total: aliases.count, failed: results.filter { !$0.ok }.count)
        let ok = results.filter(\.ok).count
        var text = "\(ok)/\(results.count) hosts exited 0.\n"
        for r in results {
            text += "\n### \(r.alias) (exit \(r.exitCode))\n" + String(r.output.suffix(3000)) + "\n"
            if text.count > 60000 { text += "\n(output truncated)"; break }
        }
        return withAudit(Outcome(text: text), audit)
    }

    // MARK: host_open / session_close

    private static func hostOpen(_ hosts: HostStore, _ sessions: SessionStore, alias: String?, conn: MCPServerConnection) async -> Outcome {
        guard let alias, let host = hosts.hosts.first(where: { $0.alias == alias }) else {
            return .error("Unknown host alias \(alias ?? "(missing)"). Use hosts_list for the aliases.")
        }
        guard !host.isRDP else { return .error("\(alias) is a remote desktop; only SSH hosts can be opened as sessions.") }
        let id = sessions.open(host: host, password: hosts.password(for: host),
                               sudoPassword: hosts.sudoPassword(for: host), focus: false)
        guard let s = sessions.session(id) else { return .error("Couldn't open a session to \(alias).") }
        s.openedBy = conn.clientName
        conn.opened.insert(id)
        let deadline = Date().addingTimeInterval(30)
        while s.connectionState == .connecting, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(250))
        }
        // Give the shell a moment to print its prompt (or a password prompt).
        if s.connectionState == .connected { try? await Task.sleep(for: .milliseconds(800)) }
        let tail = s.recentOutput.split(separator: "\n", omittingEmptySubsequences: false).suffix(15).joined(separator: "\n")
        return withAudit(Outcome(text: json(["session_id": id.uuidString, "host": alias,
                                             "state": stateName(s.connectionState), "screen": tail]),
                                 isError: s.connectionState == .disconnected), "auto")
    }

    private static func sessionClose(_ sessions: SessionStore, id: String?, conn: MCPServerConnection) -> Outcome {
        guard let id, let uuid = UUID(uuidString: id), sessions.session(uuid) != nil else {
            return .error("No open session with id \(id ?? "(missing)").")
        }
        guard conn.opened.contains(uuid) else {
            return .refused("Only sessions this client opened with host_open can be closed; that one is the user's.")
        }
        sessions.close(uuid)
        conn.opened.remove(uuid)
        return withAudit(Outcome(text: "Closed \(id)."), "auto")
    }

    // MARK: file_write

    /// The remote side of `file_write`: take the content on stdin into a temp
    /// file first (so a dropped link never leaves half a file), then copy it
    /// over the target, which keeps the file's owner and permissions.
    static func fileWriteScript(path: String) -> String {
        let script = """
        f=\(shellQuote(path))
        tmp=$(mktemp) || exit 4
        cat > "$tmp" || { rm -f "$tmp"; exit 4; }
        cat "$tmp" > "$f"; rc=$?
        rm -f "$tmp"
        exit $rc
        """
        return "sh -c " + shellQuote(script)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func fileWrite(_ hosts: HostStore, _ args: [String: Any], conn: MCPServerConnection) async -> Outcome {
        guard let alias = args["alias"] as? String, let host = hosts.hosts.first(where: { $0.alias == alias }) else {
            return .error("Unknown host alias \(args["alias"] as? String ?? "(missing)"). Use hosts_list for the aliases.")
        }
        guard !host.isRDP else { return .error("\(alias) is a remote desktop; files are only writable over SSH.") }
        guard let path = args["path"] as? String, !path.isEmpty else { return .error("path is required") }
        guard let content = args["content"] as? String else { return .error("content is required") }
        let expected = (args["expected_sha256"] as? String)?.lowercased()

        // What's there now: for the diff, and to check expected_sha256.
        let limit = 2_000_000
        let read = await FleetRunner.run(command: fileReadScript(path: path, maxBytes: limit), on: [alias], timeout: 20).first
        let original: String?
        if let out = read?.output, out.contains("__WL_ERR__ no such file") {
            original = nil
        } else if let out = read?.output, let err = out.range(of: #"__WL_ERR__ .*"#, options: .regularExpression) {
            return .error("\(alias):\(path): " + out[err].dropFirst("__WL_ERR__ ".count))
        } else if let read, read.ok, let file = parseFileRead(read.output) {
            guard file.data.count >= file.size else { return .error("\(alias):\(path) is over \(limit) bytes; too big to rewrite here.") }
            guard let text = decodeText(file.data, truncated: false), !text.contains("\u{0}") else {
                return .error("\(alias):\(path) is a binary file; it won't be overwritten.")
            }
            if let expected, sha256(file.data) != expected {
                return .error("\(alias):\(path) changed since you read it (sha256 differs). file_read it again and redo the edit.")
            }
            original = text
        } else {
            return .error("Couldn't read \(alias):\(path) before writing (exit \(read?.exitCode ?? -1)):\n" + String((read?.output ?? "").suffix(2000)))
        }
        if original == nil, expected != nil {
            return .error("\(alias):\(path) doesn't exist, but expected_sha256 was given. file_read it again.")
        }
        if original == content { return Outcome(text: "\(alias):\(path) already has exactly this content; nothing written.") }

        let summary = original.map { LineDiff.summary(old: $0, new: content) } ?? "+\(content.components(separatedBy: "\n").count)"
        let diff = LineDiff.unified(old: original ?? "", new: content)
        let shownDiff = diff.components(separatedBy: "\n").prefix(400).joined(separator: "\n")
        let loc = Localizer.shared
        let gate = await gate(MCPPolicy.fileWrite(mode: MCPServerSettings.shared.mode), key: "write|\(alias)|\(path)", conn: conn) {
            MCPApproval(client: conn.clientName,
                        title: original == nil ? loc.t("在 \(alias) 上新建文件（\(summary)）", "Create a file on \(alias) (\(summary))")
                                               : loc.t("修改 \(alias) 上的文件（\(summary)）", "Change a file on \(alias) (\(summary))"),
                        subject: path, detail: shownDiff, dangerous: false, canAlwaysAllow: false)
        }
        guard case .go(let audit) = gate else { if case .stop(let o) = gate { return o }; return .error("") }

        let data = Data(content.utf8)
        let r = await FleetRunner.run(command: fileWriteScript(path: path), on: alias, input: data, timeout: 30)
        guard r.ok else {
            return withAudit(.error("Writing \(alias):\(path) failed (exit \(r.exitCode)): \(String(r.output.suffix(1000)))"
                                    + (r.output.contains("ermission denied") ? " — the SSH user can't write there; ask the user to do it with sudo." : "")), audit)
        }
        return withAudit(Outcome(text: "Wrote \(alias):\(path) (\(data.count) bytes, \(summary)).\nsha256: \(sha256(data))"), audit)
    }
}
