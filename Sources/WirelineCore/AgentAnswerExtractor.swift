import Foundation

/// Pulls a coding agent's most recent answer out of a terminal's scrollback,
/// minus the TUI around it: the input box, spinners, tool calls and their
/// output, the `⏺` / `•` bullets and the two-space hanging indent.
///
/// Both Claude Code and Codex print a turn as bullet blocks at column 0
/// (`⏺` / `●` for Claude, `•` for Codex) after the user's prompt line
/// (`>` / `❯` / `›`). Text blocks are the answer; tool blocks (`Bash(…)`,
/// `Ran …`, anything with a `⎿` / `└` result) are dropped. Markdown the agent
/// rendered (fences, `#`) is already gone by then — what's left is the text.
public enum AgentAnswerExtractor {
    public static func latestAnswer(in screen: String, agent: CodingAgent? = nil) -> String? {
        let lines = plainLines(screen)
        guard let last = lines.lastIndex(where: isAnswerStart) else { return nil }
        let start = (lines[..<last].lastIndex(where: isUserLine) ?? -1) + 1
        var end = last + 1
        while end < lines.count, !isChrome(lines[end]), !isUserLine(lines[end]) { end += 1 }

        var blocks: [[String]] = []
        for line in lines[start..<end] {
            if isSpinner(line) { continue }
            // Claude Code's `∴ Thinking…` block: kept out like a tool block.
            if marked(line, ["∴"]) { blocks.append([thinkingHeader]); continue }
            if isAnswerStart(line) { blocks.append([String(line.dropFirst().drop { $0 == " " })]) }
            else if !blocks.isEmpty { blocks[blocks.count - 1].append(dedent(line)) }
        }
        let text = blocks.filter { !isTool($0, agent: agent) }
            .map { $0.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        return text.isEmpty ? nil : text
    }

    /// Escape sequences out, line ends normalised, trailing blanks trimmed.
    public static func plainLines(_ s: String) -> [String] {
        stripEscapes(s).replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { line in
                var l = Substring(line)
                while let c = l.last, c == " " || c == "\u{a0}" { l.removeLast() }
                return String(l)
            }
    }

    /// CSI, OSC (BEL / ST terminated) and two-byte escapes.
    static func stripEscapes(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        let u = Array(s.unicodeScalars)
        var i = 0
        while i < u.count {
            guard u[i] == "\u{1b}", i + 1 < u.count else { out.append(u[i]); i += 1; continue }
            let kind = u[i + 1]
            i += 2
            if kind == "[" {
                while i < u.count, !(0x40...0x7E).contains(u[i].value) { i += 1 }
                i += 1
            } else if kind == "]" || kind == "P" || kind == "_" {
                while i < u.count {
                    if u[i] == "\u{07}" { i += 1; break }
                    if u[i] == "\u{1b}", i + 1 < u.count, u[i + 1] == "\\" { i += 2; break }
                    i += 1
                }
            }
        }
        return String(out)
    }

    private static let thinkingHeader = "\u{0}thinking"
    private static let answerMarks: Set<Character> = ["⏺", "●", "•", "✦"]
    private static let userMarks: Set<Character> = [">", "❯", "›"]
    private static let spinnerMarks: Set<Character> = ["✻", "✶", "✳", "✢", "✽", "·", "*", "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    private static func marked(_ line: String, _ marks: Set<Character>) -> Bool {
        guard let c = line.first, marks.contains(c) else { return false }
        let rest = line.dropFirst()
        return rest.isEmpty || rest.first == " "
    }

    static func isAnswerStart(_ line: String) -> Bool { marked(line, answerMarks) }
    static func isUserLine(_ line: String) -> Bool { marked(line, userMarks) }
    static func isSpinner(_ line: String) -> Bool { marked(line, spinnerMarks) }

    /// The input box and rules that close a turn.
    static func isChrome(_ line: String) -> Bool {
        guard let c = line.first else { return false }
        if "╭╰│┌└".contains(c) { return true }
        // A rule, or Codex's `─ Worked for 1m 02s ─────`.
        return "─━═".contains(c) && line.filter { "─━═".contains($0) }.count >= 3
    }

    private static func dedent(_ line: String) -> String {
        line.hasPrefix("  ") ? String(line.dropFirst(2)) : String(line.drop { $0 == " " })
    }

    private static let codexToolVerbs = ["Ran ", "Running ", "Explored", "Exploring", "Edited ", "Added ", "Deleted ",
                                         "Updated Plan", "Read ", "Search ", "List ", "Waited", "Called ", "Proposed Change",
                                         "Change Approved", "Interrupted", "Working (", "Thinking"]

    static func isTool(_ block: [String], agent: CodingAgent?) -> Bool {
        guard let header = block.first, header != thinkingHeader else { return true }
        // Collapsed tool groups: `Read 3 files (ctrl+o to expand)`, `Searched for 2 patterns, read 1 file`.
        if header.range(of: #"\(ctrl\+\w to expand\)$"#, options: .regularExpression) != nil { return true }
        if header.range(of: #"^(Read|Searched for|Listed|Wrote|Updated|Found) \d+ "#, options: .regularExpression) != nil,
           header.split(separator: " ").count <= 10 { return true }
        if block.dropFirst().contains(where: { l in
            let t = l.drop { $0 == " " }
            return t.hasPrefix("⎿") || t.hasPrefix("└")
        }) { return true }
        // Claude Code: `Bash(ls)`, `Read(Sources/a.swift)`, `github - search (MCP)(q: …)`.
        if header.range(of: #"^[A-Za-z][\w.:-]*( - [\w .:-]+)?( \(MCP\))?\("#, options: .regularExpression) != nil {
            return true
        }
        if agent != .claude, codexToolVerbs.contains(where: { header.hasPrefix($0) }) { return true }
        return false
    }
}
