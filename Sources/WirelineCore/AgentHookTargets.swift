import Foundation

/// Where and how each coding agent takes Wireline's hooks: its event names
/// mapped to working / needs-you / done, and the file they go into. Hooks
/// other than Claude Code's put `<agent>:<event>` on the wire.
/// See docs/design/agent-hooks.md.
public struct AgentHookTarget: Sendable {
    public enum Kind: Equatable, Sendable {
        case working, needsYou, done
    }

    public enum Format: Sendable {
        /// `{"hooks": {"Event": [{"matcher"?, "hooks": [{"type": "command", "command"}]}]}}`:
        /// Claude Code, Codex, Gemini CLI, Qwen Code.
        case groupedJSON
        /// Cursor: `{"version": 1, "hooks": {"event": [{"command"}]}}`.
        case flatJSON
        /// A plugin file of our own (opencode, Amp).
        case plugin(String)
        /// `notifications-command` in ~/.aider.conf.yml.
        case aiderYAML
    }

    public enum Failure: Error, Equatable {
        /// The file holds something of the user's where ours would go.
        case conflict(String)
        case unreadable
    }

    public let agent: CodingAgent
    /// Relative to the home directory.
    public let path: String
    public let format: Format
    /// Hook event name → state, in install order.
    public let events: [(name: String, kind: Kind)]
    /// Whether the events cover a whole turn (start, waiting, end). If not,
    /// the tracker keeps guessing the rest.
    public let complete: Bool

    public func kind(of event: String) -> Kind? {
        events.first { $0.name == event }?.kind
    }

    public static let all: [AgentHookTarget] = [
        // Claude Code's events decode richer than a kind (`AgentHooks.Event`).
        .init(agent: .claude, path: ".claude/settings.json", format: .groupedJSON,
              events: AgentHooks.Event.hookNames.map { name in
                  (name, ["Notification", "PermissionRequest"].contains(name) ? .needsYou
                         : ["Stop", "StopFailure", "SessionStart", "SessionEnd"].contains(name) ? .done : .working)
              }, complete: true),
        .init(agent: .codex, path: ".codex/hooks.json", format: .groupedJSON,
              events: [("UserPromptSubmit", .working), ("PermissionRequest", .needsYou), ("Stop", .done)], complete: true),
        .init(agent: .gemini, path: ".gemini/settings.json", format: .groupedJSON,
              events: [("BeforeAgent", .working), ("Notification", .needsYou), ("AfterAgent", .done)], complete: true),
        .init(agent: .qwen, path: ".qwen/settings.json", format: .groupedJSON,
              events: [("UserPromptSubmit", .working), ("Notification", .needsYou), ("Stop", .done)], complete: true),
        .init(agent: .cursor, path: ".cursor/hooks.json", format: .flatJSON,
              events: [("beforeSubmitPrompt", .working), ("stop", .done)], complete: false),
        .init(agent: .opencode, path: ".config/opencode/plugins/wireline-hooks.js", format: .plugin(opencodePlugin),
              events: [("busy", .working), ("replied", .working), ("permission", .needsYou), ("idle", .done)], complete: true),
        .init(agent: .amp, path: ".config/amp/plugins/wireline-hooks.ts", format: .plugin(ampPlugin),
              events: [("start", .working), ("end", .done)], complete: false),
        .init(agent: .aider, path: ".aider.conf.yml", format: .aiderYAML,
              events: [("waiting", .done)], complete: false),
    ]

    public static func target(for agent: CodingAgent) -> AgentHookTarget? {
        all.first { $0.agent == agent }
    }

    /// The wire name of one of this agent's events.
    func wireEvent(_ event: String) -> String {
        agent == .claude ? event : "\(agent.rawValue):\(event)"
    }

    /// The hook command, reading the hook's JSON from stdin unless `stdin` is
    /// false (Aider's notifications command shares the terminal).
    public func command(for event: String) -> String {
        if agent == .claude { return AgentHooks.command(for: event) }
        let s = AgentHooks.sessionEnv, m = AgentHooks.marker
        if case .aiderYAML = format {
            return "[ -n \"$\(s)\" ] && [ -S \"$\(m)\" ] && echo \"$\(s) \(wireEvent(event))\" "
                + "| nc -U -w 1 \"$\(m)\" >/dev/null 2>&1; true"
        }
        return "[ -n \"$\(s)\" ] && [ -S \"$\(m)\" ] && "
            + "{ printf '%s \(wireEvent(event)) ' \"$\(s)\"; tr -d '\\n'; echo; } "
            + "| nc -U -w 1 \"$\(m)\" >/dev/null 2>&1; true"
    }

    // MARK: - Text

    /// `old` with our hooks added. Nil when they're all there already.
    public func installed(into old: Data?) throws -> Data? {
        switch format {
        case .groupedJSON, .flatJSON:
            var obj = try Self.jsonObject(old)
            guard mergeJSON(&obj) else { return nil }
            return try Self.jsonData(obj)
        case .plugin(let source):
            if let old, String(decoding: old, as: UTF8.self) == source { return nil }
            if let old, !String(decoding: old, as: UTF8.self).contains(AgentHooks.marker) {
                throw Failure.conflict(path)
            }
            return Data(source.utf8)
        case .aiderYAML:
            return try AiderConfig.installed(into: old, command: command(for: "waiting"))
        }
    }

    /// `old` without our hooks; nil when there were none. For a plugin, empty
    /// data means delete the file.
    public func uninstalled(from old: Data?) throws -> Data? {
        guard let old else { return nil }
        switch format {
        case .groupedJSON, .flatJSON:
            var obj = try Self.jsonObject(old)
            guard removeJSON(&obj) else { return nil }
            return try Self.jsonData(obj)
        case .plugin:
            return String(decoding: old, as: UTF8.self).contains(AgentHooks.marker) ? Data() : nil
        case .aiderYAML:
            return AiderConfig.uninstalled(from: old)
        }
    }

    public func isInstalled(_ data: Data?) -> Bool {
        guard let data else { return false }
        do { return try installed(into: data) == nil } catch { return false }
    }

    // MARK: - Files

    public func url(home: URL) -> URL { home.appendingPathComponent(path) }

    public func isInstalled(home: URL) -> Bool {
        isInstalled(try? Data(contentsOf: url(home: home)))
    }

    /// Add our hooks, keeping everything else; the old file is backed up next
    /// to it as `.wireline-backup`.
    public func install(home: URL) throws {
        let url = url(home: home)
        let old = try? Data(contentsOf: url)
        guard let new = try installed(into: old) else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write(new, to: url, backingUp: old)
    }

    /// Remove only what Wireline added.
    public func uninstall(home: URL) throws {
        let url = url(home: home)
        let old = try? Data(contentsOf: url)
        guard let new = try uninstalled(from: old) else { return }
        if case .plugin = format, new.isEmpty {
            try FileManager.default.removeItem(at: url)
            return
        }
        try write(new, to: url, backingUp: old)
    }

    private func write(_ data: Data, to url: URL, backingUp old: Data?) throws {
        if let old, !old.isEmpty {
            try old.write(to: url.appendingPathExtension("wireline-backup"), options: .atomic)
        }
        try data.write(to: url, options: .atomic)
    }

    // MARK: - JSON

    private static func jsonObject(_ data: Data?) throws -> [String: Any] {
        guard let data, !data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x09 || $0 == 0x0D }) else { return [:] }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.unreadable }
        return obj
    }

    private static func jsonData(_ obj: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private static func isOurs(_ entry: Any) -> Bool {
        ((entry as? [String: Any])?["command"] as? String)?.contains(AgentHooks.marker) == true
    }

    private func entryIsOurs(_ entry: Any) -> Bool {
        if case .flatJSON = format { return Self.isOurs(entry) }
        return ((entry as? [String: Any])?["hooks"] as? [Any])?.contains(where: Self.isOurs) == true
    }

    private func mergeJSON(_ obj: inout [String: Any]) -> Bool {
        var hooks = obj["hooks"] as? [String: Any] ?? [:]
        var changed = false
        for (name, _) in events {
            var list = hooks[name] as? [Any] ?? []
            if list.contains(where: entryIsOurs) { continue }
            let cmd = command(for: name)
            if case .flatJSON = format {
                list.append(["command": cmd])
            } else {
                list.append(["hooks": [["type": "command", "command": cmd]]] as [String: Any])
            }
            hooks[name] = list
            changed = true
        }
        guard changed else { return false }
        if case .flatJSON = format, obj["version"] == nil { obj["version"] = 1 }
        obj["hooks"] = hooks
        return true
    }

    private func removeJSON(_ obj: inout [String: Any]) -> Bool {
        guard var hooks = obj["hooks"] as? [String: Any] else { return false }
        var changed = false
        for (name, value) in hooks {
            guard var list = value as? [Any] else { continue }
            if case .flatJSON = format {
                let before = list.count
                list.removeAll(where: Self.isOurs)
                guard list.count != before else { continue }
            } else {
                var touched = false
                list = list.compactMap { group in
                    guard var g = group as? [String: Any], let inner = g["hooks"] as? [Any],
                          inner.contains(where: Self.isOurs) else { return group }
                    touched = true
                    let rest = inner.filter { !Self.isOurs($0) }
                    if rest.isEmpty { return nil }
                    g["hooks"] = rest
                    return g
                }
                guard touched else { continue }
            }
            hooks[name] = list.isEmpty ? nil : list
            changed = true
        }
        guard changed else { return false }
        obj["hooks"] = hooks
        return true
    }
}

// MARK: - Wire

extension AgentHooks {
    /// `<agent>:<event>` (or a bare Claude Code event) and the hook's JSON.
    static func decode(event token: String, json: [String: Any]?) -> (CodingAgent, Event)? {
        let message = (json?["message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        guard let colon = token.firstIndex(of: ":") else {
            return Event(name: token, fields: { json?[$0] as? String }).map { (.claude, $0) }
        }
        guard let agent = CodingAgent(rawValue: String(token[..<colon])),
              let target = AgentHookTarget.target(for: agent),
              let kind = target.kind(of: String(token[token.index(after: colon)...])) else { return nil }
        switch kind {
        case .working: return (agent, .promptSubmitted)
        case .needsYou: return (agent, .notification(message))
        case .done: return (agent, .stop)
        }
    }

    /// The agent's own id for its session (Codex's thread id, …), for resuming.
    static func agentSessionID(_ json: [String: Any]?) -> String? {
        for key in ["session_id", "thread-id", "thread_id", "conversation_id", "sessionID"] {
            if let v = json?[key] as? String, !v.isEmpty { return v }
        }
        return nil
    }
}

// MARK: - Aider

/// Line-level edits of ~/.aider.conf.yml: our keys sit between two marker
/// comments, so removing them never touches the user's lines.
enum AiderConfig {
    static let begin = "# >>> wireline hooks (\(AgentHooks.marker)) >>>"
    static let end = "# <<< wireline hooks <<<"

    static func installed(into old: Data?, command: String) throws -> Data? {
        let text = old.map { String(decoding: $0, as: UTF8.self) } ?? ""
        let block = self.block(command: command, in: text)
        if text.contains(block) { return nil }
        var lines = stripped(text)
        for line in lines {
            let key = line.split(separator: ":", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) }
            if key == "notifications-command" || key == "notifications_command" {
                throw AgentHookTarget.Failure.conflict("notifications-command")
            }
            if key == "notifications" || key == "notifications_bell",
               line.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces).lowercased() == "false" {
                throw AgentHookTarget.Failure.conflict("notifications")
            }
        }
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        lines.append(block)
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    static func uninstalled(from old: Data) -> Data? {
        let text = String(decoding: old, as: UTF8.self)
        guard text.contains(begin) else { return nil }
        var lines = stripped(text)
        while lines.last?.isEmpty == true { lines.removeLast() }
        return Data((lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n").utf8)
    }

    private static func block(command: String, in text: String) -> String {
        let userEnables = stripped(text).contains {
            $0.replacingOccurrences(of: " ", with: "").lowercased() == "notifications:true"
        }
        var b = [begin]
        if !userEnables { b.append("notifications: true") }
        b.append("notifications-command: '\(command.replacingOccurrences(of: "'", with: "''"))'")
        b.append(end)
        return b.joined(separator: "\n")
    }

    /// The text's lines with our block taken out.
    private static func stripped(_ text: String) -> [String] {
        var out: [String] = [], inBlock = false
        for line in text.components(separatedBy: "\n") {
            if line == begin { inBlock = true; continue }
            if inBlock { if line == end { inBlock = false }; continue }
            out.append(line)
        }
        if out.last == "" { out.removeLast() }
        return out
    }
}

// MARK: - Plugins

private let pluginSend = """
import { createConnection } from "node:net"

const send = (event, payload) => {
  const sid = process.env.WIRELINE_SESSION_ID, sock = process.env.WIRELINE_HOOK_SOCK
  if (!sid || !sock) return
  try {
    const c = createConnection(sock, () => c.end(`${sid} ${event} ${JSON.stringify(payload ?? {})}\\n`))
    c.on("error", () => {})
  } catch {}
}
"""

let opencodePlugin = """
// Written by Wireline (WIRELINE_HOOK_SOCK): reports opencode's state to the
// Wireline tab it runs in. Remove it from Wireline's settings.
\(pluginSend)

export const WirelineHooks = async () => ({
  event: async ({ event }) => {
    const p = event.properties ?? {}
    const session_id = p.sessionID ?? p.info?.sessionID
    switch (event.type) {
      case "session.status":
        if (p.status?.type === "busy") send("opencode:busy", { session_id })
        else if (p.status?.type === "idle") send("opencode:idle", { session_id })
        break
      case "session.idle": send("opencode:idle", { session_id }); break
      case "permission.asked":
      case "permission.updated": send("opencode:permission", { session_id, message: p.title }); break
      case "permission.replied": send("opencode:replied", { session_id }); break
    }
  },
})

"""

let ampPlugin = """
// Written by Wireline (WIRELINE_HOOK_SOCK): reports Amp's state to the
// Wireline tab it runs in. Remove it from Wireline's settings.
\(pluginSend)

export default function (amp) {
  amp.on("agent.start", () => { send("amp:start") })
  amp.on("agent.end", () => { send("amp:end") })
}

"""
