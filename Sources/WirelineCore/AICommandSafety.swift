import Foundation

/// Flags commands that could cause data loss / outage, so agent mode can force a
/// confirmation before running them.
public enum AICommandSafety {
    /// The first unfilled `«placeholder»` in a command, if any (e.g. `«project»`).
    /// Agent mode must never send a command that still contains one to the shell.
    ///
    /// Guillemets, not `{{…}}`: `{{…}}` is Go-template syntax that appears in
    /// perfectly good commands — `docker inspect --format '{{range .Mounts}}{{.Source}}{{end}}'`,
    /// `kubectl -o go-template=…`, Helm — and treating those braces as blanks
    /// halted agent mode on them. A legacy `{{name}}` is still caught, but only
    /// when the command isn't otherwise using template syntax.
    public static func unfilledPlaceholder(_ command: String) -> String? {
        if let m = firstMatch(#"«[^«»\n]{0,60}»"#, in: command) { return m }
        guard !usesTemplateSyntax(command) else { return nil }
        return firstMatch(#"\{\{\s*[\p{L}\p{N}_]+\s*\}\}"#, in: command)
    }

    /// Whether a command's braces belong to a template language (Go templates in
    /// docker/kubectl/helm, jsonpath) rather than marking a blank to fill in.
    private static func usesTemplateSyntax(_ command: String) -> Bool {
        let pattern = #"(?i)(--format|--template|go-template|jsonpath|\{\{[-\s]*(\.|/|range\b|end\b|if\b|else\b|with\b|define\b|template\b|block\b|printf\b|index\b|len\b|json\b|quote\b|default\b|toyaml\b))"#
        return command.range(of: pattern, options: .regularExpression) != nil
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let r = text.range(of: pattern, options: .regularExpression) else { return nil }
        return String(text[r])
    }

    public static func isDangerous(_ command: String) -> Bool {
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

    public static func isReadOnly(_ command: String) -> Bool {
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
