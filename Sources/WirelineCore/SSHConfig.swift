import Foundation

/// Parses and serializes an OpenSSH client config (`~/.ssh/config`), treating it
/// as the single source of truth for Wireline.
///
/// The parser preserves everything it does not manage:
///   * a *preamble* — comments / global options before the first `Host` line
///   * *raw blocks* — `Host` lines that use patterns (`*`, `?`, `!`) or list
///     multiple aliases; these are kept verbatim and never rewritten
///
/// Concrete single-alias `Host` blocks become `Host` values. Wireline metadata
/// is stored as a single comment line inside the block, invisible to stock ssh.
public enum SSHConfig {

    /// A structured view of a parsed config file.
    public struct Document: Sendable {
        /// Ordered list of top-level items, preserving original file order.
        public var items: [Item]

        public init(items: [Item]) { self.items = items }

        /// All managed hosts, in file order.
        public var hosts: [Host] {
            items.compactMap { if case .host(let h) = $0 { return h } else { return nil } }
        }
    }

    public enum Item: Sendable {
        /// A concrete, Wireline-managed host.
        case host(Host)
        /// Verbatim text we preserve but don't model (preamble, `Host *`, comments).
        case raw(String)
    }

    static let metadataPrefix = "# wireline:"

    // MARK: - Parsing

    public static func parse(_ text: String) -> Document {
        var items: [Item] = []
        var preamble: [String] = []
        // Lines of the current host/raw block, and whether it's managed.
        var currentLines: [String] = []
        var currentAlias: String?
        var currentIsRaw = false

        func flush() {
            guard !currentLines.isEmpty || currentAlias != nil else { return }
            if let alias = currentAlias, !currentIsRaw {
                items.append(.host(parseHostBlock(alias: alias, lines: currentLines)))
            } else {
                items.append(.raw(currentLines.joined(separator: "\n")))
            }
            currentLines = []
            currentAlias = nil
            currentIsRaw = false
        }

        for rawLine in text.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            let lower = trimmed.lowercased()

            if lower.hasPrefix("host ") || lower == "host" {
                // Starting a new block. Flush the previous one first.
                if currentAlias != nil || !currentLines.isEmpty {
                    if !preamble.isEmpty {
                        items.append(.raw(preamble.joined(separator: "\n")))
                        preamble = []
                    }
                    flush()
                } else if !preamble.isEmpty {
                    items.append(.raw(preamble.joined(separator: "\n")))
                    preamble = []
                }
                let patterns = trimmed.dropFirst(4).trimmingCharacters(in: .whitespaces)
                let tokens = patterns.split(whereSeparator: { $0 == " " || $0 == "\t" })
                let isPattern = tokens.count != 1
                    || patterns.contains(where: { "*?!".contains($0) })
                currentIsRaw = isPattern
                currentAlias = isPattern ? nil : String(tokens.first ?? "")
                currentLines = [rawLine]
            } else if lower.hasPrefix("match ") {
                // Match blocks are always preserved raw.
                if currentAlias != nil || !currentLines.isEmpty { flush() }
                else if !preamble.isEmpty {
                    items.append(.raw(preamble.joined(separator: "\n")))
                    preamble = []
                }
                currentIsRaw = true
                currentAlias = nil
                currentLines = [rawLine]
            } else if currentAlias != nil || currentIsRaw {
                currentLines.append(rawLine)
            } else {
                preamble.append(rawLine)
            }
        }
        if !preamble.isEmpty { items.append(.raw(preamble.joined(separator: "\n"))) }
        flush()
        return Document(items: items)
    }

    private static func parseHostBlock(alias: String, lines: [String]) -> Host {
        var host = Host(alias: alias)
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("#") {
                if trimmed.hasPrefix(metadataPrefix) {
                    applyMetadata(String(trimmed.dropFirst(metadataPrefix.count)), to: &host)
                }
                continue
            }
            let (keyword, value) = splitKeyword(trimmed)
            guard let keyword else { continue }
            switch keyword.lowercased() {
            case "hostname": host.hostname = value
            case "user": host.user = value
            case "port": host.port = Int(value)
            case "identityfile": host.identityFile = value
            case "proxyjump": host.proxyJump = value
            default: host.extraOptions.append((keyword, value))
            }
        }
        return host
    }

    /// Split `Keyword value` or `Keyword=value` into components.
    private static func splitKeyword(_ line: String) -> (String?, String) {
        if let eq = line.firstIndex(of: "="),
           !line[..<eq].contains(" "), !line[..<eq].contains("\t") {
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            let val = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            return (key.isEmpty ? nil : key, unquote(val))
        }
        guard let space = line.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
            return (line.isEmpty ? nil : line, "")
        }
        let key = String(line[..<space])
        let val = String(line[space...]).trimmingCharacters(in: .whitespaces)
        return (key, unquote(val))
    }

    private static func unquote(_ s: String) -> String {
        if s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") {
            return String(s.dropFirst().dropLast())
        }
        return s
    }

    // MARK: - Metadata encoding

    private static func applyMetadata(_ raw: String, to host: inout Host) {
        for pair in splitMetadata(raw) {
            guard let eq = pair.firstIndex(of: "=") else { continue }
            let key = String(pair[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = metaUnescape(String(pair[pair.index(after: eq)...]))
            switch key {
            case "group": host.group = value.isEmpty ? nil : value
            case "desc": host.descriptionText = value.isEmpty ? nil : value
            case "auth": host.authMethod = AuthMethod(rawValue: value) ?? .unknown
            case "autosudo": host.autoSudo = (value == "true" || value == "1")
            case "args": host.launchArgs = value.isEmpty ? nil : value
            default: break
            }
        }
    }

    /// Split on unescaped `;`.
    private static func splitMetadata(_ raw: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var escaped = false
        for ch in raw {
            if escaped { current.append(ch); escaped = false; continue }
            if ch == "\\" { current.append(ch); escaped = true; continue }
            if ch == ";" { parts.append(current); current = ""; continue }
            current.append(ch)
        }
        parts.append(current)
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func metaEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: ";", with: "\\;")
    }

    private static func metaUnescape(_ s: String) -> String {
        var out = ""
        var escaped = false
        for ch in s {
            if escaped { out.append(ch); escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            out.append(ch)
        }
        return out
    }

    static func metadataLine(for host: Host) -> String? {
        var parts: [String] = []
        if let g = host.group, !g.isEmpty { parts.append("group=\(metaEscape(g))") }
        if let d = host.descriptionText, !d.isEmpty { parts.append("desc=\(metaEscape(d))") }
        if host.authMethod != .unknown { parts.append("auth=\(host.authMethod.rawValue)") }
        if host.autoSudo { parts.append("autosudo=true") }
        if let a = host.launchArgs, !a.isEmpty { parts.append("args=\(metaEscape(a))") }
        guard !parts.isEmpty else { return nil }
        return "\(metadataPrefix) \(parts.joined(separator: "; "))"
    }

    // MARK: - Serialization

    public static func serialize(_ document: Document) -> String {
        var blocks: [String] = []
        for item in document.items {
            switch item {
            case .raw(let text): blocks.append(text)
            case .host(let host): blocks.append(render(host))
            }
        }
        var result = blocks.joined(separator: "\n")
        if !result.hasSuffix("\n") { result += "\n" }
        return result
    }

    static func render(_ host: Host) -> String {
        var lines = ["Host \(host.alias)"]
        if let meta = metadataLine(for: host) { lines.append("    \(meta)") }
        if let v = host.hostname, !v.isEmpty { lines.append("    HostName \(v)") }
        if let v = host.user, !v.isEmpty { lines.append("    User \(v)") }
        if let v = host.port { lines.append("    Port \(v)") }
        if let v = host.identityFile, !v.isEmpty { lines.append("    IdentityFile \(v)") }
        if let v = host.proxyJump, !v.isEmpty { lines.append("    ProxyJump \(v)") }
        for opt in host.extraOptions where !opt.keyword.isEmpty {
            lines.append("    \(opt.keyword) \(opt.value)")
        }
        return lines.joined(separator: "\n")
    }
}
