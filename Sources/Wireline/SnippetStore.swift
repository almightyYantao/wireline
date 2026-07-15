import Foundation
import Observation

/// A reusable command snippet.
struct Snippet: Identifiable, Codable, Sendable, Equatable {
    var id = UUID()
    var name: String
    var command: String

    /// Placeholder names found in the command, written as `{{name}}`, unique and
    /// in first-appearance order. Presented as fill-in fields before running.
    var placeholders: [String] {
        guard let re = try? NSRegularExpression(pattern: "\\{\\{\\s*([A-Za-z0-9_]+)\\s*\\}\\}") else { return [] }
        let ns = command as NSString
        var seen = Set<String>()
        var result: [String] = []
        for m in re.matches(in: command, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: m.range(at: 1))
            if seen.insert(name).inserted { result.append(name) }
        }
        return result
    }

    /// The command with every `{{name}}` replaced by the supplied value.
    func filled(with values: [String: String]) -> String {
        guard let re = try? NSRegularExpression(pattern: "\\{\\{\\s*([A-Za-z0-9_]+)\\s*\\}\\}") else { return command }
        let ns = command as NSString
        var out = command
        // Replace from the back so ranges stay valid.
        for m in re.matches(in: command, range: NSRange(location: 0, length: ns.length)).reversed() {
            let name = ns.substring(with: m.range(at: 1))
            let value = values[name] ?? ""
            out = (out as NSString).replacingCharacters(in: m.range, with: value)
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
        Snippet(name: "查看日志 / Tail log", command: "tail -f {{path}}"),
        Snippet(name: "查找进程 / Find process", command: "ps aux | grep {{keyword}}")
    ]
}
