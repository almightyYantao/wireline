import Foundation
import Observation

/// A reusable command snippet.
struct Snippet: Identifiable, Codable, Sendable, Equatable {
    var id = UUID()
    var name: String
    var command: String

    /// Placeholders are written `«name»`. Guillemets rather than `{{name}}`
    /// because `{{…}}` is Go-template syntax, which turns up in exactly the kind
    /// of command that gets saved here (`docker ps --format '{{.Names}}'`,
    /// `kubectl -o go-template`, Helm charts) — the braces there are the
    /// command's own syntax, not a blank to fill in. `{{name}}` is still
    /// recognised so snippets saved before the switch keep working, and it also
    /// accepts a non-ASCII name (`«服务名»`), which the old pattern silently missed.
    private static let placeholderRE = try? NSRegularExpression(
        pattern: #"«\s*([^«»\n]{1,60}?)\s*»|\{\{\s*([\p{L}\p{N}_]+)\s*\}\}"#)

    /// Every placeholder occurrence, in source order, with its name.
    private var placeholderMatches: [(range: NSRange, name: String)] {
        guard let re = Self.placeholderRE else { return [] }
        let ns = command as NSString
        return re.matches(in: command, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            for group in 1...2 where m.range(at: group).location != NSNotFound {
                return (m.range, ns.substring(with: m.range(at: group)))
            }
            return nil
        }
    }

    /// Placeholder names found in the command, unique and in first-appearance
    /// order. Presented as fill-in fields before running.
    var placeholders: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for match in placeholderMatches where seen.insert(match.name).inserted {
            result.append(match.name)
        }
        return result
    }

    /// The command with every placeholder replaced by the supplied value.
    func filled(with values: [String: String]) -> String {
        var out = command
        // Replace from the back so the earlier ranges stay valid.
        for match in placeholderMatches.reversed() {
            out = (out as NSString).replacingCharacters(in: match.range, with: values[match.name] ?? "")
        }
        return out
    }
}

/// Stores command snippets, persisted to Application Support as JSON.
@Observable
@MainActor
final class SnippetStore {
    private(set) var snippets: [Snippet] = []
    private let fileURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wireline", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.fileURL = base.appendingPathComponent("snippets.json")
        load()
    }

    private func load() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([Snippet].self, from: data) {
            snippets = decoded
        } else {
            snippets = Self.defaults
            save()
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(snippets) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func add(_ snippet: Snippet) { snippets.append(snippet); save() }

    func update(_ snippet: Snippet) {
        if let i = snippets.firstIndex(where: { $0.id == snippet.id }) { snippets[i] = snippet; save() }
    }

    func remove(_ snippet: Snippet) { snippets.removeAll { $0.id == snippet.id }; save() }

    static let defaults: [Snippet] = [
        Snippet(name: "磁盘占用 / Disk usage", command: "df -h"),
        Snippet(name: "内存 / Memory", command: "free -h"),
        Snippet(name: "系统负载 / Load", command: "uptime"),
        Snippet(name: "监听端口 / Listening ports", command: "ss -tlnp"),
        Snippet(name: "进程占用 / Top processes", command: "ps aux --sort=-%cpu | head"),
        Snippet(name: "查看日志 / Tail log", command: "tail -f «path»"),
        Snippet(name: "查找进程 / Find process", command: "ps aux | grep «keyword»")
    ]
}
