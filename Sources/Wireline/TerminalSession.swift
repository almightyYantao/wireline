import AppKit
import MetalKit
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

/// The SwiftTerm engine: a `TerminalView` that renders what `TerminalIO` feeds
/// it and hands keystrokes back. It adds the app's terminal behaviour on top —
/// prompt-aware reflow (OSC 133), jump-to-prompt / last output, colour-query
/// answers, a themed scrollbar, focus-aware caret, ⌘-click paths, snapshots.
final class WirelineTerminalView: TerminalView, TerminalEngine {
    /// The session's PTY side (for resize flushing and output observation).
    weak var io: TerminalIO?

    /// Bytes for the child: keystrokes, pastes, query replies.
    var onInput: ((ArraySlice<UInt8>) -> Void)?
    /// The grid changed size (the PTY is told, throttled, by `TerminalIO`).
    var onGridResize: (() -> Void)?

    /// Invoked when the user presses ⌘W while this terminal is focused, so the
    /// app can close just this session instead of the whole window.
    var onCloseRequested: (() -> Void)?

    /// Fired when the shell reports its working directory via OSC 7
    /// (`\e]7;file://host/path\a`). The payload is the raw OSC-7 string.
    var onDirectoryChange: ((String?) -> Void)?
    /// A program-set window title (OSC 0/2).
    var onTitleReport: ((String) -> Void)?

    /// Opaque background for the IME marked-text (composition) overlay. SwiftTerm
    /// styles that floating preview with `nativeBackgroundColor`, which is
    /// transparent here — so hand the overlay a real, opaque theme colour.
    var markedTextBackground: NSColor = NSColor(srgbRed: 0.11, green: 0.12, blue: 0.14, alpha: 1)

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Default SwiftTerm scrollback is 500 lines; deepen it so cross-launch
        // restore (and in-session scrollback) keeps a meaningful amount of history.
        getTerminal().changeScrollback(4000)
        if let font = TerminalFont.preferred(size: 13) { self.font = font }
        // Green-on-black to match the app's console theme.
        nativeBackgroundColor = NSColor(red: 0.039, green: 0.055, blue: 0.039, alpha: 1)
        nativeForegroundColor = NSColor(red: 0.78, green: 0.83, blue: 0.78, alpha: 1)
        caretColor = NSColor(red: 0.20, green: 0.82, blue: 0.50, alpha: 1)
        // `terminalDelegate` is weak, hence the strong hold.
        let bridge = SwiftTermBridge(owner: self)
        self.bridge = bridge
        terminalDelegate = bridge
        installPromptTracking()
        // SwiftTerm swaps any cursor for a thick hollow box when unfocused; we
        // keep the shape and fade the colour instead (see refreshCaretFocus).
        caretViewTracksFocus = false
    }

    private var bridge: SwiftTermBridge?

    // MARK: TerminalEngine

    func feed(_ bytes: ArraySlice<UInt8>) { feed(byteArray: bytes) }
    /// SwiftTerm reflows on the main thread: `TerminalIO` throttles the PTY.
    var coalescesResize: Bool { false }

    var gridSize: winsize {
        let t = getTerminal()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        let cell = cellSize
        return winsize(ws_row: UInt16(t.rows), ws_col: UInt16(t.cols),
                       ws_xpixel: UInt16(clamping: Int(cell.width * CGFloat(t.cols) * scale)),
                       ws_ypixel: UInt16(clamping: Int(cell.height * CGFloat(t.rows) * scale)))
    }

    /// One cell, in points (same formula SwiftTerm lays the grid out with).
    private var cellSize: CGSize {
        let t = getTerminal()
        guard t.rows > 0 else { return .zero }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let w = ceil(font.advancement(forGlyph: font.glyph(withName: "W")).width * scale) / scale
        return CGSize(width: w, height: getOptimalFrameSize().height / CGFloat(t.rows))
    }

    // MARK: Cursor focus

    /// The theme's cursor colour; shown at full strength only while focused.
    private var baseCaretColor = NSColor(red: 0.20, green: 0.82, blue: 0.50, alpha: 1)
    private var focusObservers: [NSObjectProtocol] = []
    private var responderObservation: NSKeyValueObservation?

    func setCaretColor(_ color: NSColor) {
        baseCaretColor = color
        refreshCaretFocus()
    }

    /// Focused = key window + first responder. Unfocused keeps the shape at
    /// 35% so you can still see where it is, like Terminal.app / Ghostty.
    private func refreshCaretFocus() {
        let focused = window?.isKeyWindow == true && window?.firstResponder === self
        let c = focused ? baseCaretColor : baseCaretColor.withAlphaComponent(0.35)
        guard caretColor != c else { return }
        caretColor = c
        // The Metal renderer reads the colour per frame; ask it for one.
        for case let v as MTKView in subviews { v.setNeedsDisplay(v.bounds) }
    }

    private func observeFocus() {
        focusObservers.forEach(NotificationCenter.default.removeObserver)
        focusObservers = []
        responderObservation = nil
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            focusObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.refreshCaretFocus() }
            })
        }
        responderObservation = window.observe(\.firstResponder, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.refreshCaretFocus() }
        }
        refreshCaretFocus()
    }

    // MARK: Prompt-aware resizing (OSC 133)
    //
    // The kitty / Ghostty technique. A shell integration (p10k with
    // POWERLEVEL9K_TERM_SHELL_INTEGRATION=true, or our local zsh hook) marks the
    // prompt start with OSC 133;A. Right before the grid reflows we blank
    // everything from that mark to the end of the screen, leaving the cursor
    // where it was. Blank lines don't grow when reflowed, so the distance zsh
    // remembers between prompt start and cursor stays true, and its SIGWINCH
    // redraw lands exactly on the old prompt instead of stacking a copy below
    // it. See powerlevel10k's README, "Horrific mess when resizing terminal window".

    private enum PromptRedraw { case full, last, none }
    /// Absolute row of the current prompt's start; nil while a command runs.
    private var promptStartRow: Int?
    private var promptRedraw: PromptRedraw = .full
    /// Set while a resize burst has blanked the prompt: prompt-start → cursor rows.
    private var promptClearOffset: Int?

    private var absoluteCursorRow: Int {
        let b = getTerminal().buffer
        return b.totalLinesTrimmed + b.yDisp + b.y
    }

    /// The view is showing the live bottom (not scrolled back into history),
    /// so `yDisp` is the buffer base and row maths is valid.
    private var showingLiveBottom: Bool { !canScroll || scrollPosition >= 0.999 }

    private func installPromptTracking() {
        getTerminal().registerOscHandler(code: 133) { [weak self] data in
            // SwiftTerm feeds PTY output on the main queue.
            MainActor.assumeIsolated { self?.handlePromptMark(String(decoding: data, as: UTF8.self)) }
        }
        for code in [10, 11] {
            getTerminal().registerOscHandler(code: code) { [weak self] data in
                MainActor.assumeIsolated { self?.answerColorQuery(code: code, String(decoding: data, as: UTF8.self)) }
            }
        }
    }

    // MARK: Colour queries (OSC 10 / 11)

    /// The theme's real foreground / background (0…1 RGB). The view itself
    /// paints a clear background so the wallpaper shows through, and SwiftTerm
    /// would answer a background query with that — i.e. black — making bat,
    /// vim, delta, fzf … pick dark palettes on a light theme.
    var reportedColors: (fg: [Double], bg: [Double])?

    /// Answer `OSC 10;?` / `OSC 11;?` (and the `10;?;?` form, which asks for
    /// foreground then background) like xterm: `ESC ] 1x ; rgb:RRRR/GGGG/BBBB ST`.
    /// Requests to *set* the colours are ignored — the theme owns them.
    private func answerColorQuery(code: Int, _ payload: String) {
        guard let colors = reportedColors else { return }
        for (offset, part) in payload.split(separator: ";", omittingEmptySubsequences: false).enumerated()
        where part == "?" {
            let which = code + offset
            guard which == 10 || which == 11 else { continue }
            let c = which == 10 ? colors.fg : colors.bg
            func hex(_ v: Double) -> String { String(format: "%04x", Int((min(max(v, 0), 1) * 65535).rounded())) }
            send(txt: "\u{1b}]\(which);rgb:\(hex(c[0]))/\(hex(c[1]))/\(hex(c[2]))\u{1b}\\")
        }
    }

    private func handlePromptMark(_ payload: String) {
        let parts = payload.split(separator: ";").map(String.init)
        guard let kind = parts.first else { return }
        switch kind {
        case "A":
            guard showingLiveBottom else { promptStartRow = nil; return }
            promptStartRow = absoluteCursorRow
            promptRedraw = .full
            for opt in parts.dropFirst() where opt.hasPrefix("redraw=") {
                switch opt.dropFirst("redraw=".count) {
                case "0": promptRedraw = .none
                case "last": promptRedraw = .last
                default: promptRedraw = .full
                }
            }
            recordPrompt(at: absoluteCursorRow)
        case "C":
            promptStartRow = nil
            if let i = commands.indices.last, commands[i].outputStart == nil {
                // Output begins on the line after the command line.
                commands[i].outputStart = absoluteCursorRow + 1
            }
        case "D":
            promptStartRow = nil
            if let i = commands.indices.last, commands[i].outputStart != nil, commands[i].outputEnd == nil {
                commands[i].outputEnd = absoluteCursorRow
            }
        default:
            break
        }
    }

    // MARK: Command history (OSC 133) — jump to prompt, copy last output

    /// One shell command as the marks describe it, in absolute buffer rows.
    struct CommandRecord {
        var prompt: Int
        var outputStart: Int?
        var outputEnd: Int?
    }
    private(set) var commands: [CommandRecord] = []

    private func recordPrompt(at row: Int) {
        // A redraw of the same prompt (SIGWINCH, reset-prompt) re-sends A —
        // move the open record instead of starting a new one.
        if let i = commands.indices.last, commands[i].outputStart == nil {
            commands[i].prompt = row
        } else {
            if let i = commands.indices.last, commands[i].outputEnd == nil {
                commands[i].outputEnd = row          // shell without D marks
            }
            commands.append(CommandRecord(prompt: row))
        }
        let top = getTerminal().buffer.totalLinesTrimmed
        commands.removeAll { $0.prompt < top }
        if commands.count > 2000 { commands.removeFirst(commands.count - 2000) }
    }

    /// Shift every record by `delta` rows. A reflow moves rows by varying
    /// amounts; anchoring on the live prompt (whose position we know exactly)
    /// keeps recent commands right and older ones close.
    private func shiftCommands(by delta: Int) {
        guard delta != 0 else { return }
        for i in commands.indices {
            commands[i].prompt += delta
            commands[i].outputStart = commands[i].outputStart.map { $0 + delta }
            commands[i].outputEnd = commands[i].outputEnd.map { $0 + delta }
        }
    }

    /// Scroll so the previous / next prompt is at the top (Ghostty's
    /// jump_to_prompt). Returns false when there's no prompt that way.
    @discardableResult
    func jumpToPrompt(_ delta: Int) -> Bool {
        let b = getTerminal().buffer
        let topAbs = b.totalLinesTrimmed + b.yDisp
        let rows = commands.map(\.prompt)
        let target = delta < 0 ? rows.last { $0 < topAbs } : rows.first { $0 > topAbs }
        guard let target else {
            if delta > 0 { scrollTo(row: Int.max) }      // past the last prompt: back to live
            return false
        }
        scrollTo(row: target - b.totalLinesTrimmed)
        return true
    }

    func cursorLine() -> TerminalCursorLine? {
        let t = getTerminal()
        guard !t.isCurrentBufferAlternate, scrollPosition >= 1 || !canScroll else { return nil }
        let (x, y) = t.getCursorLocation()
        guard let line = t.getLine(row: y) else { return nil }
        return TerminalCursorLine(row: y,
                                  before: line.translateToString(endCol: x, skipNullCellsFollowingWide: true),
                                  after: line.translateToString(trimRight: true, startCol: x, skipNullCellsFollowingWide: true))
    }

    /// Text of the most recent finished command's output, trailing blanks trimmed.
    func lastCommandOutput() -> String? {
        let t = getTerminal()
        guard let rec = commands.last(where: { $0.outputStart != nil && $0.outputEnd != nil }),
              let start = rec.outputStart, let end = rec.outputEnd, end > start else { return nil }
        var lines: [String] = []
        for row in start..<end {
            guard let line = t.getScrollInvariantLine(row: row) else { continue }
            lines.append(line.translateToString(trimRight: true))
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        let text = lines.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    override func setFrameSize(_ newSize: NSSize) {
        // Only when the grid really changes: the kernel sends SIGWINCH only for a
        // new rows×cols, and a blanked prompt with no redraw coming would stay
        // blank (sub-cell size changes are common at the tail of a spring).
        if newSize != frame.size, let g = predictedGrid(for: newSize) {
            let t = getTerminal()
            if g.cols != t.cols || g.rows != t.rows { blankPromptBeforeReflow() }
        }
        super.setFrameSize(newSize)
    }

    /// The rows×cols SwiftTerm will pick for `size`, using its own formula
    /// (pixel-snapped "W" advance; row height from the optimal frame). Returns
    /// nil unless the formula reproduces the *current* grid exactly — then we'd
    /// rather not blank than blank wrongly.
    private func predictedGrid(for size: NSSize) -> (cols: Int, rows: Int)? {
        let t = getTerminal()
        guard t.cols > 0, t.rows > 0, frame.width > 0, frame.height > 0, size.width > 0 else { return nil }
        let optimal = getOptimalFrameSize()
        let cellH = optimal.height / CGFloat(t.rows)
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let rawW = font.advancement(forGlyph: font.glyph(withName: "W")).width
        let cellW = ceil(rawW * scale) / scale
        guard cellW > 0, cellH > 0 else { return nil }
        let reserved = optimal.width - cellW * CGFloat(t.cols)
        func grid(_ s: NSSize) -> (cols: Int, rows: Int) {
            (Int(max(0, s.width - reserved) / cellW), Int(s.height / cellH))
        }
        let now = grid(frame.size)
        guard now.cols == t.cols, now.rows == t.rows else { return nil }
        return grid(size)
    }

    /// Called after every chunk of output is rendered, while set (lives on the
    /// IO side, which sees every chunk).
    var outputObserver: (() -> Void)? {
        get { io?.outputObserver }
        set { io?.outputObserver = newValue }
    }

    /// Send a pending throttled size to the PTY now. True if one was pending.
    @discardableResult
    func flushPendingResize() -> Bool { io?.flushPendingResize() ?? false }

    private func blankPromptBeforeReflow() {
        guard promptClearOffset == nil, let start = promptStartRow, promptRedraw != .none,
              !getTerminal().isCurrentBufferAlternate, showingLiveBottom else { return }
        var k = absoluteCursorRow - start
        guard k >= 0, k < getTerminal().rows else { return }
        if promptRedraw == .last { k = 0 }
        // Save cursor, go to the prompt's first line, erase to end of screen,
        // restore cursor. Fed to the emulator only — nothing reaches the PTY.
        getTerminal().feed(text: "\u{1b}7" + (k > 0 ? "\u{1b}[\(k)A" : "") + "\r\u{1b}[J\u{1b}8")
        promptClearOffset = k
    }

    /// Called once the debounced size has gone to the PTY: the reflow is done,
    /// so re-anchor the prompt start from the (unchanged) prompt→cursor distance.
    func didDeliverResize() {
        guard let k = promptClearOffset else { return }
        promptClearOffset = nil
        if let old = promptStartRow, showingLiveBottom {
            promptStartRow = absoluteCursorRow - k
            shiftCommands(by: (absoluteCursorRow - k) - old)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Intercept the "close shell" shortcut so it closes this session rather
        // than the containing window. The binding is user-customizable.
        // AppKit offers key equivalents to *every* view in the window, front to
        // back — not just the focused one — so with split panes the first pane
        // in the hierarchy would grab ⌘W and close itself. Only the pane that
        // has keyboard focus answers; if focus is elsewhere (AI panel, sidebar),
        // the active pane does.
        if event.type == .keyDown,
           KeyBindingStore.shared.shortcut(for: .closeShell).matches(event) {
            let focusedTerminal = window?.firstResponder as? any TerminalEngine
            let mine = focusedTerminal.map { $0 === self } ?? (isActivePane?() ?? true)
            guard mine else { return super.performKeyEquivalent(with: event) }
            onCloseRequested?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Whether this view's session is the active pane (set by the session).
    var isActivePane: (() -> Bool)?

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
        onScrollChange?()
    }

    /// A user scroll (wheel / drag / `scrollTo`), via the delegate bridge.
    fileprivate func userScrolled() { onScrollChange?() }

    // MARK: - Scrollbar

    /// Tells the themed `TerminalScrollbar` (hosted by `TerminalContainerView`)
    /// to re-read `canScroll` / `scrollPosition` / `scrollThumbsize`.
    var onScrollChange: (() -> Void)?

    /// SwiftTerm's built-in overlay `NSScroller` (hidden — `TerminalScrollbar`
    /// is drawn instead).
    private weak var nativeScroller: NSScroller?

    private func hideNativeScroller() {
        if nativeScroller == nil {
            nativeScroller = subviews.compactMap { $0 as? NSScroller }.first
        }
        nativeScroller?.isHidden = true
    }

    override func layout() {
        super.layout()
        // Keep SwiftTerm's scroller hidden even if it re-appears after a relayout.
        nativeScroller?.isHidden = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hideNativeScroller()
        // Moving windows rebuilds SwiftTerm's Metal view — re-clear it.
        makeMetalLayerTransparent()
        observeFocus()
    }

    // MARK: Appearance

    /// The cursor setting last pushed in — re-applied only when the setting
    /// itself changes, so a redraw never undoes a shape the running program
    /// chose (vim's insert-mode bar).
    private var appliedCursor: (CursorShape, Bool)?

    func applyAppearance(_ a: TerminalAppearance) {
        // Colour scheme (ANSI palette + fg/cursor).
        installColors(a.theme.ansiTermColors)
        nativeForegroundColor = a.theme.foregroundNS
        setCaretColor(a.theme.cursorNS)
        // The IME composition overlay can't use the (transparent) native
        // background, so give it the theme's real, opaque background.
        markedTextBackground = a.theme.backgroundNS
        if font != a.font { font = a.font }
        // Renderer: Metal (GPU) or CoreGraphics.
        applyRenderer(gpu: a.gpu)

        if appliedCursor.map({ $0 != (a.cursorShape, a.cursorBlink) }) ?? true {
            appliedCursor = (a.cursorShape, a.cursorBlink)
            let style: CursorStyle = switch (a.cursorShape, a.cursorBlink) {
            case (.block, true): .blinkBlock
            case (.block, false): .steadyBlock
            case (.bar, true): .blinkBar
            case (.bar, false): .steadyBar
            case (.underline, true): .blinkUnderline
            case (.underline, false): .steadyUnderline
            }
            getTerminal().setCursorStyle(style)
        }

        // The app-wide wallpaper sits behind everything; the terminal adds no
        // tint of its own. Keep the theme's RGB but paint it fully transparent
        // (`backgroundOpacity`): faint (SGR 2) text still blends towards the
        // real theme background, and there's no glyph halo.
        wantsLayer = true
        layer?.isOpaque = false
        nativeBackgroundColor = a.theme.backgroundNS
        backgroundOpacity = 0
        layer?.backgroundColor = NSColor.clear.cgColor
        // Programs that ask (OSC 10/11) get the theme's real colours.
        reportedColors = (a.theme.foreground, a.theme.background)
    }

    // MARK: GPU rendering

    /// Switch between SwiftTerm's Metal renderer and CoreGraphics. Falls back to
    /// CoreGraphics silently if Metal can't start.
    func applyRenderer(gpu: Bool) {
        guard gpu != isUsingMetalRenderer else { return }
        // SwiftTerm loads its shaders from its resource bundle and traps if it's
        // missing — check first and stay on CoreGraphics instead of crashing.
        if gpu, !Self.hasSwiftTermResources { return }
        try? setUseMetal(gpu)
        makeMetalLayerTransparent()
    }

    private static let hasSwiftTermResources =
        Bundle.main.url(forResource: "SwiftTerm_SwiftTerm", withExtension: "bundle") != nil

    /// SwiftTerm's MTKView is opaque by default; we draw over the app wallpaper
    /// with a clear background, so let the layer composite with alpha.
    private func makeMetalLayerTransparent() {
        guard isUsingMetalRenderer else { return }
        for case let v as MTKView in subviews {
            v.layer?.isOpaque = false
        }
    }

    /// An image of the current screen. `cacheDisplay` can't read a Metal layer,
    /// so under Metal this briefly draws one frame with CoreGraphics — callers
    /// take it while the terminal is about to be covered anyway.
    func snapshotImage() -> NSImage? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let metal = isUsingMetalRenderer
        if metal { try? setUseMetal(false) }
        defer { if metal { try? setUseMetal(true); makeMetalLayerTransparent() } }
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }

    // MARK: ⌘-click paths

    /// Asked to open a file path ⌘-clicked in the terminal (URLs are SwiftTerm's).
    var onOpenPath: ((String) -> Void)?

    var onPasteImage: ((Data) -> Bool)?

    var contextMenuItems: (() -> [WLMenuItem])?

    override func menu(for event: NSEvent) -> NSMenu? { contextMenuItems.map { NSMenu.wl($0()) } }

    override func paste(_ sender: Any) {
        if let png = ImagePaste.png(), onPasteImage?(png) == true { return }
        let bracketed = getTerminal().bracketedPasteMode
        guard let text = NSPasteboard.general.string(forType: .string),
              PasteConfirmPolicy.current.shouldAsk(text, bracketed: bracketed)
        else { return super.paste(sender) }
        PasteConfirmCenter.shared.ask(text, from: self) { [weak self] choice in
            guard let self, choice != .cancel else { return }
            // What SwiftTerm's own paste sends: newlines as CR, bracketed when asked.
            var body = choice == .singleLine ? PasteConfirmCenter.singleLine(text) : text
            body = body.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
            let bracketedNow = self.getTerminal().bracketedPasteMode
            self.send(txt: bracketedNow ? "\u{1b}[200~" + body + "\u{1b}[201~" : body)
        }
    }

    /// A click landed in this pane: make it the active split.
    var onClickFocus: (() -> Void)?

    /// Never fired: OSC 133 here feeds prompt tracking only, and the session
    /// uses `TerminalIO`'s output heuristic for busy / finished.
    var onShellCommand: ((ShellCommandEvent) -> Void)?

    // SwiftTerm's mouseDown doesn't take first responder, and the click never
    // reaches SwiftUI gestures over this AppKit view — focus the pane here.
    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        onClickFocus?()
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.clickCount == 1,
           let token = pathToken(at: convert(event.locationInWindow, from: nil)) {
            onOpenPath?(token)
            return
        }
        super.mouseUp(with: event)
    }

    /// The path-looking word under `point`, or nil (URLs excluded — SwiftTerm
    /// opens those itself).
    private func pathToken(at point: NSPoint) -> String? {
        let t = getTerminal()
        guard t.rows > 0 else { return nil }
        let optimal = getOptimalFrameSize()
        let cellH = optimal.height / CGFloat(t.rows)
        let scale = window?.backingScaleFactor ?? 2
        let cellW = ceil(font.advancement(forGlyph: font.glyph(withName: "W")).width * scale) / scale
        guard cellW > 0, cellH > 0 else { return nil }
        let y = isFlipped ? point.y : bounds.height - point.y
        let row = Int(y / cellH), col = Int(point.x / cellW)
        guard row >= 0, row < t.rows, let line = t.getLine(row: row) else { return nil }
        return TerminalPathToken.token(in: Array(line.translateToString(trimRight: false)), at: col)
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
            field.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.14).cgColor
        }
    }

    /// The full buffer (scrollback + screen) serialized WITH colors and styles,
    /// for cross-launch scrollback restore. Read on demand at save time. Returns
    /// empty while a full-screen app owns the alternate screen (see
    /// `serializeColored`), so callers should keep the prior snapshot in that case.
    var renderedBuffer: Data { getTerminal().serializeColored() }
}

/// A themed, self-drawn overlay scrollbar for the terminal, replacing SwiftTerm's
/// native `NSScroller` (and standing in for the one libghostty leaves to the
/// app). A thin rounded green thumb that:
///  - stays hidden while you're following the bottom (no streaming jitter),
///  - reveals on scroll / hover and fades out again shortly after,
///  - widens on hover, and is draggable / click-to-jump.
///
/// It reads the engine's `TerminalScrollable` state and drives scrolling via
/// `scroll(toPosition:)`. `TerminalContainerView` hosts it as a sibling over
/// the terminal (libghostty's view is layer-hosting: no subviews in there)
/// and calls `reflectScroll()` from the engine's `onScrollChange`.
final class TerminalScrollbar: NSView {
    weak var term: (any TerminalScrollable)?

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
            NSColor.labelColor.withAlphaComponent(0.06).setFill()
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
    // A sibling, not a subview: hand the terminal what the column doesn't use.
    override func scrollWheel(with event: NSEvent) { (term as? NSView)?.scrollWheel(with: event) }
    override func rightMouseDown(with event: NSEvent) { (term as? NSView)?.rightMouseDown(with: event) }
    override func rightMouseUp(with event: NSEvent) { (term as? NSView)?.rightMouseUp(with: event) }
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

/// SwiftTerm's view delegate, as a standalone non-isolated object (the
/// protocol isn't main-actor; SwiftTerm calls it on the main thread). Routes
/// input to the PTY side and reports grid / title / directory changes.
final class SwiftTermBridge: TerminalViewDelegate {
    private weak var owner: WirelineTerminalView?
    init(owner: WirelineTerminalView) { self.owner = owner }

    private func onMain(_ body: @MainActor (WirelineTerminalView) -> Void) {
        guard let owner else { return }
        MainActor.assumeIsolated { body(owner) }
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        onMain { $0.onGridResize?() }
    }
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        onMain { $0.onInput?(data) }
    }
    // Program-set window titles aren't used as the tab title, but an SSH
    // session mines them for the remote directory (applyReportedTitle).
    func setTerminalTitle(source: TerminalView, title: String) {
        onMain { $0.onTitleReport?(title) }
    }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        onMain { $0.onDirectoryChange?(directory) }
    }
    func scrolled(source: TerminalView, position: Double) {
        onMain { $0.userScrolled() }
    }
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        TerminalView.openDefaultLink(link)
    }
    func bell(source: TerminalView) { NSSound.beep() }
    // OSC 52: programs (tmux, vim) may set and read the clipboard.
    func clipboardCopy(source: TerminalView, content: Data) {
        guard let str = String(bytes: content, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([str as NSString])
    }
    func clipboardRead(source: TerminalView) -> Data? {
        NSPasteboard.general.string(forType: .string)?.data(using: .utf8)
    }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
