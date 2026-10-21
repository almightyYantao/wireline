// The surface view is ported from Ghostty's macOS app
// (macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift, Ghostty.Surface.swift),
// Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors. MIT License — see LICENSE-ghostty.

import AppKit
import GhosttyKit
import IOSurface
import struct SwiftTerm.SearchOptions

/// Owns a `ghostty_surface_t` (Ghostty.Surface's pattern): freed on the main
/// thread when the last reference goes, whichever thread that happens on.
final class GhosttySurfaceHandle: Sendable {
    nonisolated(unsafe) let raw: ghostty_surface_t
    init(_ raw: ghostty_surface_t) { self.raw = raw }
    deinit {
        if Thread.isMainThread { ghostty_surface_free(raw); return }
        nonisolated(unsafe) let raw = raw
        Task.detached { @MainActor in ghostty_surface_free(raw) }
    }
}

/// The libghostty engine: a layer-hosting NSView whose IOSurface libghostty's
/// Metal renderer draws into. Input, focus, mouse and IME follow Ghostty's
/// own SurfaceView; the byte stream goes through `GhosttyIO` so `TerminalIO`
/// keeps owning the PTY. Behaviour matches `WirelineTerminalView` where the
/// app relies on it (caret dimming, ⌘W, click focus, ⌘-click paths,
/// transparent background over the wallpaper, snapshots).
final class GhosttyTerminalView: NSView, TerminalEngine {
    /// libghostty draws an unfocused surface's cursor as a hollow block,
    /// whatever its style. The SwiftTerm view keeps the shape at 35%; to match,
    /// the surface is always told it's focused and the real focus picks a
    /// dimmed, non-blinking config instead. Focus reports (DECSET 1004) are
    /// then synthesized by `GhosttyIO`. False = libghostty's own behaviour.
    static let keepsCaretShapeWhenUnfocused = true

    /// Whether sessions may use this engine: libghostty started, and this
    /// GhosttyKit can leave the PTY to `TerminalIO` (manual IO).
    static var isAvailable: Bool { GhosttyIO.supportsManualIO && GhosttyRuntime.shared.start() }

    // MARK: TerminalEngine state

    weak var io: TerminalIO?
    var onInput: ((ArraySlice<UInt8>) -> Void)?
    var onGridResize: (() -> Void)?
    var onCloseRequested: (() -> Void)?
    var onDirectoryChange: ((String?) -> Void)?
    var onTitleReport: ((String) -> Void)?
    var onOpenPath: ((String) -> Void)?
    var onClickFocus: (() -> Void)?
    var isActivePane: (() -> Bool)?

    /// Off while an overlay covers the terminal: no mouse events reach the
    /// surface (so TUIs don't see the pointer), and it's told the pointer left.
    var allowMouseReporting = true {
        didSet {
            guard oldValue, !allowMouseReporting, let s = surface?.raw else { return }
            ghostty_surface_mouse_pos(s, -1, -1, GHOSTTY_MODS_NONE)
        }
    }

    var outputObserver: (() -> Void)? {
        get { io?.outputObserver }
        set { io?.outputObserver = newValue }
    }

    // MARK: Engine extras (harness, later features)

    /// OSC 133 command-finished reports (exit code, seconds).
    var onCommandFinished: ((Int?, Double) -> Void)?
    /// `.exec` mode: libghostty's child exited / the surface wants to close.
    var onChildExited: (() -> Void)?
    /// Last scrollbar state from libghostty (rows: total, first visible, visible).
    private(set) var scrollbar: (total: UInt64, offset: UInt64, length: UInt64)?
    /// The URL under the pointer while ⌘ is held.
    private(set) var hoveredLink: String?

    // MARK: Surface

    let ioGlue: GhosttyIO
    private(set) var surface: GhosttySurfaceHandle?
    private let id: Int
    private var terminalAppearance: TerminalAppearance?

    init(frame: CGRect, mode: GhosttyIOMode = .manual) {
        id = GhosttyRuntime.shared.makeID()
        ioGlue = GhosttyIO(mode: mode)
        super.init(frame: frame.width > 0 && frame.height > 0 ? frame : CGRect(x: 0, y: 0, width: 800, height: 480))
        ioGlue.view = self
        GhosttyRuntime.shared.register(self, id: id)
        guard GhosttyRuntime.shared.start(), let app = GhosttyRuntime.shared.app else { return }

        var cfg = ghostty_surface_config_new()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque()))
        cfg.userdata = UnsafeMutableRawPointer(bitPattern: id)
        cfg.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)
        cfg.font_size = 0                     // the config's font-size
        cfg.context = GHOSTTY_SURFACE_CONTEXT_WINDOW
        // libghostty makes this view layer-hosting (its IOSurfaceLayer, then
        // wantsLayer) — so nothing here touches `layer` / `wantsLayer` first.
        guard let raw = ioGlue.withSurfaceConfig(&cfg, { ghostty_surface_new(app, &$0) }) else {
            ghosttyLog.error("ghostty_surface_new failed")
            return
        }
        surface = GhosttySurfaceHandle(raw)
        if Self.keepsCaretShapeWhenUnfocused { ghostty_surface_set_focus(raw, true) }
        pushSize()
        updateTrackingAreas()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    @discardableResult
    func binding(_ action: String) -> Bool {
        guard let s = surface?.raw else { return false }
        return action.withCString { ghostty_surface_binding_action(s, $0, UInt(strlen($0))) }
    }

    // MARK: Byte plumbing

    func feed(_ bytes: ArraySlice<UInt8>) { ioGlue.feed(bytes) }
    func feed(text: String) { ioGlue.feed(ArraySlice(Array(text.utf8))) }
    func send(txt: String) { ioGlue.sendToChild(Array(txt.utf8)) }
    func didDeliverResize() {}   // libghostty handles prompt redraw on resize (OSC 133) itself
    @discardableResult func flushPendingResize() -> Bool { io?.flushPendingResize() ?? false }

    var gridSize: winsize {
        guard let s = surface?.raw else { return winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0) }
        let size = ghostty_surface_size(s)
        return winsize(ws_row: size.rows, ws_col: size.columns,
                       ws_xpixel: UInt16(clamping: UInt32(size.columns) * size.cell_width_px),
                       ws_ypixel: UInt16(clamping: UInt32(size.rows) * size.cell_height_px))
    }

    /// One cell in points.
    var cellSize: CGSize {
        guard let s = surface?.raw else { return .zero }
        let size = ghostty_surface_size(s)
        return CGSize(width: CGFloat(size.cell_width_px) / backingScale, height: CGFloat(size.cell_height_px) / backingScale)
    }

    // MARK: Size and scale

    private var backingScale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }
    private var lastGrid: (cols: UInt16, rows: UInt16) = (0, 0)

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        pushSize()
    }

    /// The framebuffer size goes to libghostty; a new rows×cols goes to the
    /// PTY (via `onGridResize` → `TerminalIO`, throttled).
    private func pushSize() {
        guard let s = surface?.raw, frame.width >= 1, frame.height >= 1 else { return }
        let scale = backingScale
        ghostty_surface_set_size(s, UInt32(frame.width * scale), UInt32(frame.height * scale))
        checkGrid()
    }

    private func checkGrid() {
        guard let s = surface?.raw else { return }
        let size = ghostty_surface_size(s)
        guard size.columns != lastGrid.cols || size.rows != lastGrid.rows else { return }
        lastGrid = (size.columns, size.rows)
        onGridResize?()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateScale()
    }

    private func updateScale() {
        guard let window else { return }
        // We render at the right scale ourselves; stop the compositor rescaling.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contentsScale = window.backingScaleFactor
        CATransaction.commit()
        guard let s = surface?.raw else { return }
        ghostty_surface_set_content_scale(s, window.backingScaleFactor, window.backingScaleFactor)
        pushSize()
    }

    // MARK: Window, focus, occlusion

    private var windowObservers: [NSObjectProtocol] = []
    private var responderObservation: NSKeyValueObservation?
    /// Key window + first responder.
    private(set) var isFocused = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = []
        responderObservation = nil
        guard let window else { refreshFocus(); return }
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            windowObservers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshFocus() }
            })
        }
        windowObservers.append(center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                  object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateOcclusion() }
        })
        windowObservers.append(center.addObserver(forName: NSWindow.didChangeScreenNotification,
                                                  object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateScreen() }
        })
        responderObservation = window.observe(\.firstResponder, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.refreshFocus() } }
        }
        updateScreen()
        updateOcclusion()
        refreshFocus()
    }

    private func updateScreen() {
        if let s = surface?.raw,
           let n = window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            ghostty_surface_set_display_id(s, n.uint32Value)
        }
        updateScale()
    }

    private func updateOcclusion() {
        guard let s = surface?.raw else { return }
        ghostty_surface_set_occlusion(s, window?.occlusionState.contains(.visible) ?? false)
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.refreshFocus() } } }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.refreshFocus() } } }
        return ok
    }

    private func refreshFocus() {
        let focused = window?.isKeyWindow == true && window?.firstResponder === self
        guard focused != isFocused else { return }
        isFocused = focused
        guard let s = surface?.raw else { return }
        if Self.keepsCaretShapeWhenUnfocused {
            applyConfig()
            ioGlue.focusChanged(focused, synthesizeReports: true)
        } else {
            ghostty_surface_set_focus(s, focused)
        }
    }

    // MARK: Appearance

    func applyAppearance(_ a: TerminalAppearance) {
        // SwiftUI re-applies on every update; only a real change costs a config.
        // (`gpu` doesn't apply: libghostty always renders with Metal.)
        guard a != terminalAppearance else { return }
        terminalAppearance = a
        applyConfig()
    }

    private func applyConfig() {
        guard let s = surface?.raw, let appearance = terminalAppearance else { return }
        let focused = Self.keepsCaretShapeWhenUnfocused ? isFocused : true
        guard let config = GhosttyRuntime.shared.config(for: appearance, focused: focused) else { return }
        ghostty_surface_update_config(s, config)
        checkGrid()   // a font change moves the grid
    }

    // MARK: Snapshot

    /// The last rendered frame, alpha intact, read straight from the IOSurface
    /// libghostty presents (`cacheDisplay` can't see layer contents, and loses
    /// the transparency anyway).
    func snapshotImage() -> NSImage? {
        guard bounds.width > 0, bounds.height > 0,
              let contents = layer?.contents, CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID() else { return nil }
        let surface = unsafeBitCast(contents as AnyObject, to: IOSurfaceRef.self)
        IOSurfaceLock(surface, .readOnly, nil)
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let scale = backingScale
        let width = min(IOSurfaceGetWidth(surface), Int(bounds.width * scale))
        let height = min(IOSurfaceGetHeight(surface), Int(bounds.height * scale))
        let rowBytes = IOSurfaceGetBytesPerRow(surface)
        guard width > 0, height > 0 else { return nil }
        // Top-left gravity: the view's frame is the surface's first rows.
        let data = Data(bytes: IOSurfaceGetBaseAddress(surface), count: rowBytes * height)
        guard let provider = CGDataProvider(data: data as CFData),
              let space = CGColorSpace(name: CGColorSpace.displayP3),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: rowBytes, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                                      | CGImageAlphaInfo.premultipliedFirst.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale))
    }

    // MARK: Content

    @discardableResult
    func jumpToPrompt(_ delta: Int) -> Bool { binding("jump_to_prompt:\(delta)") }

    func lastCommandOutput() -> String? { ioGlue.lastCommandOutput() }

    /// Scrollback + screen as SGR-coloured text with CRLFs — Ghostty's VT
    /// export (`write_screen_file:copy,vt`), whose "copy" of the file path is
    /// intercepted instead of reaching the pasteboard. Empty on the alternate
    /// screen, like the SwiftTerm view.
    var renderedBuffer: Data {
        guard surface != nil, !ioGlue.alternateScreen else { return Data() }
        var path: String?
        GhosttyRuntime.shared.clipboardCapture = { path = $0 }
        binding("write_screen_file:copy,vt")
        GhosttyRuntime.shared.clipboardCapture = nil
        guard let path else { return Data() }
        let url = URL(fileURLWithPath: path)
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        guard var data = try? Data(contentsOf: url) else { return Data() }
        // The export opens by *setting* the default colours (OSC 10/11);
        // replayed on restore that would override the theme. Drop them.
        while data.starts(with: [0x1B, 0x5D, 0x31]),   // ESC ] 1
              let st = data.firstRange(of: Data([0x1B, 0x5C])) ?? data.firstRange(of: Data([0x07])) {
            data.removeSubrange(data.startIndex..<st.upperBound)
        }
        return data
    }

    // MARK: Search
    //
    // Ghostty's search is a literal, ASCII case-insensitive substring search
    // on a background thread: `options.caseSensitive` / `.regex` are ignored,
    // and match counts arrive asynchronously (SEARCH_TOTAL / SEARCH_SELECTED)
    // — `ghosttySearchDidUpdate` tells the find bar to re-read the summary.

    private var searchNeedle: String?
    private var searchTotal: Int?
    private var searchSelected: Int?

    func findNext(_ term: String, options: SearchOptions, scrollToResult: Bool) -> Bool { search(term, "next") }
    func findPrevious(_ term: String, options: SearchOptions, scrollToResult: Bool) -> Bool { search(term, "previous") }

    private func search(_ term: String, _ direction: String) -> Bool {
        guard !term.isEmpty else { clearSearch(); return false }
        if searchNeedle != term {
            searchNeedle = term
            searchTotal = nil
            searchSelected = nil
            binding("search:\(term)")
        }
        binding("navigate_search:\(direction)")
        return searchTotal.map { $0 > 0 } ?? true
    }

    func searchMatchSummary(_ term: String, options: SearchOptions, limit: Int) -> (index: Int, total: Int) {
        guard term == searchNeedle else { return (0, 0) }
        return (searchSelected.map { $0 + 1 } ?? 0, min(searchTotal ?? 0, limit))
    }

    func clearSearch() {
        guard searchNeedle != nil else { return }
        searchNeedle = nil
        searchTotal = nil
        searchSelected = nil
        binding("end_search")
    }

    // MARK: libghostty actions

    /// Set while a click is being released, to learn whether libghostty
    /// opened a link (then ⌘-click path detection stays out of it).
    private var openedURLDuringClick = false
    private var mouseCursor: NSCursor = .iBeam

    func handle(_ event: GhosttyEvent) {
        switch event {
        case .title(let t): onTitleReport?(t)
        case .pwd(let p):
            // Manual IO sniffs OSC 7 itself (remote hosts too); this is the
            // local-only report from libghostty's own child.
            if !ioGlue.isManual { onDirectoryChange?(p) }
        case let .commandFinished(code, seconds): onCommandFinished?(code, seconds)
        case let .scrollbar(total, offset, length): scrollbar = (total, offset, length)
        case .cellSize: checkGrid()
        case .searchStarted: break
        case .searchEnded: searchTotal = nil; searchSelected = nil; notifySearch()
        case .searchTotal(let n): searchTotal = n; notifySearch()
        case .searchSelected(let n): searchSelected = n; notifySearch()
        case .mouseShape(let raw): setMouseShape(ghostty_action_mouse_shape_e(rawValue: raw))
        case .mouseVisible(let visible): NSCursor.setHiddenUntilMouseMoves(!visible)
        case .mouseOverLink(let url): hoveredLink = url
        case .openURL(let url): openLink(url)
        case .bell: NSSound.beep()
        case .childExited: onChildExited?()
        case .rendererHealthy(let ok): if !ok { ghosttyLog.error("renderer unhealthy") }
        case .ignored: break
        }
    }

    private func notifySearch() { NotificationCenter.default.post(name: .ghosttySearchDidUpdate, object: self) }

    /// libghostty's ⌘-click on a link. Its link regex also matches bare paths
    /// (greedily: `a/b:12:3 now`); those are left to `pathToken`, which knows
    /// Wireline's rules (strip `:line:col`, resolve remote vs local).
    private func openLink(_ link: String) {
        // `main.c:12` parses with a scheme too — require a real one.
        guard link.contains("://") || link.hasPrefix("mailto:"), let url = URL(string: link) else { return }
        openedURLDuringClick = true
        NSWorkspace.shared.open(url)
    }

    func surfaceRequestedClose(processAlive: Bool) {
        // Manual IO: the PTY (and its exit) is TerminalIO's business.
        if !ioGlue.isManual { onChildExited?() }
    }

    private func setMouseShape(_ shape: ghostty_action_mouse_shape_e) {
        let cursor: NSCursor? = switch shape {
        case GHOSTTY_MOUSE_SHAPE_DEFAULT: .arrow
        case GHOSTTY_MOUSE_SHAPE_TEXT: .iBeam
        case GHOSTTY_MOUSE_SHAPE_POINTER: .pointingHand
        case GHOSTTY_MOUSE_SHAPE_GRAB: .openHand
        case GHOSTTY_MOUSE_SHAPE_GRABBING: .closedHand
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR: .crosshair
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED: .operationNotAllowed
        case GHOSTTY_MOUSE_SHAPE_CONTEXT_MENU: .contextualMenu
        case GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT: .iBeamCursorForVerticalLayout
        case GHOSTTY_MOUSE_SHAPE_EW_RESIZE, GHOSTTY_MOUSE_SHAPE_COL_RESIZE: .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_NS_RESIZE, GHOSTTY_MOUSE_SHAPE_ROW_RESIZE: .resizeUpDown
        default: nil
        }
        guard let cursor, cursor != mouseCursor else { return }
        mouseCursor = cursor
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: mouseCursor) }

    // MARK: Keyboard

    /// Non-nil during keyDown: text the input method committed.
    private var keyTextAccumulator: [String]?
    private var markedText = NSMutableAttributedString()

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        // ⌘W (customizable) closes this session, not the window. AppKit offers
        // key equivalents to every view front to back, so only the focused
        // terminal — or, if focus is elsewhere, the active pane — answers.
        if KeyBindingStore.shared.shortcut(for: .closeShell).matches(event) {
            let focusedTerminal = window?.firstResponder as? any TerminalEngine
            let mine = focusedTerminal.map { $0 === self } ?? (isActivePane?() ?? true)
            guard mine else { return super.performKeyEquivalent(with: event) }
            onCloseRequested?()
            return true
        }
        guard window?.firstResponder === self else { return false }
        // Everything else with ⌘ belongs to the app's menus (copy:, paste: …).
        let equivalent: String
        switch event.charactersIgnoringModifiers {
        case "\r":
            // ⌃↩ verbatim (otherwise the default context-menu equivalent).
            guard event.modifierFlags.contains(.control) else { return false }
            equivalent = "\r"
        case "/":
            // ⌃/ as ⌃_ (macOS beeps at ⌃/).
            guard event.modifierFlags.contains(.control),
                  event.modifierFlags.isDisjoint(with: [.shift, .command, .option]) else { return false }
            equivalent = "_"
        default:
            return false
        }
        guard let final = NSEvent.keyEvent(with: .keyDown, location: event.locationInWindow,
                                           modifierFlags: event.modifierFlags, timestamp: event.timestamp,
                                           windowNumber: event.windowNumber, context: nil, characters: equivalent,
                                           charactersIgnoringModifiers: equivalent, isARepeat: event.isARepeat,
                                           keyCode: event.keyCode) else { return false }
        keyDown(with: final)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard let s = surface?.raw else { interpretKeyEvents([event]); return }
        // ⌘-keys no menu claimed don't reach the program (as with SwiftTerm).
        if event.modifierFlags.contains(.command) { return }

        // Option-as-alt etc.: translate with the modifiers libghostty says
        // take part in text. Reuse the original event when they're the same —
        // AppKit relies on its identity for Korean input.
        let translationGhostty = GhosttyInput.flags(ghostty_surface_key_translation_mods(s, GhosttyInput.mods(event.modifierFlags)))
        var translationMods = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            if translationGhostty.contains(flag) { translationMods.insert(flag) } else { translationMods.remove(flag) }
        }
        let translationEvent: NSEvent = translationMods == event.modifierFlags ? event : NSEvent.keyEvent(
            with: event.type, location: event.locationInWindow, modifierFlags: translationMods,
            timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
            characters: event.characters(byApplyingModifiers: translationMods) ?? "",
            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
            isARepeat: event.isARepeat, keyCode: event.keyCode) ?? event

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }
        let markedTextBefore = markedText.length > 0
        let layoutBefore = markedTextBefore ? nil : GhosttyInput.keyboardLayoutID

        interpretKeyEvents([translationEvent])

        // The keystroke switched the input source: an IME took it.
        if !markedTextBefore && layoutBefore != GhosttyInput.keyboardLayoutID { return }

        syncPreedit(clearIfNeeded: markedTextBefore)
        // Composing while there's preedit — or right after it was cleared
        // (backspace that cancels a composition mustn't delete real input).
        let composing = markedText.length > 0 || markedTextBefore

        if markedTextBefore, let list = keyTextAccumulator, !list.isEmpty {
            // The IME committed (part of) its preedit while handling a key that
            // isn't itself input: send the text, replay only movement keys.
            for text in list where !Self.suppressComposingControl(text, composing: composing) {
                _ = committedText(action, text)
            }
            if shouldReplayCommittedPreeditKey(translationEvent) {
                _ = keyAction(action, event: event, translationEvent: translationEvent)
            }
            return
        }
        if let list = keyTextAccumulator, !list.isEmpty {
            for text in list where !Self.suppressComposingControl(text, composing: composing) {
                _ = keyAction(action, event: event, translationEvent: translationEvent, text: text)
            }
        } else {
            if Self.suppressComposingControl(event.characters, composing: composing) { return }
            _ = keyAction(action, event: event, translationEvent: translationEvent,
                          text: translationEvent.ghosttyCharacters, composing: composing)
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.modifierFlags.contains(.command) { return }
        _ = keyAction(GHOSTTY_ACTION_RELEASE, event: event)
    }

    override func flagsChanged(with event: NSEvent) {
        let mod: UInt32
        switch event.keyCode {
        case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }
        if hasMarkedText() { return }
        let mods = GhosttyInput.mods(event.modifierFlags)
        var action = GHOSTTY_ACTION_RELEASE
        if mods.rawValue & mod != 0 {
            // Pressed — if it's this side that's down; else the other side is
            // still held and this is this side's release.
            let raw = event.modifierFlags.rawValue
            let sidePressed = switch event.keyCode {
            case 0x3C: raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0
            case 0x3E: raw & UInt(NX_DEVICERCTLKEYMASK) != 0
            case 0x3D: raw & UInt(NX_DEVICERALTKEYMASK) != 0
            case 0x36: raw & UInt(NX_DEVICERCMDKEYMASK) != 0
            default: true
            }
            if sidePressed { action = GHOSTTY_ACTION_PRESS }
        }
        _ = keyAction(action, event: event)
    }

    private func keyAction(_ action: ghostty_input_action_e, event: NSEvent, translationEvent: NSEvent? = nil,
                           text: String? = nil, composing: Bool = false) -> Bool {
        guard let s = surface?.raw else { return false }
        var key = event.ghosttyKeyEvent(action, translationMods: translationEvent?.modifierFlags)
        key.composing = composing
        guard let text = text?.ghosttyKeyText else { return ghostty_surface_key(s, key) }
        return text.withCString { ptr in
            key.text = ptr
            return ghostty_surface_key(s, key)
        }
    }

    /// Committed IME / dictation text: a key event with no key, never a paste.
    private func committedText(_ action: ghostty_input_action_e, _ text: String) -> Bool {
        guard let s = surface?.raw else { return false }
        var key = ghostty_input_key_s()
        key.action = action
        key.mods = GHOSTTY_MODS_NONE
        key.consumed_mods = GHOSTTY_MODS_NONE
        return text.withCString { ptr in
            key.text = ptr
            return ghostty_surface_key(s, key)
        }
    }

    private func shouldReplayCommittedPreeditKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 125, 124, 126: return true                     // ↓ → ↑
        case 123:                                            // ← — Korean IMEs already leave the caret
            return !event.modifierFlags.isDisjoint(with: [.shift, .control, .option, .command])
        default: return false
        }
    }

    /// A lone C0 control arriving mid-composition belongs to the IME.
    static func suppressComposingControl(_ text: String?, composing: Bool) -> Bool {
        guard composing, let text, text.unicodeScalars.count == 1, let scalar = text.unicodeScalars.first else { return false }
        return scalar.value < 0x20
    }

    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let s = surface?.raw else { return }
        if markedText.length > 0 {
            let str = markedText.string
            str.withCString { ghostty_surface_preedit(s, $0, UInt(strlen($0))) }
        } else if clearIfNeeded {
            ghostty_surface_preedit(s, nil, 0)
        }
    }

    // AppKit commands from interpretKeyEvents (moveUp:, insertNewline: …):
    // the key itself is encoded after interpretKeyEvents; just don't beep.
    override func doCommand(by selector: Selector) {}

    // MARK: Menu actions

    @objc func copy(_ sender: Any?) { binding("copy_to_clipboard") }
    @objc func paste(_ sender: Any?) { binding("paste_from_clipboard") }
    @objc func pasteAsPlainText(_ sender: Any?) { binding("paste_from_clipboard") }
    override func selectAll(_ sender: Any?) { binding("select_all") }

    // MARK: Mouse

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        // Mouse reports even when unfocused / not key, only in the visible part.
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways],
                                       owner: self, userInfo: nil))
        super.updateTrackingAreas()
    }

    private func sendMousePos(_ event: NSEvent) {
        guard allowMouseReporting, let s = surface?.raw else { return }
        let p = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(s, p.x, frame.height - p.y, GhosttyInput.mods(event.modifierFlags))
    }

    // Like the SwiftTerm view: a click focuses the pane, then reaches the terminal.
    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        onClickFocus?()
        guard allowMouseReporting, let s = surface?.raw else { return }
        sendMousePos(event)
        _ = ghostty_surface_mouse_button(s, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, GhosttyInput.mods(event.modifierFlags))
    }

    override func mouseUp(with event: NSEvent) {
        guard let s = surface?.raw else { return }
        // ⌘-click: libghostty opens a URL under the pointer (OPEN_URL, sent
        // synchronously from the release); otherwise look for a path.
        openedURLDuringClick = false
        if allowMouseReporting {
            sendMousePos(event)
            _ = ghostty_surface_mouse_button(s, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GhosttyInput.mods(event.modifierFlags))
            ghostty_surface_mouse_pressure(s, 0, 0)
        }
        if event.modifierFlags.contains(.command), event.clickCount == 1, !openedURLDuringClick,
           let token = pathToken(at: convert(event.locationInWindow, from: nil)) {
            onOpenPath?(token)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        // A program capturing the mouse gets it; otherwise the app's context menu.
        guard allowMouseReporting, let s = surface?.raw,
              ghostty_surface_mouse_button(s, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, GhosttyInput.mods(event.modifierFlags))
        else { return super.rightMouseDown(with: event) }
    }

    override func rightMouseUp(with event: NSEvent) {
        guard allowMouseReporting, let s = surface?.raw,
              ghostty_surface_mouse_button(s, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, GhosttyInput.mods(event.modifierFlags))
        else { return super.rightMouseUp(with: event) }
    }

    override func otherMouseDown(with event: NSEvent) {
        guard allowMouseReporting, let s = surface?.raw else { return }
        _ = ghostty_surface_mouse_button(s, GHOSTTY_MOUSE_PRESS, GhosttyInput.mouseButton(event.buttonNumber),
                                         GhosttyInput.mods(event.modifierFlags))
    }

    override func otherMouseUp(with event: NSEvent) {
        guard allowMouseReporting, let s = surface?.raw else { return }
        _ = ghostty_surface_mouse_button(s, GHOSTTY_MOUSE_RELEASE, GhosttyInput.mouseButton(event.buttonNumber),
                                         GhosttyInput.mods(event.modifierFlags))
    }

    override func mouseMoved(with event: NSEvent) { sendMousePos(event) }
    override func mouseDragged(with event: NSEvent) { sendMousePos(event) }
    override func rightMouseDragged(with event: NSEvent) { sendMousePos(event) }
    override func otherMouseDragged(with event: NSEvent) { sendMousePos(event) }
    // Entering resets the position (exit set it to -1/-1, which turns reports off).
    override func mouseEntered(with event: NSEvent) { sendMousePos(event) }

    override func mouseExited(with event: NSEvent) {
        // A drag keeps reporting outside the view.
        guard allowMouseReporting, NSEvent.pressedMouseButtons == 0, let s = surface?.raw else { return }
        ghostty_surface_mouse_pos(s, -1, -1, GhosttyInput.mods(event.modifierFlags))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let s = surface?.raw else { return }
        var x = event.scrollingDeltaX, y = event.scrollingDeltaY
        let precise = event.hasPreciseScrollingDeltas
        if precise { x *= 2; y *= 2 }      // Ghostty's (subjective) trackpad speed-up
        ghostty_surface_mouse_scroll(s, x, y, GhosttyInput.scrollMods(precise: precise, phase: event.momentumPhase))
    }

    override func pressureChange(with event: NSEvent) {
        guard let s = surface?.raw else { return }
        ghostty_surface_mouse_pressure(s, UInt32(event.stage), Double(event.pressure))
    }

    // MARK: ⌘-click paths

    /// The visible text of viewport row `row` (top = 0).
    private func viewportLine(_ row: Int, columns: Int) -> String? {
        guard let s = surface?.raw, columns > 0 else { return nil }
        var text = ghostty_text_s()
        let sel = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT, x: 0, y: UInt32(row)),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT,
                                          x: UInt32(columns - 1), y: UInt32(row)),
            rectangle: false)
        guard ghostty_surface_read_text(s, sel, &text) else { return nil }
        defer { ghostty_surface_free_text(s, &text) }
        return String(cString: text.text)
    }

    /// The path-looking word under `point` (same rules as the SwiftTerm
    /// view; URLs are libghostty's).
    private func pathToken(at point: NSPoint) -> String? {
        guard let s = surface?.raw else { return nil }
        let size = ghostty_surface_size(s)
        let cell = cellSize
        guard cell.width > 0, cell.height > 0 else { return nil }
        let row = Int((bounds.height - point.y) / cell.height), col = Int(point.x / cell.width)
        guard row >= 0, row < Int(size.rows), col >= 0, let line = viewportLine(row, columns: Int(size.columns)) else { return nil }
        // Column → character: wide (CJK, emoji) characters take two cells.
        let chars = Array(line)
        var cellAt = 0, index: Int?
        for (i, ch) in chars.enumerated() {
            let w = Self.cellWidth(ch)
            if col < cellAt + w { index = i; break }
            cellAt += w
        }
        guard let index, !chars[index].isWhitespace else { return nil }
        return TerminalPathToken.token(in: chars, at: index)
    }

    private static func cellWidth(_ ch: Character) -> Int {
        guard let v = ch.unicodeScalars.first?.value else { return 1 }
        let wide = (0x1100...0x115F).contains(v) || (0x2E80...0xA4CF).contains(v) || (0xAC00...0xD7A3).contains(v)
            || (0xF900...0xFAFF).contains(v) || (0xFE30...0xFE4F).contains(v) || (0xFF00...0xFF60).contains(v)
            || (0xFFE0...0xFFE6).contains(v) || (0x1F300...0x1FAFF).contains(v) || (0x20000...0x3FFFD).contains(v)
        return wide ? 2 : 1
    }
}

extension Notification.Name {
    /// A libghostty search's match count or selection changed (object: the view).
    static let ghosttySearchDidUpdate = Notification.Name("WirelineGhosttySearchDidUpdate")
}

// MARK: - NSTextInputClient (IME)

extension GhosttyTerminalView: @preconcurrency NSTextInputClient {
    func hasMarkedText() -> Bool { markedText.length > 0 }

    func markedRange() -> NSRange {
        markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange()
    }

    func selectedRange() -> NSRange {
        guard let s = surface?.raw else { return NSRange() }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(s, &text) else { return NSRange() }
        defer { ghostty_surface_free_text(s, &text) }
        return NSRange(location: Int(text.offset_start), length: Int(text.offset_len))
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let v as NSAttributedString: markedText = NSMutableAttributedString(attributedString: v)
        case let v as String: markedText = NSMutableAttributedString(string: v)
        default: return
        }
        // Outside keyDown (a layout switch mid-composition): show it now.
        if keyTextAccumulator == nil { syncPreedit() }
    }

    func unmarkText() {
        guard markedText.length > 0 else { return }
        markedText.mutableString.setString("")
        syncPreedit()
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard let s = surface?.raw, range.length > 0 else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(s, &text) else { return nil }
        defer { ghostty_surface_free_text(s, &text) }
        return NSAttributedString(string: String(cString: text.text))
    }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    /// Where the IME candidate window goes: libghostty's cursor position.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let s = surface?.raw else { return NSRect(origin: frame.origin, size: .zero) }
        let cell = cellSize
        var x = 0.0, y = 0.0, width = Double(cell.width), height = Double(cell.height)
        ghostty_surface_ime_point(s, &x, &y, &width, &height)
        if range.length == 0, width > 0 {
            // Dictation's indicator wants a zero-width caret rect.
            width = 0
            x += Double(cell.width) * Double(range.location)
        }
        let viewRect = NSRect(x: x, y: frame.size.height - y, width: width, height: max(height, Double(cell.height)))
        let winRect = convert(viewRect, to: nil)
        return window?.convertToScreen(winRect) ?? winRect
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        let chars: String
        switch string {
        case let v as NSAttributedString: chars = v.string
        case let v as String: chars = v
        default: return
        }
        unmarkText()
        // Inside keyDown: collect, keyDown sends it with the key.
        if keyTextAccumulator != nil { keyTextAccumulator?.append(chars); return }
        // IME commits, dictation: typed input, never a paste.
        if !chars.isEmpty { _ = committedText(GHOSTTY_ACTION_PRESS, chars) }
    }
}

extension GhosttyTerminalView: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)): surface.map { ghostty_surface_has_selection($0.raw) } ?? false
        case #selector(paste(_:)), #selector(pasteAsPlainText(_:)): NSPasteboard.general.string(forType: .string) != nil
        default: true
        }
    }
}
