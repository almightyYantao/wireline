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

/// Flags commands that could cause data loss / outage, so agent mode can force a
/// confirmation before running them.
enum AICommandSafety {
    /// The first unfilled `{{placeholder}}` in a command, if any (e.g. `{{project_name}}`).
    /// Agent mode must never send a command that still contains one to the shell.
    static func unfilledPlaceholder(_ command: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: #"\{\{\s*[A-Za-z0-9_]+\s*\}\}"#) else { return nil }
        let ns = command as NSString
        guard let m = re.firstMatch(in: command, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range)
    }

    static func isDangerous(_ command: String) -> Bool {
        let c = command.lowercased()
        let patterns = [
            #"\brm\s+(-\w*\s+)*-?\w*[rf]"#,   // rm -rf / rm -fr …
            #"\bdd\s+.*of=/dev/"#,
            #"\bmkfs\b"#,
            #"\b(shutdown|reboot|halt|poweroff)\b"#,
            #">\s*/dev/(sd|nvme|disk)"#,
            #"\bchmod\s+-r\s+777\b"#,
            #"\bchown\s+-r\b.*\s/\s*$"#,
            #"\bdrop\s+(database|table)\b"#,
            #"\btruncate\b.*\s-s\s*0"#,
            #":\(\)\s*\{.*\};:"#,             // fork bomb
            #"\bgit\s+reset\s+--hard\b"#,
            #"\bkill(all)?\s+-9\b"#,
            #"/etc/(passwd|shadow|fstab)"#,
            #"\brm\s+-rf?\s+/(\s|$)"#
        ]
        return patterns.contains { c.range(of: $0, options: .regularExpression) != nil }
    }

    /// Commands considered safe in read-only sandbox mode — informational only,
    /// no mutation. Every segment of a pipeline / chain must be on the allowlist,
    /// and no output redirection or elevation is allowed.
    private static let readOnlyCommands: Set<String> = [
        "ls", "ll", "cat", "bat", "less", "more", "head", "tail", "grep", "egrep", "fgrep",
        "rg", "ag", "find", "fd", "locate", "which", "whereis", "type", "file", "stat",
        "pwd", "echo", "printf", "date", "cal", "whoami", "id", "groups", "uname", "hostname",
        "uptime", "w", "who", "last", "env", "printenv", "ps", "top", "htop", "pgrep",
        "df", "du", "free", "vmstat", "iostat", "mpstat", "lsblk", "lscpu", "lsusb", "lspci",
        "mount", "ip", "ifconfig", "netstat", "ss", "ping", "traceroute", "dig", "nslookup",
        "host", "curl", "wget", "journalctl", "dmesg", "lsof", "wc", "sort", "uniq", "cut",
        "tr", "awk", "sed", "column", "jq", "yq", "tree", "readlink", "realpath", "basename",
        "dirname", "diff", "cmp", "md5sum", "sha256sum", "docker", "kubectl", "systemctl",
        "service", "git", "helm", "true", "false", "test", "sleep", "tee"
    ]

    /// Subcommands that keep otherwise-powerful tools read-only.
    private static let readOnlySubcommands: [String: Set<String>] = [
        "docker": ["ps", "images", "image", "inspect", "logs", "stats", "top", "version", "info", "port", "diff"],
        "kubectl": ["get", "describe", "logs", "top", "explain", "version", "config", "api-resources"],
        "systemctl": ["status", "list-units", "list-unit-files", "is-active", "is-enabled", "show", "cat"],
        "service": ["status"],
        "git": ["status", "log", "diff", "show", "branch", "remote", "config", "blame", "ls-files", "rev-parse"],
        "helm": ["list", "status", "get", "history", "version", "show"]
    ]

    static func isReadOnly(_ command: String) -> Bool {
        // No output redirection or elevation.
        if command.range(of: #"(>>?|<|\btee\b|\bsudo\b|\bsu\b)"#, options: .regularExpression) != nil {
            // `>` redirect writes; sudo elevates — disallow in sandbox.
            if command.contains(">") || command.range(of: #"\bsudo\b|\bsu\b"#, options: .regularExpression) != nil {
                return false
            }
        }
        // Split into pipeline / chain segments; every segment must be allowlisted.
        let segments = command.split(whereSeparator: { "|;&\n".contains($0) })
        guard !segments.isEmpty else { return false }
        for seg in segments {
            let tokens = seg.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let cmd = tokens.first(where: { !$0.contains("=") })?.lowercased() else { return false }
            let base = (cmd as NSString).lastPathComponent
            guard readOnlyCommands.contains(base) else { return false }
            if let subs = readOnlySubcommands[base] {
                let sub = tokens.dropFirst().first { !$0.hasPrefix("-") }?.lowercased()
                guard let sub, subs.contains(sub) else { return false }
            }
            // `sed -i` mutates in place.
            if base == "sed", tokens.contains(where: { $0.hasPrefix("-i") }) { return false }
        }
        return true
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
