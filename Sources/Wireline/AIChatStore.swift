import Foundation
import Observation

/// Persists AI conversations per host (and per local shell), so each machine
/// keeps its own history across panel opens / app restarts.
@Observable
@MainActor
final class AIChatStore {
    static let shared = AIChatStore()

    struct Convo: Codable {
        var display: [AIMessage] = []   // what the user sees
        var model: [AIMessage] = []     // what the model is fed
    }

    private var convos: [String: Convo] = [:]
    private let fileURL: URL
    private var maxMessages: Int { max(10, AIConfig.shared.historyLimit) }

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wireline", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("ai_chats.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: Convo].self, from: data) {
            convos = decoded
        }
    }

    func load(_ key: String) -> Convo { convos[key] ?? Convo() }

    func save(_ key: String, display: [AIMessage], model: [AIMessage]) {
        convos[key] = Convo(display: Array(display.suffix(maxMessages)),
                            model: Array(model.suffix(maxMessages)))
        persist()
    }

    func clear(_ key: String) {
        convos[key] = nil
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(convos) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
