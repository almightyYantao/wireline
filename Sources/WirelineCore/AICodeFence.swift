import Foundation

/// Parses ``` fences out of a model reply and decides which ones are actually
/// commands to execute.
///
/// Agent mode used to take the *first* fence of any kind and hand it to the
/// shell, so a reply that quoted `ls` output, a log line, a JSON sample or a
/// config file got run as a command. A fence is only a candidate when it is
/// tagged as a shell (or carries no tag at all), and only runs when its body
/// reads like a command rather than like terminal output.
public enum AICodeFence {
    public struct Block: Equatable {
        /// Lowercased info string after the opening fence ("" when there is none).
        public let lang: String
        public let body: String

        /// Whether the *tag* claims this block is meant to be executed. Untagged
        /// blocks count — models routinely omit the tag for plain commands.
        public var isShell: Bool { AICodeFence.shellLangs.contains(lang) }
    }

    /// Info strings that mean "shell".
    public static let shellLangs: Set<String> = [
        "", "bash", "sh", "zsh", "shell", "shellscript", "shell-script",
        "fish", "ksh", "dash", "command", "cmd",
    ]

    /// What a reply proposes to run, if anything.
    public enum Proposal: Equatable {
        /// A command that's safe to hand to the shell as-is.
        case runnable(String)
        /// The reply *has* a shell-ish fence, but its body is output/content, not
        /// a command — so agent mode must not run it.
        case notACommand
        /// Nothing that even claims to be a command.
        case none
    }

    /// Split a reply into its fenced blocks, in order. An unterminated final
    /// fence is included, since replies are inspected while still streaming.
    public static func blocks(in text: String) -> [Block] {
        var out: [Block] = []
        var lang: String?
        var body: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let open = lang {
                    out.append(Block(lang: open, body: body.joined(separator: "\n")))
                    lang = nil
                    body = []
                } else {
                    // The info string sits on the opening fence line — parsing by
                    // line (rather than splitting on "```") is what lets a
                    // one-word command like `uptime` stay a command instead of
                    // being mistaken for a language tag.
                    lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces).lowercased()
                }
            } else if lang != nil {
                body.append(line)
            }
        }
        if let open = lang { out.append(Block(lang: open, body: body.joined(separator: "\n"))) }
        return out
    }

    /// Look through a reply for something agent mode may execute.
    public static func proposal(in text: String) -> Proposal {
        var sawShellBlock = false
        for block in blocks(in: text) where block.isShell {
            sawShellBlock = true
            if let cmd = command(from: block.body) { return .runnable(cmd) }
        }
        return sawShellBlock ? .notACommand : .none
    }

    /// A shell block's body as a runnable command, or nil when it reads like
    /// terminal output. Only the first line is checked for "is this a command",
    /// so real multi-line scripts (loops, heredocs, `&&` chains) still pass.
    public static func command(from body: String) -> String? {
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
            .map { stripPrompt(String($0)) }
        let joined = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joined.isEmpty else { return nil }
        // A single output-looking line anywhere is enough to disqualify the block:
        // a command pasted together with its own output is not runnable either.
        guard !lines.contains(where: isOutputLine) else { return nil }
        guard let first = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              looksLikeCommandLine(first) else { return nil }
        return joined
    }

    /// True when the "command" is just a line the previous command printed — the
    /// classic agent failure of feeding output back into the shell.
    public static func echoesOutput(_ command: String, in previousOutput: String) -> Bool {
        guard !previousOutput.isEmpty else { return false }
        let cmdLines = command.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // Short lines (`ls -la`, `df -h`, `uptime`) are perfectly good commands
        // that also turn up inside output — too generic to judge by echo alone.
        guard !cmdLines.isEmpty, cmdLines.allSatisfy({ $0.count >= 8 }) else { return false }
        let outLines = Set(previousOutput.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
        return cmdLines.allSatisfy(outLines.contains)
    }

    // MARK: - Heuristics

    /// Drop a `$ ` / `% ` / `➜ ` prompt the model sometimes types in front of a
    /// command. Never `#` — that's a legitimate shell comment.
    private static func stripPrompt(_ line: String) -> String {
        guard let r = line.range(of: #"^\s*([$%]|➜|❯|PS[1-9]?>)\s+"#, options: .regularExpression) else { return line }
        return String(line[r.upperBound...])
    }

    /// Shell syntax that legitimately opens a command line. A bare `{` is
    /// deliberately absent — in a model reply it opens a JSON object far more
    /// often than a shell group (a real group is written `{ cmd; }`, handled by
    /// stripping the `{ ` prefix below).
    private static let shellOpeners: Set<String> = [
        "for", "while", "until", "if", "case", "do", "then", "else", "elif",
        "fi", "done", "esac", "function", "[[", "!", ":",
    ]

    /// Single words that head a table of output far more often than a command.
    private static let outputHeaders: Set<String> = [
        "total", "filesystem", "container", "image", "repository", "ready",
        "restarts", "mounted", "proto", "recv-q", "send-q", "active", "loaded",
        "tasks", "cgroup", "traceback", "warning", "error", "usage", "real",
    ]

    private static let outputSignatures = [
        #"^[-dlbcps][rwxsStT-]{9}[.+@]?\s"#,                    // `ls -l` permission bits
        #"^total\s+\d+\s*$"#,                                    // `ls -l` header
        #"^\s*File\s+"[^"]+",\s+line\s+\d+"#,                   // Python traceback frame
        #"^\s*at\s+[\w.$]+\([^)]*\)"#,                           // JVM/JS stack frame
        #"[│┌└├┤┬┴─╭╰┐┘]"#,                                      // box-drawing table
        #"\u{1B}\["#,                                            // raw ANSI escapes
        #"^\s*\[?\d{4}[-/]\d{2}[-/]\d{2}[ T]\d{2}:\d{2}"#,       // log timestamp
        #"(?i)\[(emerg|alert|crit|error|warn|notice|debug)\]"#,  // syslog/nginx level tag
        #"^(real|user|sys)\s+\d+m"#,                             // `time` output
        #"^\s*\d+\s+rows?\s+in\s+set"#,                          // mysql footer
    ]

    /// A line that could only be output, never something to run.
    private static func isOutputLine(_ line: String) -> Bool {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return outputSignatures.contains { line.range(of: $0, options: .regularExpression) != nil }
    }

    /// Whether a line opens a plausible command: its first word has to look like
    /// a command name once `sudo` / `VAR=value` prefixes are peeled off.
    private static func looksLikeCommandLine(_ line: String) -> Bool {
        var rest = line.trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix("#") { return true }   // a script's leading comment
        // Subshell `(cd /x && ls)` and group `{ cmd; }` wrappers.
        if rest.hasPrefix("(") { rest = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces) }
        else if rest.hasPrefix("{ ") { rest = String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
        while true {
            if let r = rest.range(of: #"^(sudo|env|time|nohup|exec|command)\s+"#, options: .regularExpression) {
                rest = String(rest[r.upperBound...]); continue
            }
            if let r = rest.range(of: #"^[A-Za-z_][A-Za-z0-9_]*=\S*\s+"#, options: .regularExpression) {
                rest = String(rest[r.upperBound...]); continue
            }
            break
        }
        guard let token = rest.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) else { return false }
        if shellOpeners.contains(token) { return true }
        // `ls`, `apt-get`, `./deploy.sh`, `/usr/bin/env`, `python3.11`. No colon:
        // `nginx:`, `Active:` and `error:` head output lines, not commands.
        guard token.range(of: #"^[A-Za-z0-9_./~][A-Za-z0-9_./~+-]*$"#, options: .regularExpression) != nil,
              // A command name contains a letter somewhere: `ls`, `./run.sh`,
              // `/usr/bin/env`. A date or a PID (`2026/07/27`, `1234`) does not.
              token.rangeOfCharacter(from: .letters) != nil else { return false }
        // Column headers (`PID`, `NAME`, `STATUS`) are lone uppercase words;
        // commands effectively never are.
        if token.count > 1, token == token.uppercased(), token.rangeOfCharacter(from: .letters) != nil { return false }
        return !outputHeaders.contains(token.lowercased())
    }
}
