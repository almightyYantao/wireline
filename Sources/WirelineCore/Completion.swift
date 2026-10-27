import Foundation

// MARK: - Input line tracking

/// Follows what the user types at a shell prompt, from the bytes sent to the
/// PTY. It only trusts plain typing: any escape sequence (arrows, history,
/// paste), Tab (the shell's own completion) or unknown control key makes the
/// line unknown until the next Enter / Ctrl-C.
public struct CompletionLineTracker: Sendable, Equatable {
    public private(set) var line = ""
    public private(set) var isValid = true
    private var pendingUTF8: [UInt8] = []

    public init() {}

    /// The shell is at a fresh, empty prompt.
    public mutating func promptReady() {
        line = ""
        isValid = true
        pendingUTF8 = []
    }

    /// The line can no longer be followed (a job owns the terminal, an edit we can't model).
    public mutating func invalidate() {
        isValid = false
        line = ""
        pendingUTF8 = []
    }

    /// Feed bytes going to the PTY. Returns the lines submitted with Enter
    /// (only those typed in full while tracking was valid).
    @discardableResult
    public mutating func feed<S: Sequence>(_ bytes: S) -> [String] where S.Element == UInt8 {
        var submitted: [String] = []
        var escaping = false
        for b in bytes {
            if escaping { continue }
            switch b {
            case 0x0D, 0x0A:
                if isValid, !line.trimmingCharacters(in: .whitespaces).isEmpty { submitted.append(line) }
                promptReady()
            case 0x03, 0x04:
                promptReady()
            case 0x7F, 0x08:
                guard isValid else { break }
                if !pendingUTF8.isEmpty { pendingUTF8.removeAll() } else if !line.isEmpty { line.removeLast() }
            case 0x15:
                if isValid { line = "" }
            case 0x17:
                guard isValid else { break }
                while line.last == " " { line.removeLast() }
                while let c = line.last, c != " " { line.removeLast() }
            case 0x1B:
                invalidate()
                escaping = true   // the rest of this chunk is the sequence
            case 0x00..<0x20:
                invalidate()
            default:
                guard isValid else { break }
                pendingUTF8.append(b)
                if let s = String(bytes: pendingUTF8, encoding: .utf8) {
                    line += s
                    pendingUTF8.removeAll()
                } else if pendingUTF8.count >= 4 {
                    invalidate()
                }
            }
        }
        return submitted
    }
}

// MARK: - Parsing

/// A shell input line split for completion.
public struct CompletionContext: Equatable, Sendable {
    /// Finished words before the one being typed (unquoted).
    public var words: [String]
    /// The word under the cursor so far (unquoted).
    public var current: String
    /// The whole line.
    public var line: String

    public var command: String? { words.first }
    /// Index of `current` among the command's words (0 = the command itself).
    public var index: Int { words.count }

    /// Parse `line` — the cursor is at its end. Splits on unquoted whitespace
    /// and resets at `|`, `;`, `&&`, `||` so `cd x && git checkout ma` sees `git`.
    public static func parse(_ line: String) -> CompletionContext {
        var words: [String] = []
        var cur = ""
        var inWord = false
        var quote: Character?
        var escape = false
        for ch in line {
            if escape { cur.append(ch); escape = false; inWord = true; continue }
            if let q = quote {
                if ch == q { quote = nil } else if ch == "\\" && q == "\"" { escape = true } else { cur.append(ch) }
                continue
            }
            switch ch {
            case "\\": escape = true; inWord = true
            case "'", "\"": quote = ch; inWord = true
            case " ", "\t":
                if inWord { words.append(cur); cur = ""; inWord = false }
            case "|", ";", "&":
                words = []; cur = ""; inWord = false
            default:
                cur.append(ch); inWord = true
            }
        }
        return CompletionContext(words: words, current: cur, line: line)
    }
}

// MARK: - Candidates

public struct Completion: Equatable, Hashable, Sendable {
    public enum Kind: String, Sendable { case branch, script, makeTarget, host, path, history, subcommand }
    public var kind: Kind
    /// What is shown.
    public var display: String
    /// The text to type after what the user already has.
    public var insert: String

    public init(kind: Kind, display: String, insert: String) {
        self.kind = kind
        self.display = display
        self.insert = insert
    }
}

/// What the completion sources need about the session, gathered (with IO) by the app.
public struct CompletionData: Sendable {
    public var branches: [String] = []
    public var scripts: [String] = []
    public var makeTargets: [String] = []
    public var hosts: [String] = []
    /// Most recent first.
    public var history: [String] = []
    /// Entries of the directory `current` points into; directories end in "/".
    public var pathEntries: [String] = []

    public init() {}
}

/// Which data a context wants, so the app only does the IO needed.
public struct CompletionNeeds: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let branches = Self(rawValue: 1)
    public static let scripts = Self(rawValue: 2)
    public static let makeTargets = Self(rawValue: 4)
    public static let hosts = Self(rawValue: 8)
    public static let paths = Self(rawValue: 16)
    public static let history = Self(rawValue: 32)
}

public enum CompletionEngine {
    static let gitBranchCommands: Set<String> = ["checkout", "switch", "merge", "rebase", "branch", "diff", "log",
                                                 "cherry-pick", "reset", "push", "pull", "show", "worktree"]
    static let gitSubcommands = ["add", "branch", "checkout", "cherry-pick", "clone", "commit", "diff", "fetch",
                                 "log", "merge", "pull", "push", "rebase", "reset", "restore", "show", "stash",
                                 "status", "switch", "tag", "worktree"]
    static let sshCommands: Set<String> = ["ssh", "scp", "sftp", "rsync", "mosh", "ssh-copy-id"]
    static let pathCommands: Set<String> = ["cd", "cat", "ls", "vim", "vi", "nvim", "less", "more", "head", "tail",
                                            "open", "code", "rm", "cp", "mv", "source", ".", "bat", "touch", "mkdir",
                                            "chmod", "chown", "grep", "rg", "python", "python3", "node", "bash", "sh",
                                            "zsh", "nano", "du", "wc", "tar", "unzip", "diff", "find", "git", "make"]

    enum Source { case branch, script, makeTarget, host, path, gitSubcommand }

    static func sources(for ctx: CompletionContext) -> [Source] {
        guard let cmd = ctx.command else { return [] }
        let args = Array(ctx.words.dropFirst())
        let positional = args.filter { !$0.hasPrefix("-") }
        // Right after a short option (`ssh -p `) the word is its value.
        if ctx.current.isEmpty, let last = args.last, last.count == 2, last.hasPrefix("-") { return [] }
        switch cmd {
        case "git":
            if positional.isEmpty { return ctx.current.hasPrefix("-") ? [] : [.gitSubcommand] }
            return gitBranchCommands.contains(positional[0]) ? [.branch, .path] : [.path]
        case "npm", "bun":
            if args.first == "run" || args.first == "run-script" { return args.count == 1 ? [.script] : [.path] }
            return args.isEmpty && cmd == "bun" ? [.script, .path] : [.path]
        case "pnpm", "yarn":
            if args.first == "run" { return args.count == 1 ? [.script] : [.path] }
            return args.isEmpty ? [.script] : [.path]
        case "make", "gmake":
            return ctx.current.hasPrefix("-") ? [] : [.makeTarget]
        default:
            if sshCommands.contains(cmd) {
                if ctx.current.hasPrefix("-") { return [] }
                // scp/rsync take paths as well as host:path.
                return cmd == "ssh" || cmd == "mosh" || cmd == "ssh-copy-id" ? [.host] : [.host, .path]
            }
            if ctx.current.hasPrefix("-") { return [] }
            return pathCommands.contains(cmd) || looksLikePath(ctx.current) ? [.path] : []
        }
    }

    static func looksLikePath(_ s: String) -> Bool {
        s.hasPrefix("/") || s.hasPrefix("~") || s.hasPrefix("./") || s.hasPrefix("../") || s.contains("/")
    }

    public static func needs(for ctx: CompletionContext) -> CompletionNeeds {
        var n: CompletionNeeds = []
        if ctx.words.isEmpty {
            if looksLikePath(ctx.current) { n.insert(.paths) }
            return ctx.current.count >= 1 ? n.union(.history) : n
        }
        for s in sources(for: ctx) {
            switch s {
            case .branch: n.insert(.branches)
            case .script: n.insert(.scripts)
            case .makeTarget: n.insert(.makeTargets)
            case .host: n.insert(.hosts)
            case .path: n.insert(.paths)
            case .gitSubcommand: break
            }
        }
        if !ctx.current.isEmpty || n.isEmpty { n.insert(.history) }
        return n
    }

    /// Whether the popup should open with nothing typed in the current word
    /// (right after `git checkout `, `npm run `, `make `, `ssh `).
    static func offersEmpty(_ ctx: CompletionContext) -> Bool {
        sources(for: ctx).contains { if case .path = $0 { return false } else { return true } }
    }

    /// Ranked candidates for `ctx`, best first.
    public static func suggest(_ ctx: CompletionContext, data: CompletionData, limit: Int = 8) -> [Completion] {
        var out: [Completion] = []
        var seen = Set<String>()
        func add(_ kind: Completion.Kind, _ items: [String], escape: Bool = true) {
            let typed = ctx.current
            if typed.isEmpty, !offersEmpty(ctx) { return }
            for item in rank(items, prefix: typed) where item != typed {
                let rest = String(item.dropFirst(typed.count))
                let insert = (escape ? shellEscape(rest) : rest) + (item.hasSuffix("/") ? "" : " ")
                guard seen.insert(item).inserted else { continue }
                out.append(Completion(kind: kind, display: item, insert: insert))
            }
        }

        if !ctx.words.isEmpty {
            for s in sources(for: ctx) {
                switch s {
                case .gitSubcommand: add(.subcommand, gitSubcommands)
                case .branch: add(.branch, data.branches)
                case .script: add(.script, data.scripts)
                case .makeTarget: add(.makeTarget, data.makeTargets)
                case .host: add(.host, data.hosts)
                case .path: add(.path, pathMatches(ctx.current, entries: data.pathEntries))
                }
            }
        } else if looksLikePath(ctx.current) {
            add(.path, pathMatches(ctx.current, entries: data.pathEntries))
        }

        // History: whole-line prefix, after the specific sources.
        let line = ctx.line
        if line.trimmingCharacters(in: .whitespaces).count >= 2 {
            var hist: [Completion] = []
            var seenLines = Set<String>()
            for h in data.history where h.count > line.count && h.hasPrefix(line) && seenLines.insert(h).inserted {
                hist.append(Completion(kind: .history, display: h, insert: String(h.dropFirst(line.count))))
                if hist.count >= limit { break }
            }
            // Specific sources first, but keep room for a few history lines.
            let keep = max(limit - min(hist.count, 3), 0)
            out = Array(out.prefix(keep)) + hist
        }
        return Array(out.prefix(limit))
    }

    /// Case-sensitive prefix matches (accepting only appends, so the typed text
    /// must match exactly), shorter then alphabetical; nothing typed keeps input order.
    static func rank(_ items: [String], prefix: String) -> [String] {
        if prefix.isEmpty { return items }
        return items.filter { $0.hasPrefix(prefix) }
            .sorted { $0.count != $1.count ? $0.count < $1.count : $0 < $1 }
    }

    /// Full words for path candidates: the typed directory part + each entry.
    static func pathMatches(_ current: String, entries: [String]) -> [String] {
        let dir = pathDirectoryPart(current)
        let name = String(current.dropFirst(dir.count))
        return entries.filter { name.hasPrefix(".") || !$0.hasPrefix(".") }.map { dir + $0 }
    }

    /// `src/ma` → `src/`, `ma` → ``, `~/` → `~/`.
    public static func pathDirectoryPart(_ word: String) -> String {
        guard let slash = word.lastIndex(of: "/") else { return "" }
        return String(word[...slash])
    }

    public static func shellEscape(_ s: String) -> String {
        var out = ""
        for ch in s {
            if " '\"\\$`!&;|()<>*?[]{}#".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }
}

// MARK: - File parsers

public enum CompletionParsers {
    /// `scripts` keys of a package.json, in file order where possible.
    public static func packageScripts(_ data: Data) -> [String] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = obj["scripts"] as? [String: Any] else { return [] }
        return scripts.keys.sorted()
    }

    /// Makefile rule targets (`name:`), skipping special, pattern and variable lines.
    public static func makeTargets(_ text: String) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let first = raw.first, first != "\t", first != "#", first != " " else { continue }
            guard let colon = raw.firstIndex(of: ":") else { continue }
            let after = raw[raw.index(after: colon)...]
            if after.hasPrefix("=") { continue }                  // VAR := value
            let head = raw[..<colon]
            if head.contains("=") || head.contains("$") || head.contains("%") { continue }
            for t in head.split(separator: " ") {
                let name = String(t)
                guard !name.hasPrefix("."), seen.insert(name).inserted else { continue }
                out.append(name)
            }
        }
        return out
    }

    /// Concrete `Host` aliases of an ssh config (no wildcards or negations).
    public static func sshHosts(_ text: String) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
            guard parts.count >= 2, parts[0].lowercased() == "host" else { continue }
            for p in parts.dropFirst() {
                let name = String(p)
                if name.contains("*") || name.contains("?") || name.hasPrefix("!") { continue }
                if seen.insert(name).inserted { out.append(name) }
            }
        }
        return out
    }

    /// Commands of a zsh (plain or extended `: time:0;cmd`) or bash history
    /// file, most recent first, without duplicates. Multi-line entries are skipped.
    public static func history(_ text: String, limit: Int = 5000) -> [String] {
        var lines: [String] = []
        var continued = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if continued { continued = raw.hasSuffix("\\"); continue }
            if raw.hasSuffix("\\") { continued = true; continue }
            var s = Substring(raw)
            if s.hasPrefix(": "), let semi = s.firstIndex(of: ";") { s = s[s.index(after: semi)...] }
            if s.hasPrefix("#") && s.dropFirst().allSatisfy(\.isNumber) { continue }   // bash timestamps
            let cmd = s.trimmingCharacters(in: .whitespaces)
            if !cmd.isEmpty { lines.append(cmd) }
        }
        var out: [String] = []
        var seen = Set<String>()
        for cmd in lines.reversed() where seen.insert(cmd).inserted {
            out.append(cmd)
            if out.count >= limit { break }
        }
        return out
    }
}
