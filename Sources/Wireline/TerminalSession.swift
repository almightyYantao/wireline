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
        // Intercept ⌘W: close this shell session, not the containing window.
        if event.type == .keyDown,
           event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "w" {
            onCloseRequested?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
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
