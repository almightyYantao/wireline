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
    private let sudoPassword: String?
    private let autoSudo: Bool

    /// Invoked when the user presses ⌘W while this terminal is focused, so the
    /// app can close just this session instead of the whole window.
    var onCloseRequested: (() -> Void)?

    /// Called when a command that ran for a while finishes (the shell prompt
    /// returns), with its elapsed seconds — drives the "command finished" notice.
    var onCommandFinished: ((TimeInterval) -> Void)?

    /// Called when this session's busy state flips: `true` when a command/process
    /// starts running (the shell prompt goes away), `false` when it returns to the
    /// prompt (with the run's elapsed seconds). Drives the "running…" tab badge and
    /// the background-tab completion reminder. Emitted only after the first shell
    /// prompt, so the initial connect/login phase doesn't count as a "run".
    var onBusyChange: ((Bool, TimeInterval) -> Void)?

    /// Called on every chunk of output, so a backgrounded tab can flag that it has
    /// unread output. Kept lightweight — the session decides whether it matters.
    var onOutput: (() -> Void)?

    /// Fired once when the first byte arrives from the host — i.e. the connection
    /// is live and the server is responding (dialing → connected).
    var onConnected: (() -> Void)?
    /// Fired when the underlying process exits (ssh dropped, logout, killed).
    var onDisconnected: ((Int32?) -> Void)?
    private var hasConnected = false

    /// Opaque background for the IME marked-text (composition) overlay. SwiftTerm
    /// styles that floating preview with `nativeBackgroundColor`, but we force the
    /// terminal's native background to `.clear` for wallpaper translucency — and
    /// `.clear` faded to 0.9 alpha renders as an ugly opaque black box. So we hand
    /// the overlay a real, opaque theme color instead. Set from the active theme.
    var markedTextBackground: NSColor = NSColor(srgbRed: 0.11, green: 0.12, blue: 0.14, alpha: 1)

    // Session logging: append ANSI-stripped output to a file while active.
    private var logHandle: FileHandle?

    /// Begin logging this session's (clean) output to a file under
    /// `~/Library/Logs/Wireline/`. Returns the file URL, or nil on failure.
    func startLogging(label: String) -> URL? {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Wireline", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = label.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let stamp = Self.logStampFormatter.string(from: Date())
        let url = dir.appendingPathComponent("\(String(safe))-\(stamp).log")
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else { return nil }
        // Seed with a header so a fresh log has context.
        handle.write(Data("# Wireline session log — \(label) — \(stamp)\n".utf8))
        logHandle = handle
        return url
    }

    func stopLogging() {
        try? logHandle?.close()
        logHandle = nil
    }

    private static let logStampFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmmss"; return f
    }()

    private var tail = ""            // rolling tail of recent output
    private var passwordSends = 0
    private var sudoPasswordSends = 0
    private var sudoSent = false
    private var lastPasswordSend: DispatchTime?

    // Command-timing for the finished-notification, inferred from output only
    // (SwiftTerm seals the key-input path, so we can't observe Return): a command
    // runs from when the shell prompt disappears (output starts) to when it
    // returns.
    private var atPrompt = true
    private var leftPromptAt: DispatchTime?
    private var promptTail = ""
    /// Set once the first shell prompt appears, so the connect/login phase isn't
    /// mistaken for a running command.
    private var hasSeenFirstPrompt = false
    /// Debounced "a command is running" state — survives transient prompt redraws
    /// (async prompt segments, theme repaints) so an idle shell never flickers to
    /// "running".
    private var busy = false
    /// Bumped on every prompt transition to invalidate a pending busy timer.
    private var busyGeneration = 0

    init(frame: CGRect, password: String?, sudoPassword: String? = nil, autoSudo: Bool) {
        self.password = password
        self.sudoPassword = sudoPassword
        self.autoSudo = autoSudo
        super.init(frame: frame)
        // Default SwiftTerm scrollback is 500 lines; deepen it so cross-launch
        // restore (and in-session scrollback) keeps a meaningful amount of history.
        getTerminal().changeScrollback(4000)
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

    /// Tame the overlay scrollbar during streaming output.
    ///
    /// SwiftTerm refreshes its overlay `NSScroller` on *every* line the engine
    /// scrolls (`Terminal.scroll()` → `scrolled(source:yDisp:)` → `updateScroller()`).
    /// That per-line churn is what made the scrollbar misbehave: pinned to the
    /// bottom, the auto-hiding overlay kept flashing back in and the knob shook as
    /// the position briefly lagged the bottom; scrolled up into history, the knob
    /// jittered as the scrollback grew underneath the fixed viewport.
    ///
    /// So we don't refresh the scroller from this streaming callback at all — we
    /// just forward the position to any observer. The scroller still refreshes
    /// accurately where it matters: a wheel/drag scroll goes through `scrollTo`
    /// (which calls `updateScroller` and reveals the overlay), and resize /
    /// buffer-switch refresh it too. The net effect is a scrollbar that's calm
    /// during output and correct the moment you interact with it.
    override func scrolled(source terminal: Terminal, yDisp: Int) {
        terminalDelegate?.scrolled(source: self, position: scrollPosition)
        customScrollbar?.reflectScroll()
    }

    /// The view→app scroll callback — fired both by the engine forward above and by
    /// `scrollTo` (user wheel/drag). A single place to refresh our custom scrollbar.
    override func scrolled(source: TerminalView, position: Double) {
        super.scrolled(source: source, position: position)
        customScrollbar?.reflectScroll()
    }

    // MARK: - Custom scrollbar

    /// SwiftTerm's built-in overlay `NSScroller` (hidden — we draw our own).
    private weak var nativeScroller: NSScroller?
    private var customScrollbar: TerminalScrollbar?

    /// Hide SwiftTerm's scroller and float a themed one that matches the app: a
    /// thin rounded green thumb that widens on hover, is draggable, and fades away
    /// while you're following the bottom.
    private func setupCustomScrollbar() {
        guard customScrollbar == nil else { return }
        if nativeScroller == nil {
            nativeScroller = subviews.compactMap { $0 as? NSScroller }.first
        }
        nativeScroller?.isHidden = true
        let bar = TerminalScrollbar(frame: scrollbarFrame())
        bar.term = self
        bar.autoresizingMask = [.minXMargin, .height]
        addSubview(bar, positioned: .above, relativeTo: nil)
        customScrollbar = bar
    }

    private func scrollbarFrame() -> CGRect {
        let w: CGFloat = 16
        return CGRect(x: bounds.maxX - w, y: 0, width: w, height: bounds.height)
    }

    override func layout() {
        super.layout()
        // Keep SwiftTerm's scroller hidden even if it re-appears after a relayout,
        // and keep our bar pinned to the right edge.
        nativeScroller?.isHidden = true
        customScrollbar?.frame = scrollbarFrame()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        setupCustomScrollbar()
    }

    /// The child process (ssh / shell) exited — the connection is gone. Let the
    /// session flip its state so the UI can show "disconnected".
    override func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        super.processTerminated(source, exitCode: exitCode)
        onDisconnected?(exitCode)
    }

    /// SwiftTerm draws the IME composition preview as a floating `NSTextField`
    /// whose background is `nativeBackgroundColor.withAlphaComponent(0.9)`. Since
    /// we keep the native background `.clear` for translucency, that resolves to a
    /// solid black box. Re-skin the overlay with an opaque theme color and a subtle
    /// rounded border so composing text (e.g. Pinyin) reads as an intentional pill.
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        restyleMarkedTextOverlay()
    }

    private func restyleMarkedTextOverlay() {
        for case let field as NSTextField in subviews where field.drawsBackground {
            field.backgroundColor = markedTextBackground
            field.wantsLayer = true
            field.layer?.backgroundColor = markedTextBackground.cgColor
            field.layer?.cornerRadius = 4
            field.layer?.borderWidth = 1
            field.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        }
    }

    /// A rolling, ANSI-stripped tail of recent terminal output, for AI context.
    private(set) var recentClean = ""

    /// The full buffer (scrollback + screen) serialized WITH colors and styles,
    /// for cross-launch scrollback restore. Read on demand at save time. Returns
    /// empty while a full-screen app owns the alternate screen (see
    /// `serializeColored`), so callers should keep the prior snapshot in that case.
    var renderedBuffer: Data { getTerminal().serializeColored() }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        let chunk = String(decoding: slice, as: UTF8.self)
        detectFullScreenApp(chunk)
        let clean = Self.stripAnsi(chunk)
        recentClean += clean
        if recentClean.count > 20000 { recentClean = String(recentClean.suffix(20000)) }
        if let logHandle { logHandle.write(Data(clean.utf8)) }
        onOutput?()
        if !hasConnected { hasConnected = true; onConnected?() }

        // Command-finished heuristic (output only): track the prompt→output→prompt
        // cycle. Leaving the prompt = a command started; the prompt returning =
        // it finished. Only durations ≥ the threshold notify.
        promptTail += clean
        if promptTail.count > 400 { promptTail = String(promptTail.suffix(400)) }
        let promptLine = promptTail.split(separator: "\n", omittingEmptySubsequences: false)
            .reversed().first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map(String.init) ?? ""
        let nowAtPrompt = isShellPrompt(promptLine)
        // Seeing any prompt means we're past the connect/login phase — even if it
        // doesn't flip the state (e.g. the first output already is a prompt).
        if nowAtPrompt { hasSeenFirstPrompt = true }
        if nowAtPrompt != atPrompt {
            atPrompt = nowAtPrompt
            busyGeneration &+= 1
            if nowAtPrompt {
                // Back at the prompt: if a command had actually started, it's done.
                if busy {
                    busy = false
                    let elapsed = leftPromptAt.map {
                        Double(DispatchTime.now().uptimeNanoseconds - $0.uptimeNanoseconds) / 1e9
                    } ?? 0
                    if elapsed >= 20 { onCommandFinished?(elapsed) }
                    onBusyChange?(false, elapsed)
                }
            } else if hasSeenFirstPrompt {
                // Left the prompt — only count it as "running" if it stays that
                // way for a beat, so prompt redraws / async segments (p10k, etc.)
                // don't flicker the badge on an idle shell.
                leftPromptAt = .now()
                let gen = busyGeneration
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                    guard let self, self.busyGeneration == gen, !self.atPrompt, !self.busy else { return }
                    self.busy = true
                    self.onBusyChange?(true, 0)
                }
            }
        }

        guard password != nil || sudoPassword != nil || autoSudo else { return }

        tail += String(decoding: slice, as: UTF8.self)
        if tail.count > 600 { tail = String(tail.suffix(600)) }
        // Examine the last couple of non-empty lines — the live prompt.
        let lines = tail.split(separator: "\n", omittingEmptySubsequences: false)
        let lastLine = lines.reversed().first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map(String.init) ?? ""

        // 1) Answer the ssh login (or key passphrase) prompt with the login
        //    password — only before auto-sudo kicks in, deduped so multiple read
        //    chunks around the same prompt don't double-send.
        if !sudoSent, let password, passwordSends < 3, isPasswordPrompt(lastLine), mayResend() {
            passwordSends += 1
            lastPasswordSend = .now()
            tail = ""
            send(txt: password + "\n")
            return
        }

        // 1b) Answer the sudo password prompt after `sudo -i`. Uses the dedicated
        //     sudo password, which is available even on key-auth hosts (where the
        //     login `password` is nil).
        if sudoSent, let sudoPassword, sudoPasswordSends < 3, isPasswordPrompt(lastLine), mayResend() {
            sudoPasswordSends += 1
            lastPasswordSend = .now()
            tail = ""
            send(txt: sudoPassword + "\n")
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

/// A themed, self-drawn overlay scrollbar for the terminal, replacing SwiftTerm's
/// native `NSScroller`. A thin rounded green thumb that:
///  - stays hidden while you're following the bottom (no streaming jitter),
///  - reveals on scroll / hover and fades out again shortly after,
///  - widens on hover, and is draggable / click-to-jump.
///
/// It reads the terminal's public `scrollPosition` / `scrollThumbsize` / `canScroll`
/// and drives scrolling via `scroll(toPosition:)`.
final class TerminalScrollbar: NSView {
    weak var term: WirelineTerminalView?

    private var hovering = false
    private var dragging = false
    private var hideTimer: DispatchWorkItem?
    private var tracking: NSTrackingArea?

    private let idleThumbW: CGFloat = 4
    private let hoverThumbW: CGFloat = 9
    private let rightPad: CGFloat = 3
    private let vInset: CGFloat = 3
    private let minThumbH: CGFloat = 28

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        alphaValue = 0
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    override var isFlipped: Bool { true }   // y grows downward: pos 0 = top, 1 = bottom

    // MARK: State reads

    private var canScroll: Bool { term?.canScroll ?? false }
    private var position: CGFloat { CGFloat(term?.scrollPosition ?? 0) }
    private var thumbProp: CGFloat { max(CGFloat(term?.scrollThumbsize ?? 1), 0.04) }
    private var atBottom: Bool { !canScroll || position >= 0.999 }

    private var thumbColor: NSColor {
        // Matches the app's terminal accent (the caret green).
        NSColor(red: 0.20, green: 0.82, blue: 0.50, alpha: hovering || dragging ? 0.9 : 0.5)
    }

    // MARK: Geometry

    private var trackHeight: CGFloat { bounds.height - vInset * 2 }
    private func thumbRect() -> CGRect {
        let thumbH = min(trackHeight, max(minThumbH, trackHeight * thumbProp))
        let travel = max(0, trackHeight - thumbH)
        let y = vInset + travel * position
        let w = hovering || dragging ? hoverThumbW : idleThumbW
        return CGRect(x: bounds.width - w - rightPad, y: y, width: w, height: thumbH)
    }

    // MARK: Draw

    override func draw(_ dirtyRect: NSRect) {
        guard canScroll else { return }
        if hovering || dragging {
            let track = CGRect(x: bounds.width - hoverThumbW - rightPad, y: vInset,
                               width: hoverThumbW, height: trackHeight)
            NSColor.white.withAlphaComponent(0.06).setFill()
            NSBezierPath(roundedRect: track, xRadius: hoverThumbW / 2, yRadius: hoverThumbW / 2).fill()
        }
        let r = thumbRect()
        thumbColor.setFill()
        NSBezierPath(roundedRect: r, xRadius: r.width / 2, yRadius: r.width / 2).fill()
    }

    // MARK: Visibility

    /// Called whenever the terminal scrolls. Reveal when scrolled up into history;
    /// stay out of the way (and skip redraws) while following the bottom.
    func reflectScroll() {
        guard canScroll else { animator().alphaValue = 0; return }
        if atBottom {
            if alphaValue > 0.01, !hovering, !dragging { scheduleHide() }
            return
        }
        needsDisplay = true
        reveal()
    }

    private func reveal() {
        hideTimer?.cancel(); hideTimer = nil
        if alphaValue < 1 { animator().alphaValue = 1 }
    }

    private func scheduleHide() {
        hideTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.hovering, !self.dragging else { return }
            self.animator().alphaValue = 0
        }
        hideTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let ta = NSTrackingArea(rect: bounds,
                                options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                owner: self, userInfo: nil)
        addTrackingArea(ta); tracking = ta
    }

    override func mouseEntered(with event: NSEvent) {
        guard canScroll else { return }
        hovering = true; reveal(); needsDisplay = true
    }
    override func mouseExited(with event: NSEvent) {
        hovering = false; needsDisplay = true
        if atBottom { scheduleHide() }
    }

    // MARK: Drag / click-to-jump

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only intercept clicks in the thumb column while visible, so text
        // selection near the right edge still works when the bar is hidden.
        guard canScroll, alphaValue > 0.05 else { return nil }
        let local = convert(point, from: superview)
        let column = CGRect(x: bounds.width - hoverThumbW - rightPad - 3, y: 0,
                            width: hoverThumbW + rightPad + 3, height: bounds.height)
        return column.contains(local) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        dragging = true; reveal(); scrollToMouse(event)
    }
    override func mouseDragged(with event: NSEvent) { scrollToMouse(event) }
    override func mouseUp(with event: NSEvent) {
        dragging = false; needsDisplay = true
        if atBottom { scheduleHide() }
    }

    private func scrollToMouse(_ event: NSEvent) {
        guard let term else { return }
        let p = convert(event.locationInWindow, from: nil)
        let thumbH = min(trackHeight, max(minThumbH, trackHeight * thumbProp))
        let travel = max(1, trackHeight - thumbH)
        let pos = (p.y - vInset - thumbH / 2) / travel
        term.scroll(toPosition: Double(min(1, max(0, pos))))
        needsDisplay = true
    }
}
