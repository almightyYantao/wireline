import Foundation

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
    func stream(system: String, messages: [AIMessage], model: String? = nil) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard config.isConfigured else { throw AIClientError.notConfigured }
                    let base = config.activeBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: " /"))
                    guard let url = URL(string: base + "/chat/completions") else { throw AIClientError.badURL }

                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.timeoutInterval = 120
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    let key = config.apiKey
                    if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }

                    var wire: [[String: String]] = [["role": "system", "content": system]]
                    wire += messages.map { ["role": $0.role.rawValue, "content": $0.content] }
                    let body: [String: Any] = [
                        "model": model ?? config.activeModel,
                        "messages": wire,
                        "stream": true,
                        "temperature": 0.2
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
                        continuation.yield(content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
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

/// Best-effort redaction of obvious secrets before sending context to the model.
enum AIRedactor {
    static func redact(_ text: String) -> String {
        var out = text
        let patterns = [
            // key=secret / password: secret / token "..."
            #"(?i)(password|passwd|passphrase|secret|token|api[_-]?key|access[_-]?key)\s*[:=]\s*\S+"#,
            // long base64/hex blobs that look like credentials
            #"\b[A-Fa-f0-9]{32,}\b"#,
            #"\b[A-Za-z0-9+/]{40,}={0,2}\b"#
        ]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p) else { continue }
            let range = NSRange(out.startIndex..., in: out)
            out = re.stringByReplacingMatches(in: out, range: range, withTemplate: "«redacted»")
        }
        return out
    }
}
