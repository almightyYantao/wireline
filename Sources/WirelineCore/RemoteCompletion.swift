import Foundation

/// Whether an SSH pane's remote shell is at its own prompt, so completion may
/// follow the typed line. The local foreground process is always `ssh`, so
/// this relies on the remote shell's OSC 133 marks: nothing pops up until a
/// mark has been seen, and never while a command runs, in the alternate
/// screen, or after a line that opened another shell (nested `ssh`, `su`,
/// `docker exec -it` …) — whose prompts we couldn't tell from this one's —
/// until that shell is left with `exit` / Ctrl-D.
public struct RemotePromptGate: Sendable, Equatable {
    public private(set) var marksSeen = false
    public private(set) var running = false
    public private(set) var nesting = 0

    public init() {}

    public var isOpen: Bool { marksSeen && !running && nesting == 0 }

    /// OSC 133;C.
    public mutating func commandStarted() {
        marksSeen = true
        running = true
    }

    /// OSC 133;D.
    public mutating func commandFinished() {
        marksSeen = true
        running = false
    }

    /// A line submitted with Enter (only lines typed in full are known).
    public mutating func submitted(_ line: String) {
        let ctx = CompletionContext.parse(line + " ")
        if Self.opensShell(ctx.words) { nesting += 1 }
        else if nesting > 0, ["exit", "logout"].contains(ctx.words.first ?? "") { nesting -= 1 }
    }

    /// Ctrl-D on an empty line leaves a nested shell.
    public mutating func endOfInput(lineWasEmpty: Bool) {
        if lineWasEmpty, nesting > 0 { nesting -= 1 }
    }

    /// The connection dropped or was reopened.
    public mutating func reset() { self = RemotePromptGate() }

    static let sshValueOptions = Set("bBcDEeFIiJLlmOoPpQRSWw")

    /// Whether `words` (one command, already split) starts an interactive shell
    /// whose prompts would look like ours.
    public static func opensShell(_ words: [String]) -> Bool {
        var w = words.drop { $0.contains("=") && !$0.hasPrefix("-") }   // FOO=1 cmd
        if w.first == "sudo" {
            w = w.dropFirst()
            if w.contains(where: { $0 == "-i" || $0 == "-s" }) { return true }
            w = w.drop { $0.hasPrefix("-") }
        }
        guard let cmd = w.first else { return false }
        let args = Array(w.dropFirst())
        switch cmd {
        case "ssh", "mosh", "telnet":
            // `ssh host cmd` runs a command and comes back.
            var positional = 0
            var i = 0
            while i < args.count {
                let a = args[i]
                if a.hasPrefix("-"), a.count == 2, let c = a.last, sshValueOptions.contains(c), cmd == "ssh" {
                    i += 2; continue
                }
                if !a.hasPrefix("-") { positional += 1 }
                i += 1
            }
            return cmd != "ssh" || positional <= 1
        case "su", "bash", "zsh", "sh", "fish", "ksh", "tmux", "screen", "byobu", "zellij", "nix-shell", "toolbox":
            return args.allSatisfy { $0.hasPrefix("-") } || ["su", "tmux", "screen", "byobu", "zellij"].contains(cmd)
        case "docker", "podman", "kubectl", "oc", "lxc", "incus":
            return args.contains("exec") || args.contains("run") || args.contains("attach") || args.contains("shell")
        case "exec":
            return opensShell(args)
        default:
            return false
        }
    }
}

public enum RemoteCompletionPaths {
    /// The remote directory to list for the word being typed, as an SFTP path
    /// (relative paths are relative to the login home). `cwd` is the remote
    /// shell's directory (absolute, or `~` / `~/…`); nil when it's needed but
    /// unknown.
    public static func directory(for word: String, cwd: String?) -> String? {
        let dir = CompletionEngine.pathDirectoryPart(word)
        if dir.hasPrefix("/") { return dir }
        if dir.hasPrefix("~/") || word == "~" { return home(dir) }
        if dir.hasPrefix("~") { return nil }                  // ~otheruser/
        guard let cwd, !cwd.isEmpty else { return nil }
        let base: String
        if cwd == "~" || cwd.hasPrefix("~/") { base = home(cwd) }
        else if cwd.hasPrefix("/") { base = cwd }
        else { return nil }
        if dir.isEmpty { return base }
        if base == "." { return dir }
        return base.hasSuffix("/") ? base + dir : base + "/" + dir
    }

    /// `~` → `.`, `~/a/` → `a/` (SFTP resolves relative paths against home).
    private static func home(_ p: String) -> String {
        let rest = p.dropFirst(p.hasPrefix("~/") ? 2 : 1)
        return rest.isEmpty ? "." : String(rest)
    }
}
