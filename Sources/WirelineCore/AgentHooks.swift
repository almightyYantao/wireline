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
        /// It wants a permission or has been idle waiting for you.
        case notification(String?)
        /// Its turn ended.
        case stop

        /// The Claude Code hook events Wireline installs, by name.
        public static let hookNames = ["UserPromptSubmit", "Notification", "Stop"]

        public init?(name: String, message: String? = nil) {
            switch name {
            case "UserPromptSubmit": self = .promptSubmitted
            case "Notification": self = .notification(message)
            case "Stop": self = .stop
            default: return nil
            }
        }

        public var state: CodingAgentTracker.State {
            switch self {
            case .promptSubmitted: .working
            case .notification(let m): .needsYou(m)
            case .stop: .done
            }
        }
    }

    public struct Message: Equatable, Sendable {
        public var sessionID: UUID
        public var event: Event
        /// The Claude Code conversation the event belongs to (`session_id`).
        public var resume: AIResume?
    }

    /// `<uuid> <event>` optionally followed by the hook's JSON payload (whose
    /// `message` becomes a notification's text).
    public static func parse(_ line: String) -> Message? {
        let parts = line.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2, let id = UUID(uuidString: String(parts[0])) else { return nil }
        var message: String?
        var resume: AIResume?
        if parts.count == 3 {
            resume = CodingAgentSessions.claude(hookPayload: String(parts[2]))
        }
        if parts.count == 3, let data = parts[2].data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let m = obj["message"] as? String, !m.isEmpty {
            message = m
        }
        guard let event = Event(name: String(parts[1]), message: message) else { return nil }
        return Message(sessionID: id, event: event, resume: resume)
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
    public static func merged(settings: [String: Any]) -> [String: Any]? {
        var out = settings
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        var changed = false
        for name in Event.hookNames {
            var groups = hooks[name] as? [Any] ?? []
            if groups.contains(where: containsOurs) { continue }
            groups.append(["hooks": [["type": "command", "command": command(for: name)]]] as [String: Any])
            hooks[name] = groups
            changed = true
        }
        guard changed else { return nil }
        out["hooks"] = hooks
        return out
    }

    /// Merge into the JSON text of a settings file (nil / empty: no file yet).
    /// Returns the new text, or nil when nothing needs writing.
    public static func merged(settingsJSON data: Data?) throws -> Data? {
        var settings: [String: Any] = [:]
        if let data, !data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x09 || $0 == 0x0D }) {
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CocoaError(.propertyListReadCorrupt)
            }
            settings = obj
        }
        guard let out = merged(settings: settings) else { return nil }
        return try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// Whether every Wireline hook is present.
    public static func isInstalled(settingsJSON data: Data?) -> Bool {
        guard let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return merged(settings: obj) == nil
    }

    private static func containsOurs(_ group: Any) -> Bool {
        guard let hooks = (group as? [String: Any])?["hooks"] as? [Any] else { return false }
        return hooks.contains { (($0 as? [String: Any])?["command"] as? String)?.contains(marker) == true }
    }
}
