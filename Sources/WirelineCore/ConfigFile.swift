import Foundation

/// Parser for Wireline's plain-text config file (Ghostty-style):
///
///     # comment
///     font-size = 14
///     font-family = "JetBrains Mono"
///     keybind = cmd+shift+t=new_local_terminal
///     config-file = ?~/.config/wireline/local     # leading ? = optional
///
/// One `key = value` per line. Later lines win for scalar keys; `keybind` is
/// repeatable. Values may be wrapped in double quotes. An empty value resets the
/// key to its default.
public enum ConfigFile {
    public struct Entry: Equatable, Sendable {
        public let key: String
        public let value: String
        /// 1-based line number in `source`.
        public let line: Int
        public let source: String
    }

    public struct Issue: Equatable, Sendable, CustomStringConvertible {
        public let source: String
        public let line: Int
        public let message: String
        public init(source: String, line: Int, message: String) {
            self.source = source; self.line = line; self.message = message
        }
        public var description: String {
            "\((source as NSString).lastPathComponent):\(line): \(message)"
        }
    }

    /// Parse one file's text. `config-file` includes are returned as ordinary
    /// entries; `load` resolves them.
    public static func parse(_ text: String, source: String = "config") -> (entries: [Entry], issues: [Issue]) {
        var entries: [Entry] = []
        var issues: [Issue] = []
        for (i, raw) in text.components(separatedBy: .newlines).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else {
                issues.append(Issue(source: source, line: i + 1, message: "expected `key = value`"))
                continue
            }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if key.isEmpty {
                issues.append(Issue(source: source, line: i + 1, message: "missing key"))
                continue
            }
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            entries.append(Entry(key: key, value: value, line: i + 1, source: source))
        }
        return (entries, issues)
    }

    /// Read `url` and every file it pulls in via `config-file`, in order.
    /// Missing optional (`?`-prefixed) includes are skipped silently; cycles are
    /// reported once and broken.
    public static func load(_ url: URL) -> (entries: [Entry], issues: [Issue], files: [URL]) {
        var entries: [Entry] = []
        var issues: [Issue] = []
        var files: [URL] = []
        var visiting = Set<String>()

        func visit(_ url: URL, optional: Bool, from: Entry?) {
            let path = url.standardizedFileURL.path
            guard !visiting.contains(path) else {
                if let from { issues.append(Issue(source: from.source, line: from.line, message: "config-file cycle: \(path)")) }
                return
            }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                if !optional, let from {
                    issues.append(Issue(source: from.source, line: from.line, message: "cannot read \(path)"))
                }
                return
            }
            visiting.insert(path)
            files.append(url)
            let parsed = parse(text, source: path)
            issues += parsed.issues
            for e in parsed.entries {
                if e.key == "config-file" {
                    var p = e.value
                    let opt = p.hasPrefix("?")
                    if opt { p.removeFirst() }
                    visit(resolve(p, relativeTo: url), optional: opt, from: e)
                } else {
                    entries.append(e)
                }
            }
            visiting.remove(path)
        }

        visit(url, optional: true, from: nil)
        return (entries, issues, files)
    }

    /// Expand `~` and resolve relative paths against the including file.
    public static func resolve(_ path: String, relativeTo file: URL) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded) }
        return file.deletingLastPathComponent().appendingPathComponent(expanded)
    }

    /// `$XDG_CONFIG_HOME/wireline/config`, else `~/.config/wireline/config`.
    public static func defaultURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let base: URL
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            base = URL(fileURLWithPath: (xdg as NSString).expandingTildeInPath)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        }
        return base.appendingPathComponent("wireline/config")
    }

    // MARK: Value coercion

    public static func bool(_ s: String) -> Bool? {
        switch s.lowercased() {
        case "true", "yes", "on", "1": return true
        case "false", "no", "off", "0": return false
        default: return nil
        }
    }

    public static func number(_ s: String, in range: ClosedRange<Double>) -> Double? {
        guard let d = Double(s), d.isFinite else { return nil }
        return min(max(d, range.lowerBound), range.upperBound)
    }

    /// A keybind value `mods+key=action`, e.g. `cmd+shift+t=new_local_terminal`.
    public struct Keybind: Equatable, Sendable {
        public var key: String
        public var command = false, shift = false, option = false, control = false
        public var action: String
    }

    /// Non-character keys a keybind may name. `enter` is accepted for `return`.
    public static let namedKeys: Set<String> = ["left", "right", "up", "down", "return", "enter"]

    public static func keybind(_ s: String) -> Keybind? {
        // Split on the LAST "=" so a bound "=" key (cmd+==action) still parses.
        guard let eq = s.lastIndex(of: "="), eq != s.startIndex else { return nil }
        let trigger = s[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
        let action = s[s.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        guard !action.isEmpty else { return nil }
        var parts = trigger.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        // "cmd++" → the key itself is "+".
        if trigger.hasSuffix("++") { parts.removeLast(2); parts.append("+") }
        guard let key = parts.popLast(), key.count == 1 || namedKeys.contains(key) else { return nil }
        var kb = Keybind(key: key == "enter" ? "return" : key, action: action)
        for m in parts {
            switch m {
            case "cmd", "command", "super": kb.command = true
            case "shift": kb.shift = true
            case "opt", "option", "alt": kb.option = true
            case "ctrl", "control": kb.control = true
            default: return nil
            }
        }
        return kb
    }
}
