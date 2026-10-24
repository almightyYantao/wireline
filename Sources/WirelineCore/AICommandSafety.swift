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

    /// Whether `command` only reads. Read-only commands run without asking
    /// (the agent's sandbox, the MCP server's confirm / trust modes), so when
    /// in doubt this says no.
    public static func isReadOnly(_ command: String) -> Bool {
        // Output redirection writes; elevation; command / process substitution
        // runs anything inside an otherwise harmless `echo`.
        if command.contains(">") || command.contains("`") || command.contains("$(")
            || command.contains("<(") || command.range(of: #"\b(sudo|su|doas)\b"#, options: .regularExpression) != nil {
            return false
        }
        // Split into pipeline / chain segments; every segment must be allowlisted.
        let segments = command.split(whereSeparator: { "|;&\n".contains($0) })
        guard !segments.isEmpty else { return false }
        for seg in segments {
            let tokens = seg.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            // Leading `VAR=value` assignments are fine; the command comes after.
            guard let i = tokens.firstIndex(where: { !$0.contains("=") }) else { return false }
            let base = (tokens[i].lowercased() as NSString).lastPathComponent
            guard readOnlyCommands.contains(base) else { return false }
            let args = Array(tokens[(i + 1)...])
            if let subs = readOnlySubcommands[base] {
                let sub = args.first { !$0.hasPrefix("-") }?.lowercased()
                guard let sub, subs.contains(sub) else { return false }
            }
            guard argumentsOnlyRead(base, args) else { return false }
        }
        return true
    }

    /// Per-command flags and forms that turn an allowlisted reader into a writer.
    private static func argumentsOnlyRead(_ base: String, _ args: [String]) -> Bool {
        // Case matters (curl -X is the method, -x a proxy), so flags are
        // compared as written.
        let lower = args.map { $0.lowercased() }
        func has(_ flags: Set<String>) -> Bool {
            args.contains { a in flags.contains(a) || flags.contains { $0.hasPrefix("--") && a.hasPrefix($0 + "=") } }
        }
        let positional = args.filter { !$0.hasPrefix("-") }
        switch base {
        case "sed":
            return !args.contains { $0.hasPrefix("-i") || $0.hasPrefix("--in-place") }
        case "env":
            // `env cmd …` runs cmd.
            return !args.contains { !$0.hasPrefix("-") && !$0.contains("=") }
        case "tee":
            return positional.isEmpty
        case "awk":
            return !args.joined(separator: " ").contains("system")
        case "find":
            return !has(["-delete", "-exec", "-execdir", "-ok", "-okdir", "-fprint", "-fprint0", "-fprintf", "-fls"])
        case "sort":
            return !args.contains { $0 == "-o" || $0.hasPrefix("--output") || ($0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("o")) }
        case "curl":
            let writes: Set<String> = ["-d", "--data", "--data-raw", "--data-binary", "--data-urlencode", "--data-ascii",
                                       "--json", "-F", "--form", "--form-string", "-T", "--upload-file", "-o", "--output",
                                       "--output-dir", "-O", "--remote-name", "--remote-name-all", "-K", "--config"]
            if has(writes) { return false }
            // Clustered short flags (-sSO, -dfoo) hide the same letters.
            if args.contains(where: { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.count > 2
                && $0.dropFirst().contains(where: { "dFTOoK".contains($0) }) }) { return false }
            let readMethods: Set<String> = ["GET", "HEAD", "OPTIONS"]
            for (n, a) in args.enumerated() {
                if a == "-X" || a == "--request" {
                    guard n + 1 < args.count, readMethods.contains(args[n + 1].uppercased()) else { return false }
                } else if a.hasPrefix("--request=") {
                    guard readMethods.contains(String(a.dropFirst("--request=".count)).uppercased()) else { return false }
                } else if a.hasPrefix("-X") {
                    guard readMethods.contains(String(a.dropFirst(2)).uppercased()) else { return false }
                }
            }
            return true
        case "wget":
            // wget saves to a file unless told to print or only check; -o / -a write a log.
            let joined = args.joined(separator: " ")
            let toStdout = ["-O -", "-O-", "-qO-", "-qO -", "--output-document=-", "--spider"].contains { joined.contains($0) }
            return toStdout && !has(["-o", "--output-file", "-a", "--append-output"])
        case "ip":
            let verbs: Set<String> = ["add", "del", "delete", "set", "change", "replace", "flush", "append",
                                      "prepend", "up", "down", "save", "restore", "exec", "attach", "detach"]
            return !lower.contains { verbs.contains($0) }
        case "ifconfig":
            return positional.count <= 1
        case "mount":
            return positional.isEmpty
        case "hostname":
            return positional.isEmpty
        case "date":
            return !has(["-s", "--set"])
        case "dmesg":
            return !has(["-c", "-C", "--clear", "--read-clear", "-n", "--console-level", "-D", "-E",
                         "--console-off", "--console-on"])
        case "journalctl":
            return !lower.contains { $0.hasPrefix("--vacuum") || $0 == "--rotate" || $0 == "--flush" || $0 == "--relinquish-var" || $0.hasPrefix("--setup-keys") }
        case "docker":
            if positional.first?.lowercased() == "image" {
                return ["ls", "list", "inspect", "history"].contains(positional.dropFirst().first?.lowercased() ?? "ls")
            }
            return true
        case "kubectl":
            if positional.first?.lowercased() == "config" {
                return ["view", "get-contexts", "current-context", "get-clusters", "get-users"]
                    .contains(positional.dropFirst().first?.lowercased() ?? "")
            }
            return true
        case "git":
            switch positional.first?.lowercased() {
            case "branch":
                // Listing only: no names (create / rename) and no mutating flags.
                return positional.count == 1 && !has(["-d", "-D", "--delete", "-m", "-M", "--move", "-c", "-C", "--copy",
                                                      "-f", "--force", "-u", "--set-upstream-to", "--unset-upstream",
                                                      "--edit-description", "-t", "--track"])
            case "remote":
                return positional.count == 1 || ["show", "get-url"].contains(positional[1].lowercased())
            case "config":
                return lower.contains { $0 == "--get" || $0.hasPrefix("--get-") || $0 == "--list" || $0 == "-l" }
                    && !lower.contains { ["--add", "--unset", "--unset-all", "--replace-all", "--rename-section", "--remove-section", "-e", "--edit"].contains($0) }
            default:
                return true
            }
        default:
            return true
        }
    }
}
