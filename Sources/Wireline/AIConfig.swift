import Foundation
import Observation
import WirelineCore

/// Which backend the AI assistant talks to. Both speak the OpenAI-compatible
/// `/chat/completions` API, so one client covers relay stations, direct OpenAI,
/// and local Ollama (which exposes an OpenAI-compatible endpoint).
enum AIProvider: String, CaseIterable, Codable, Sendable {
    case relay      // third-party relay / OpenAI-compatible endpoint (needs a key)
    case ollama     // local Ollama (http://localhost:11434/v1, no key)

    var title: String {
        switch self {
        case .relay:  return "中转站 / OpenAI 兼容"
        case .ollama: return "Ollama (本地)"
        }
    }
}

/// User-configurable AI settings, persisted to `UserDefaults`; the API key lives
/// in the Keychain (never plaintext on disk).
@Observable
final class AIConfig: @unchecked Sendable {
    static let shared = AIConfig()

    var enabled: Bool { didSet { d.set(enabled, forKey: "ai.enabled") } }
    var provider: AIProvider { didSet { d.set(provider.rawValue, forKey: "ai.provider") } }
    var relayBaseURL: String { didSet { d.set(relayBaseURL, forKey: "ai.relay.base") } }
    var relayModel: String { didSet { d.set(relayModel, forKey: "ai.relay.model") } }
    var relayModelFast: String { didSet { d.set(relayModelFast, forKey: "ai.relay.modelFast") } }
    var ollamaBaseURL: String { didSet { d.set(ollamaBaseURL, forKey: "ai.ollama.base") } }
    var ollamaModel: String { didSet { d.set(ollamaModel, forKey: "ai.ollama.model") } }
    var ollamaModelFast: String { didSet { d.set(ollamaModelFast, forKey: "ai.ollama.modelFast") } }
    /// Optional price per 1K tokens (in your currency); 0 hides cost.
    var pricePer1k: Double { didSet { d.set(pricePer1k, forKey: "ai.pricePer1k") } }
    /// Redact obvious secrets (passwords, tokens) from context before sending.
    var redact: Bool { didSet { d.set(redact, forKey: "ai.redact") } }
    /// Agent mode: run AI commands in the visible terminal (true) so the user
    /// sees exactly what runs, vs. an out-of-band channel (false).
    var agentInTerminal: Bool { didSet { d.set(agentInTerminal, forKey: "ai.agentInTerminal") } }
    /// Whether the AI panel's "Agent" (auto-execute) mode is on. Persisted here
    /// (rather than panel-local state) so it survives view rebuilds.
    var agentMode: Bool { didSet { d.set(agentMode, forKey: "ai.agentMode") } }
    /// Font size for the AI panel's messages.
    var fontSize: Double { didSet { d.set(fontSize, forKey: "ai.fontSize") } }
    /// Read-only sandbox: in Agent mode, only allow non-mutating commands.
    var agentReadOnly: Bool { didSet { d.set(agentReadOnly, forKey: "ai.agentReadOnly") } }
    /// Max messages kept per conversation (persistence + memory bound).
    var historyLimit: Int { didSet { d.set(historyLimit, forKey: "ai.historyLimit") } }

    private let d = UserDefaults.standard
    private let keychain = KeychainService()
    private let keyAccount = "__wireline_ai_key__"

    /// API key for the relay provider, stored in the Keychain.
    var apiKey: String {
        get { ((try? keychain.password(for: keyAccount)) ?? nil) ?? "" }
        set {
            if newValue.isEmpty { try? keychain.deletePassword(for: keyAccount) }
            else { try? keychain.setPassword(newValue, for: keyAccount) }
        }
    }

    init() {
        enabled = d.bool(forKey: "ai.enabled")
        provider = AIProvider(rawValue: d.string(forKey: "ai.provider") ?? "") ?? .relay
        relayBaseURL = d.string(forKey: "ai.relay.base") ?? ""
        relayModel = d.string(forKey: "ai.relay.model") ?? "claude-sonnet-4-20250514"
        relayModelFast = d.string(forKey: "ai.relay.modelFast") ?? ""
        ollamaBaseURL = d.string(forKey: "ai.ollama.base") ?? "http://localhost:11434/v1"
        ollamaModel = d.string(forKey: "ai.ollama.model") ?? "qwen2.5"
        ollamaModelFast = d.string(forKey: "ai.ollama.modelFast") ?? ""
        pricePer1k = (d.object(forKey: "ai.pricePer1k") as? Double) ?? 0
        redact = (d.object(forKey: "ai.redact") as? Bool) ?? true
        agentInTerminal = (d.object(forKey: "ai.agentInTerminal") as? Bool) ?? true
        agentMode = d.bool(forKey: "ai.agentMode")
        fontSize = (d.object(forKey: "ai.fontSize") as? Double) ?? 13
        agentReadOnly = d.bool(forKey: "ai.agentReadOnly")
        historyLimit = (d.object(forKey: "ai.historyLimit") as? Int) ?? 60
    }

    var activeBaseURL: String { provider == .relay ? relayBaseURL : ollamaBaseURL }
    var activeModel: String { provider == .relay ? relayModel : ollamaModel }
    var activeModelFast: String { provider == .relay ? relayModelFast : ollamaModelFast }
    var hasFastModel: Bool { !activeModelFast.trimmingCharacters(in: .whitespaces).isEmpty }

    var isConfigured: Bool {
        guard !activeBaseURL.isEmpty else { return false }
        return provider == .ollama || !apiKey.isEmpty
    }
}
