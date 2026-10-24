import Foundation
import WirelineCore

struct AIMessage: Codable, Sendable, Identifiable, Equatable {
    enum Role: String, Codable, Sendable { case user, assistant, system }
    var id = UUID()
    var role: Role
    var content: String
}

enum AIClientError: LocalizedError {
    case notConfigured
    case badURL
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "AI 未配置：请在 设置 → AI 里填写服务地址" + " / API Key。"
        case .badURL:        return "AI 服务地址无效。"
        case .http(let code, let body):
            return "AI 请求失败 (\(code))：\(body.prefix(300))"
        }
    }
}

/// A minimal OpenAI-compatible streaming chat client. Works with relay stations,
/// direct OpenAI, and Ollama's OpenAI-compatible endpoint.
struct AIClient: Sendable {
    let config: AIConfig

    /// Stream assistant token deltas for the given system prompt + conversation.
    /// `model` overrides the configured default (for per-task model switching).
    ///
    /// Privacy is enforced here, for every caller: what goes out is masked and
    /// the reply comes back restored, so callers deal in real values only. A
    /// conversation passes its own `masker` so placeholders stay stable across
    /// turns; otherwise each request gets a fresh one.
    func stream(system: String, messages: [AIMessage], model: String? = nil,
                masker: PrivacyMasker? = nil) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard config.isConfigured else { throw AIClientError.notConfigured }
                    let masker = masker ?? PrivacyContext.masker(config.privacyLevel)
                    if let masker { PrivacyContext.refresh(masker) }
                    let restorer = masker?.streamRestorer()
                    let base = config.activeBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: " /"))
                    guard let url = URL(string: base + "/chat/completions") else { throw AIClientError.badURL }

                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.timeoutInterval = 120
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    let key = config.apiKey
                    if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }

                    let out = { (text: String) in masker?.mask(text) ?? text }
                    let note = masker == nil ? "" : "\n\n" + Self.placeholderNote
                    var wire: [[String: String]] = [["role": "system", "content": out(system) + note]]
                    wire += messages.map { ["role": $0.role.rawValue, "content": out($0.content)] }
                    // Only the required fields. Optional sampling parameters
                    // (temperature, top_p …) are rejected by some models — e.g.
                    // recent Claude models refuse a non-default temperature — so
                    // let every endpoint use its own defaults.
                    let body: [String: Any] = [
                        "model": model ?? config.activeModel,
                        "messages": wire,
                        "stream": true
                    ]
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        var errText = ""
                        for try await line in bytes.lines { errText += line; if errText.count > 800 { break } }
                        throw AIClientError.http(http.statusCode, errText)
                    }

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let choices = obj["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any],
                              let content = delta["content"] as? String else { continue }
                        let shown = restorer?.feed(content) ?? content
                        if !shown.isEmpty { continuation.yield(shown) }
                    }
                    if let rest = restorer?.finish(), !rest.isEmpty { continuation.yield(rest) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Tells the model what the placeholders are, so it passes them through.
    static let placeholderNote = """
    【脱敏说明】上下文中形如 [WL…_SECRET_1]、[WL…_IP_2]、[WL…_HOST_3]（… 是四位随机字符）的是脱敏占位符，各代表一个真实的密钥 / IP / 主机名。\
    需要用到时（命令、文件内容、参数里）原样照抄占位符即可，本地执行前会自动还原成真实值；不要猜测、拆分或改写它，也不要因为看不到真实值而拒绝执行。
    """
}

/// Rough local token estimate (no API dependency): ~4 ASCII chars/token, and
/// ~1.4 chars/token for CJK. Good enough for a usage indicator.
enum AITokenEstimator {
    static func estimate(_ text: String) -> Int {
        var t = 0.0
        for scalar in text.unicodeScalars {
            t += scalar.isASCII ? 0.25 : 0.7
        }
        return Int(t.rounded())
    }
}
