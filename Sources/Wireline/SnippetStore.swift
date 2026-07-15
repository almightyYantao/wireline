import Foundation
import Observation

/// A reusable command snippet.
struct Snippet: Identifiable, Codable, Sendable, Equatable {
    var id = UUID()
    var name: String
    var command: String
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
        Snippet(name: "进程占用 / Top processes", command: "ps aux --sort=-%cpu | head")
    ]
}
