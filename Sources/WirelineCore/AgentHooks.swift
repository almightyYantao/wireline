import Foundation

/// Exact coding-agent state, reported by the agent itself through Claude Code
/// hooks instead of guessed from the outside. A local shell gets
/// `WIRELINE_SESSION_ID` and `WIRELINE_HOOK_SOCK` in its environment; the hook
/// command writes one line, `<session id> <event> [hook JSON]`, to that socket.
/// See docs/design/agent-hooks.md.
public enum AgentHooks {
    public static let sessionEnv = "WIRELINE_SESSION_ID"
    public static let socketEnv = "WIRELINE_HOOK_SOCK"

    /// `~/Library/Application Support/Wireline/mcp/hooks-v1.sock`.
    public static var socketPath: String {
        MCPBridge.directory.appendingPathComponent("hooks-v1.sock").path
    }

    public enum Event: Equatable, Sendable {
        /// You sent a prompt: it's working.
        case promptSubmitted
        /// The same, with the prompt's text (Claude Code's `prompt`).
        case prompted(String)
        /// It's about to run a tool (`PreToolUse`); the tool's name.
        case toolStarted(String)
        /// A tool finished (`PostToolUse` / `PostToolUseFailure`).
        case toolFinished(String, failed: Bool)
        /// It's asking to run something (`PermissionRequest`).
        case permission(String?)
        /// It wants a permission or has been idle waiting for you.
        case notification(String?)
        case subagentStarted
        case subagentStopped
        /// Its turn ended.
        case stop
        /// Its turn ended on an error (`StopFailure`: API error, rate limit…).
        case stopFailed(String?)
        case sessionStarted
        case sessionEnded

        /// The Claude Code hook events Wireline installs, by name.
        public static let hookNames = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                                       "PostToolUseFailure", "PermissionRequest", "Notification",
                                       "SubagentStart", "SubagentStop", "Stop", "StopFailure"]

        public init?(name: String, message: String? = nil) {
            self.init(name: name, fields: { $0 == "message" ? message : nil })
        }

        /// From a hook name and a way to read the payload's string fields.
        init?(name: String, fields: (String) -> String?) {
            func text(_ key: String) -> String? { fields(key).flatMap { $0.isEmpty ? nil : $0 } }
            let tool = text("tool_name") ?? ""
            switch name {
            case "UserPromptSubmit": self = text("prompt").map { .prompted($0) } ?? .promptSubmitted
            case "PreToolUse": self = .toolStarted(tool)
            case "PostToolUse": self = .toolFinished(tool, failed: false)
            case "PostToolUseFailure": self = .toolFinished(tool, failed: true)
            case "PermissionRequest": self = .permission(tool.isEmpty ? nil : tool)
            case "Notification":
                // The idle reminder repeats "your turn", which Stop already said.
                if text("notification_type") == "idle_prompt" { return nil }
                self = .notification(text("message"))
            case "SubagentStart": self = .subagentStarted
            case "SubagentStop": self = .subagentStopped
            case "Stop": self = .stop
            case "StopFailure": self = .stopFailed(text("error") ?? text("message"))
            case "SessionStart": self = .sessionStarted
            case "SessionEnd": self = .sessionEnded
            default: return nil
            }
        }

        /// The state it puts the agent in; nil leaves the state alone.
        public var state: CodingAgentTracker.State? {
            switch self {
            case .promptSubmitted, .prompted, .toolStarted, .toolFinished: .working
            case .permission: .needsYou(nil)
            case .notification(let m): .needsYou(m)
            case .stop, .stopFailed: .done
            case .sessionStarted, .sessionEnded: .idle
            case .subagentStarted, .subagentStopped: nil
            }
        }
    }

    public struct Message: Equatable, Sendable {
        public var sessionID: UUID
        public var event: Event
        public var agent: CodingAgent
        /// The agent's own session id (Codex thread id, …), when it sends one.
        public var agentSessionID: String?
        /// The Claude Code conversation the event belongs to (`session_id`).
        public var resume: AIResume?

        public init(sessionID: UUID, event: Event, agent: CodingAgent = .claude, agentSessionID: String? = nil,
                    resume: AIResume? = nil) {
            self.sessionID = sessionID
            self.event = event
            self.agent = agent
            self.agentSessionID = agentSessionID
            self.resume = resume
        }
    }

    /// `<uuid> <event>` (`<agent>:<event>` for agents other than Claude Code)
    /// optionally followed by the hook's JSON payload (whose
    /// `message` becomes a notification's text).
    public static func parse(_ line: String) -> Message? {
        let parts = line.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2, let id = UUID(uuidString: String(parts[0])) else { return nil }
        var json: [String: Any]?
        if parts.count == 3, let data = parts[2].data(using: .utf8) {
            json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        guard let (agent, event) = decode(event: String(parts[1]), json: json) else { return nil }
        let resume = agent == .claude && parts.count == 3 ? CodingAgentSessions.claude(hookPayload: String(parts[2])) : nil
        return Message(sessionID: id, event: event, agent: agent, agentSessionID: agentSessionID(json), resume: resume)
    }

    // MARK: - SSH: in-band OSC

    /// Over SSH there's no socket: the remote hook writes
    /// `OSC 1337;WirelineHook=<event>;<base64 hook JSON> BEL` to its terminal,
    /// which the pane's output sniffer picks up. Other terminals ignore it.
    public static let oscKey = "1337;WirelineHook="
    /// What marks a remote (OSC) hook as ours.
    public static let remoteMarker = "WirelineHook="
    /// Hook JSON beyond this is cut (the OSC sniffer drops long payloads).
    public static let remotePayloadLimit = 2000

    /// The OSC payload after `oscKey`: `<event>[;<base64 JSON>]`.
    public static func parseOSC(_ payload: String) -> Event? {
        let parts = payload.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        guard let name = parts.first else { return nil }
        var data = Data()
        if parts.count == 2, let d = Data(base64Encoded: String(parts[1]), options: .ignoreUnknownCharacters) { data = d }
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return Event(name: String(name), fields: { key in obj.map { $0[key] as? String } ?? Self.string(key, in: data) })
    }

    /// A string field of a hook JSON payload cut off by the size limit: still
    /// there when it came before the cut.
    static func string(_ key: String, in data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        guard let r = text.range(of: "\"\(key)\""),
              let open = text[r.upperBound...].firstIndex(of: "\"") else { return nil }
        var out = "", escape = false
        for ch in text[text.index(after: open)...] {
            if escape { out.append(ch == "n" ? "\n" : ch); escape = false; continue }
            if ch == "\\" { escape = true; continue }
            if ch == "\"" { return out.isEmpty ? nil : out }
            out.append(ch)
        }
        return nil
    }

    /// The remote hook command: writes the OSC straight to the controlling
    /// terminal (a hook's stdout is captured by Claude Code). No env vars
    /// needed — they don't survive SSH — and it always exits 0.
    public static func remoteCommand(for event: String) -> String {
        "{ printf '\\033]\(oscKey)\(event);'; { head -c \(remotePayloadLimit); cat >/dev/null; } | base64 | tr -d '\\n'; "
            + "printf '\\007'; } 2>/dev/null >/dev/tty; true"
    }

    // MARK: - ~/.claude/settings.json

    /// What marks a hook as ours, so installing twice adds nothing.
    public static let marker = "WIRELINE_HOOK_SOCK"

    /// The shell command for one hook event. Outside Wireline (no env vars) it
    /// does nothing, and it never fails the hook.
    public static func command(for event: String) -> String {
        "[ -n \"$\(sessionEnv)\" ] && [ -S \"$\(marker)\" ] && "
            + "{ printf '%s \(event) ' \"$\(sessionEnv)\"; tr -d '\\n'; echo; } "
            + "| nc -U -w 1 \"$\(marker)\" >/dev/null 2>&1; true"
    }

    /// `settings` with Wireline's hooks added to its `hooks` section, leaving
    /// every existing hook alone. Nil when they're all there already.
    public static func merged(settings: [String: Any], remote: Bool = false) -> [String: Any]? {
        let mark = remote ? remoteMarker : marker
        var out = settings
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        var changed = false
        for name in Event.hookNames {
            var groups = hooks[name] as? [Any] ?? []
            if groups.contains(where: { containsOurs($0, mark) }) { continue }
            let cmd = remote ? remoteCommand(for: name) : command(for: name)
            groups.append(["hooks": [["type": "command", "command": cmd]]] as [String: Any])
            hooks[name] = groups
            changed = true
        }
        guard changed else { return nil }
        out["hooks"] = hooks
        return out
    }

    /// Merge into the JSON text of a settings file (nil / empty: no file yet).
    /// Returns the new text, or nil when nothing needs writing.
    public static func merged(settingsJSON data: Data?, remote: Bool = false) throws -> Data? {
        var settings: [String: Any] = [:]
        if let data, !data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x09 || $0 == 0x0D }) {
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CocoaError(.propertyListReadCorrupt)
            }
            settings = obj
        }
        guard let out = merged(settings: settings, remote: remote) else { return nil }
        return try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// Whether every Wireline hook is present.
    public static func isInstalled(settingsJSON data: Data?, remote: Bool = false) -> Bool {
        guard let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return merged(settings: obj, remote: remote) == nil
    }

    /// `settings` with only Wireline's hook commands taken out. Groups and
    /// events left empty by that go too; everything else stays. Nil when
    /// there is nothing of ours.
    public static func removed(settings: [String: Any]) -> [String: Any]? {
        guard var hooks = settings["hooks"] as? [String: Any] else { return nil }
        var changed = false
        for (name, value) in hooks {
            guard let groups = value as? [Any] else { continue }
            var kept: [Any] = []
            for group in groups {
                guard containsOurs(group), var dict = group as? [String: Any],
                      let entries = dict["hooks"] as? [Any] else { kept.append(group); continue }
                changed = true
                let rest = entries.filter { !isOurs($0) }
                if rest.isEmpty { continue }
                dict["hooks"] = rest
                kept.append(dict)
            }
            hooks[name] = kept.isEmpty ? nil : kept
        }
        guard changed else { return nil }
        var out = settings
        out["hooks"] = hooks.isEmpty ? nil : hooks
        return out
    }

    /// Remove from the JSON text of a settings file. Nil when nothing changes.
    public static func removed(settingsJSON data: Data?) throws -> Data? {
        guard let data, !data.isEmpty else { return nil }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        guard let out = removed(settings: obj) else { return nil }
        return try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// Whether any Wireline hook is present (even a partial install).
    public static func hasAny(settingsJSON data: Data?) -> Bool {
        guard let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return removed(settings: obj) != nil
    }

    private static func isOurs(_ entry: Any) -> Bool {
        ((entry as? [String: Any])?["command"] as? String)?.contains(marker) == true
    }

    private static func containsOurs(_ group: Any, _ marker: String = marker) -> Bool {
        guard let hooks = (group as? [String: Any])?["hooks"] as? [Any] else { return false }
        return hooks.contains { (($0 as? [String: Any])?["command"] as? String)?.contains(marker) == true }
    }
}
