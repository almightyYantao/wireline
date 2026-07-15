import Foundation
import Observation

/// Per-host "memory": durable facts the AI has learned about a machine (uses
/// systemd, nginx config path, quirks…). Injected into the AI's context for that
/// host so answers get more accurate over time. Persisted to Application Support.
@Observable
@MainActor
final class HostMemoryStore {
    static let shared = HostMemoryStore()

    private var facts: [String: [String]] = [:]
    private let fileURL: URL
    private let maxPerHost = 40

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wireline", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("ai_memory.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) {
            facts = decoded
        }
    }

    func facts(for key: String) -> [String] { facts[key] ?? [] }

    func add(_ note: String, for key: String) {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var list = facts[key] ?? []
        guard !list.contains(trimmed) else { return }   // dedupe
        list.append(trimmed)
        facts[key] = Array(list.suffix(maxPerHost))
        persist()
    }

    func remove(_ note: String, for key: String) {
        facts[key]?.removeAll { $0 == note }
        if facts[key]?.isEmpty == true { facts[key] = nil }
        persist()
    }

    func clear(_ key: String) {
        facts[key] = nil
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(facts) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
