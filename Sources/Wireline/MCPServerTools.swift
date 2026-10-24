import Foundation
import CryptoKit
import WirelineCore

/// The tools Wireline's MCP server offers. P2: read-only ones only
/// (docs/design/mcp-server.md §2). Each returns text; `MCPServerConnection`
/// masks it before it leaves.
@MainActor
enum MCPServerTools {
    struct Outcome {
        var text: String
        var isError = false
        static func error(_ text: String) -> Outcome { Outcome(text: text, isError: true) }
    }

    static let disabledText = "Wireline 的对外 MCP 没有开启。请让用户在 Wireline → 设置 → AI → 对外开放（MCP）里打开，然后重试。"
        + " / Wireline's MCP server is switched off. Ask the user to enable it in Wireline → Settings → AI → MCP server, then retry."

    static func instructions(masking: Bool) -> String {
        var s = """
        Wireline is the user's SSH client: it knows every host in their ~/.ssh/config, its group, and what is open right now. \
        Use these tools for anything on those hosts. Call get_environment first. Address hosts by their ssh-config alias \
        (exactly as hosts_list shows it). Don't run ssh from your own shell for these hosts. \
        Errors and refusals are final; don't work around them.
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
                            required: ["alias", "path"]))
        ]
    }

    // MARK: Dispatch

    static func run(_ name: String, _ args: [String: Any], clientName: String) async -> Outcome {
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
        default:                return .error("Unknown tool: \(name)")
        }
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
            header += "\nsha256: " + SHA256.hash(data: file.data).map { String(format: "%02x", $0) }.joined()
        }
        return Outcome(text: header + "\n-----\n" + text)
    }
}
