import AppKit
import SwiftTerm
import WirelineCore

/// Picks a monospaced font for the terminal that includes Nerd-Font / Powerline
/// glyphs, so prompts like Powerlevel10k / starship render their icons instead
/// of tofu boxes. Falls back to the system monospaced font.
enum TerminalFont {
    /// Preferred families, best first. These are the common Nerd-Font installs.
    static let candidates = [
        "MesloLGS NF", "MesloLGM Nerd Font", "Hack Nerd Font Mono", "Hack Nerd Font",
        "JetBrainsMono Nerd Font", "FiraCode Nerd Font", "SauceCodePro Nerd Font",
        "Symbols Nerd Font Mono", "Meslo LG S for Powerline"
    ]

    static func preferred(size: CGFloat) -> NSFont? {
        let available = Set(NSFontManager.shared.availableFontFamilies)
        for family in candidates where available.contains(family) {
            if let f = NSFont(name: family, size: size) { return f }
            if let member = NSFontManager.shared.availableMembers(ofFontFamily: family)?.first,
               let name = member.first as? String, let f = NSFont(name: name, size: size) {
                return f
            }
        }
        // Any family advertising Nerd-Font support.
        if let nerd = NSFontManager.shared.availableFontFamilies.first(where: {
            $0.lowercased().contains("nerd font")
        }), let f = NSFont(name: nerd, size: size) {
            return f
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

/// A `LocalProcessTerminalView` that spawns `ssh` in a PTY and — for
/// password hosts — best-effort auto-fills the Keychain password and runs
/// `sudo -i` when the host is flagged auto-sudo.
///
/// Injection is deliberately conservative: the password is sent at most twice
/// (login prompt, then an optional sudo prompt) and only when the incoming
/// stream actually looks like a password prompt, so it never leaks into a
/// normal shell.
final class WirelineTerminalView: LocalProcessTerminalView {
    private let password: String?
    private let autoSudo: Bool

    /// Invoked when the user presses ⌘W while this terminal is focused, so the
    /// app can close just this session instead of the whole window.
    var onCloseRequested: (() -> Void)?

    private var tail = ""            // rolling tail of recent output
    private var passwordSends = 0
    private var sudoSent = false
    private var lastPasswordSend: DispatchTime?

    init(frame: CGRect, password: String?, autoSudo: Bool) {
        self.password = password
        self.autoSudo = autoSudo
        super.init(frame: frame)
        if let font = TerminalFont.preferred(size: 13) { self.font = font }
        // Green-on-black to match the app's console theme.
        nativeBackgroundColor = NSColor(red: 0.039, green: 0.055, blue: 0.039, alpha: 1)
        nativeForegroundColor = NSColor(red: 0.78, green: 0.83, blue: 0.78, alpha: 1)
        caretColor = NSColor(red: 0.20, green: 0.82, blue: 0.50, alpha: 1)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Intercept the "close shell" shortcut so it closes this session rather
        // than the containing window. The binding is user-customizable.
        if event.type == .keyDown,
           KeyBindingStore.shared.shortcut(for: .closeShell).matches(event) {
            onCloseRequested?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// A rolling, ANSI-stripped tail of recent terminal output, for AI context.
    private(set) var recentClean = ""

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        let chunk = String(decoding: slice, as: UTF8.self)
        detectFullScreenApp(chunk)
        recentClean += Self.stripAnsi(chunk)
        if recentClean.count > 20000 { recentClean = String(recentClean.suffix(20000)) }
        guard password != nil || autoSudo else { return }

        tail += String(decoding: slice, as: UTF8.self)
        if tail.count > 600 { tail = String(tail.suffix(600)) }
        // Examine the last couple of non-empty lines — the live prompt.
        let lines = tail.split(separator: "\n", omittingEmptySubsequences: false)
        let lastLine = lines.reversed().first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map(String.init) ?? ""

        // 1) Answer a password prompt (ssh login or sudo), deduped so multiple
        //    read chunks around the same prompt don't double-send.
        if let password, passwordSends < 3, isPasswordPrompt(lastLine), mayResend() {
            passwordSends += 1
            lastPasswordSend = .now()
            tail = ""
            send(txt: password + "\n")
            return
        }

        // 2) On the first real shell prompt, kick off auto-sudo once.
        if autoSudo, !sudoSent, isShellPrompt(lastLine) {
            sudoSent = true
            tail = ""
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.send(txt: SSHCommand.autoSudoRemoteCommand() + "\n")
            }
        }
    }

    // MARK: - Full-screen editor detection

    /// Fired when a vim-family editor starts (`"vim"`) or exits (`nil`), so the
    /// UI can pop up / hide the cheat-sheet. Runs on the main thread.
    var onEditorChange: ((String?) -> Void)?

    private var detectTail = ""
    private var inAltBuffer = false
    /// While in the alt screen and not yet identified, keep sniffing content for
    /// vim's on-screen signatures (see `contentLooksLikeVim`).
    private var vimSniffing = false
    private var reportedEditor: String?

    /// Detect the alternate-screen-buffer switch that full-screen TUIs (vim, less,
    /// htop…) trigger. Identify vim two ways — the echoed command that launched it,
    /// or vim's on-screen signatures once drawn — so the hint is reliable even with
    /// fancy prompts or indirect launches (`git commit`, `crontab -e`). Only vim
    /// raises the hint, matching what the cheat-sheet documents.
    private func detectFullScreenApp(_ chunk: String) {
        detectTail += chunk
        if detectTail.count > 4000 { detectTail = String(detectTail.suffix(4000)) }

        let enterTokens = ["\u{1b}[?1049h", "\u{1b}[?1047h", "\u{1b}[?47h"]
        let exitTokens  = ["\u{1b}[?1049l", "\u{1b}[?1047l", "\u{1b}[?47l"]
        func lastIndex(of tokens: [String]) -> String.Index? {
            tokens.compactMap { detectTail.range(of: $0, options: .backwards)?.lowerBound }.max()
        }
        let enterAt = lastIndex(of: enterTokens)
        let exitAt = lastIndex(of: exitTokens)

        // Current state = whichever toggle appears later in the buffer.
        let nowInAlt: Bool
        switch (enterAt, exitAt) {
        case (nil, nil): nowInAlt = inAltBuffer     // no toggle yet; keep current
        case (.some, nil): nowInAlt = true
        case (nil, .some): nowInAlt = false
        case let (.some(e), .some(x)): nowInAlt = e > x
        }

        if nowInAlt != inAltBuffer {
            inAltBuffer = nowInAlt
            if nowInAlt {
                // Just entered a full-screen app.
                if let e = enterAt, looksLikeVim(before: e) {
                    report("vim")
                } else {
                    vimSniffing = true          // undecided — watch the content
                }
            } else {
                vimSniffing = false
                report(nil)
            }
        } else if inAltBuffer, vimSniffing, contentLooksLikeVim(chunk) {
            report("vim")
        }
    }

    private func report(_ editor: String?) {
        if editor != nil { vimSniffing = false }
        guard editor != reportedEditor else { return }
        reportedEditor = editor
        onEditorChange?(editor)
    }

    /// vim's distinctive on-screen output: a column of `~` for empty lines, or a
    /// mode banner. `less`/`htop`/`man` don't draw these.
    private func contentLooksLikeVim(_ chunk: String) -> Bool {
        let clean = Self.stripAnsi(chunk)
        if clean.contains("-- INSERT --") || clean.contains("-- VISUAL --") { return true }
        let tildes = clean.filter { $0 == "~" }.count
        return tildes >= 3
    }

    /// Was a vim-family editor the command that just switched to the alt screen?
    /// Scans a ~300-char window right before the switch (ANSI escapes stripped)
    /// for a `vim`/`vi`/`nvim` command word. A window, rather than just the last
    /// line, tolerates prompt redraws (e.g. powerlevel10k transient prompt).
    private func looksLikeVim(before enterIndex: String.Index) -> Bool {
        let head = detectTail[..<enterIndex]
        let start = head.index(head.endIndex, offsetBy: -300, limitedBy: head.startIndex) ?? head.startIndex
        let window = Self.stripAnsi(String(head[start...]))
        let words = window.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        let editors: Set<String> = ["vim", "vi", "nvim", "view", "vimdiff", "nvimdiff"]
        return words.contains { editors.contains($0) }
    }

    /// Remove CSI / OSC escape sequences so residual escape bytes don't get
    /// mistaken for command words.
    private static func stripAnsi(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "\u{1b}" {
                // Skip until the terminating byte of the escape sequence.
                var j = s.index(after: i)
                while j < s.endIndex {
                    let c = s[j]
                    if c.isLetter || c == "\u{07}" { j = s.index(after: j); break }
                    j = s.index(after: j)
                }
                i = j
            } else {
                out.append(s[i])
                i = s.index(after: i)
            }
        }
        return out
    }

    /// At least ~1.5s since the last password we sent, so we don't answer the
    /// same prompt twice as it streams in over several reads.
    private func mayResend() -> Bool {
        guard let last = lastPasswordSend else { return true }
        return DispatchTime.now().uptimeNanoseconds - last.uptimeNanoseconds > 1_500_000_000
    }

    private func isPasswordPrompt(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces).lowercased()
        guard t.hasSuffix(":") else { return false }
        return t.contains("password") || t.contains("passphrase")
    }

    private func isShellPrompt(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.hasSuffix("$") || t.hasSuffix("#") || t.hasSuffix("%") || t.hasSuffix("❯") || t.hasSuffix(">")
    }
}
