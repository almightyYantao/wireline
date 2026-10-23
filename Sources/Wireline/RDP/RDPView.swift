import AppKit
import Carbon.HIToolbox
import IOSurface
import WirelineCore

/// The remote desktop of one RDP pane.
///
/// Rendering: FreeRDP's framebuffer (BGRA) is copied — dirty rect only — into
/// a small ring of IOSurfaces, the newest of which is the contents of
/// `screen`, a sublayer aspect-fitted into the view. (Core Animation only
/// notices new pixels when `contents` changes object, and a surface it may
/// still be compositing must not be written, hence the ring; each surface
/// tracks the region it's behind the newest one by, so a frame still costs
/// just its dirty rects.) The compositor scales it, so while a layout animation
/// resizes the pane the last frame simply stretches (the RDP equivalent of
/// the terminals' freeze-and-snapshot), and the remote resize waits for the
/// size to settle (see `RDPSession`).
///
/// Input: keys go out as scancodes (`RDPKeyMap`), text from an input method
/// (Chinese, Japanese …) as Unicode key events; ⌘ follows
/// `RDPCommandKeyMode`; ⌘C/⌘V/⌘X/⌘A (Edit menu) always act as Ctrl+key.
@MainActor
final class RDPView: NSView, @preconcurrency NSTextInputClient, NSMenuItemValidation {
    /// Set by `RDPSession` while a connection is up (nil = input is dropped).
    var connection: RDPConnection?
    var commandKeyMode: RDPCommandKeyMode = .controlShortcuts
    /// Left-click: focus this pane.
    var onClickFocus: (() -> Void)?
    /// The view's size or backing scale changed (debounced by the session).
    var onGeometryChange: (() -> Void)?
    /// About to paste on the remote side: make sure it has the Mac clipboard.
    var onWillPaste: (() -> Void)?
    /// Paused while an overlay (host drawer, AI panel) covers the pane.
    var allowPointer = true

    private let screen = CALayer()
    /// The ring (see the type comment). `stale[i]`: what surface i lacks
    /// compared with the one on screen (nil = up to date, `.infinite` = all).
    private var surfaces: [IOSurface] = []
    private var stale: [CGRect?] = []
    private var front = -1
    private(set) var desktop: (width: UInt32, height: UInt32) = (0, 0)
    /// Frames shown since the desktop appeared (diagnostics / tests).
    private(set) var framesShown = 0
    private static let ringSize = 3

    // Input state: everything sent "down" that still has to come back up.
    private var heldKeys: [UInt16: RDPKeyMap.Scancode] = [:]
    private var heldModifiers: [UInt16: RDPKeyMap.Scancode] = [:]
    private var buttonsDown: Set<Int> = []
    private var commandDown = false
    private var commandUsed = false
    private var commandDownAt: CFTimeInterval = 0
    private var injected: RDPKeyMap.Scancode?   // Win or Ctrl sent on ⌘'s behalf
    private var wheelY = RDPWheelAccumulator()
    private var wheelX = RDPWheelAccumulator()
    private var lastPointer: CGPoint = .zero

    // Input method state.
    private var marked = NSMutableAttributedString()
    private var interpreting: NSEvent?
    private let compositionLayer = CATextLayer()

    private var cursor: NSCursor = .arrow
    private static let invisibleCursor: NSCursor = {
        let img = NSImage(size: NSSize(width: 1, height: 1))
        return NSCursor(image: img, hotSpot: .zero)
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        screen.contentsGravity = .resize
        screen.magnificationFilter = .linear
        screen.minificationFilter = .trilinear
        screen.isOpaque = true
        screen.backgroundColor = NSColor.black.cgColor
        screen.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(screen)
        compositionLayer.isHidden = true
        compositionLayer.fontSize = 14
        compositionLayer.cornerRadius = 6
        compositionLayer.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.95).cgColor
        compositionLayer.foregroundColor = NSColor.labelColor.cgColor
        compositionLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
        layer?.addSublayer(compositionLayer)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Rendering

    func resetFrame() {
        surfaces = []
        stale = []
        front = -1
        screen.contents = nil
        desktop = (0, 0)
        framesShown = 0
    }

    /// Pull whatever changed into the next surface of the ring and show it.
    /// Called on every frame event.
    func refresh() {
        guard let connection else { return }
        let size = connection.desktopSize
        guard size.width > 0, size.height > 0 else { return }
        if surfaces.isEmpty || desktop != size {
            guard makeSurfaces(size) else { return }
        }
        // The next surface the compositor isn't reading (normally the oldest).
        var target = (front + 1) % surfaces.count
        for k in 0..<surfaces.count {
            let i = (front + 1 + k) % surfaces.count
            if i != front, !surfaces[i].isInUse { target = i; break }
        }
        let back = surfaces[target]
        back.lock(options: [], seed: nil)
        defer { back.unlock(options: [], seed: nil) }
        let full = front < 0 || stale[target] == .infinite
        if !full, let behind = stale[target] {
            // Catch up on what earlier frames changed, from the surface on screen.
            Self.copy(behind, from: surfaces[front], to: back)
        }
        let result = connection.copyDirty(into: back.baseAddress, stride: back.bytesPerRow,
                                          width: Int(size.width), height: Int(size.height), full: full)
        switch result {
        case .mismatch:
            // Resized between the size query and the copy: the next frame
            // event (the resize itself) rebuilds the ring.
            surfaces = []
            return
        case .unchanged:
            // Caught up with the screen, nothing new: no need to show it.
            stale[target] = nil
        case .copied(let changed):
            stale[target] = nil
            for i in stale.indices where i != target && stale[i] != .infinite {
                stale[i] = full ? .infinite : (stale[i] ?? .null).union(changed)
            }
            front = target
            screen.contents = back
            framesShown += 1
        }
    }

    private func makeSurfaces(_ size: (width: UInt32, height: UInt32)) -> Bool {
        let props: [IOSurfacePropertyKey: Any] = [
            .width: Int(size.width), .height: Int(size.height),
            .bytesPerElement: 4, .pixelFormat: kCVPixelFormatType_32BGRA,
        ]
        let made = (0..<Self.ringSize).compactMap { _ in IOSurface(properties: props) }
        guard made.count == Self.ringSize else { surfaces = []; return false }
        let resized = desktop != size
        surfaces = made
        stale = Array(repeating: .infinite, count: made.count)
        front = -1
        desktop = size
        // Keep showing the old frame (stretched) until the new one lands.
        if resized { layoutScreen() }
        return true
    }

    /// Copy `rect` (pixels) between two same-sized BGRA surfaces.
    private static func copy(_ rect: CGRect, from src: IOSurface, to dst: IOSurface) {
        let bounds = CGRect(x: 0, y: 0, width: src.width, height: src.height)
        let r = rect.intersection(bounds)
        guard !r.isNull, r.width > 0, r.height > 0 else { return }
        src.lock(options: .readOnly, seed: nil)
        defer { src.unlock(options: .readOnly, seed: nil) }
        let x = Int(r.minX), w = Int(r.width) * 4
        for row in Int(r.minY)..<Int(r.maxY) {
            memcpy(dst.baseAddress + row * dst.bytesPerRow + x * 4,
                   src.baseAddress + row * src.bytesPerRow + x * 4, w)
        }
    }

    /// The frame on screen as an image (tests / diagnostics), nil before the first.
    func snapshotImage() -> CGImage? {
        guard front >= 0, surfaces.indices.contains(front) else { return nil }
        let s = surfaces[front]
        s.lock(options: .readOnly, seed: nil)
        defer { s.unlock(options: .readOnly, seed: nil) }
        let data = Data(bytes: s.baseAddress, count: s.bytesPerRow * s.height)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: s.width, height: s.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: s.bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                                                | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    override func layout() {
        super.layout()
        layoutScreen()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        layoutScreen()
        if changed { onGeometryChange?() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        onGeometryChange?()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        onGeometryChange?()
    }

    /// The desktop aspect-fitted into the view (exactly the bounds once the
    /// remote side has followed a resize).
    private var screenRect: CGRect {
        guard desktop.width > 0, desktop.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let aspect = CGFloat(desktop.width) / CGFloat(desktop.height)
        var w = bounds.width, h = bounds.width / aspect
        if h > bounds.height { h = bounds.height; w = h * aspect }
        // Within a couple of points: fill (no hairline bars from rounding).
        if abs(w - bounds.width) < 3 { w = bounds.width }
        if abs(h - bounds.height) < 3 { h = bounds.height }
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h).integral
    }

    private func layoutScreen() {
        screen.frame = screenRect
        screen.contentsScale = window?.backingScaleFactor ?? 2
    }

    /// The pane's current size in points (what the remote desktop should be).
    var pointSize: CGSize { bounds.size }
    var backingScale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    var hasFrame: Bool { front >= 0 }

    // MARK: Pointer

    func setRemotePointer(_ p: RDPConnection.Pointer) {
        switch p {
        case .system: cursor = .arrow
        case .hidden: cursor = Self.invisibleCursor
        case let .image(rgba, w, h, hx, hy):
            cursor = Self.makeCursor(rgba: rgba, width: w, height: h, hotX: hx, hotY: hy,
                                     scale: desktop.width > 0 ? screen.frame.width / CGFloat(desktop.width) : 1)
        }
        window?.invalidateCursorRects(for: self)
        if let window, window.isKeyWindow, allowPointer {
            let p = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if screen.frame.contains(p) { cursor.set() }
        }
    }

    /// `scale`: view points per remote pixel, so the cursor keeps the size
    /// Windows drew it at relative to the desktop.
    private static func makeCursor(rgba: Data, width: Int, height: Int, hotX: Int, hotY: Int, scale: CGFloat) -> NSCursor {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: rgba as CFData),
              let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: width * 4, space: cs,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return .arrow }
        let s = max(0.25, scale)
        let size = NSSize(width: CGFloat(width) * s, height: CGFloat(height) * s)
        let img = NSImage(cgImage: cg, size: size)
        return NSCursor(image: img, hotSpot: NSPoint(x: CGFloat(hotX) * s, y: CGFloat(hotY) * s))
    }

    override func resetCursorRects() {
        addCursorRect(screen.frame, cursor: cursor)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .cursorUpdate],
                                       owner: self))
    }

    override func cursorUpdate(with event: NSEvent) {
        cursor.set()
    }

    private func remote(_ event: NSEvent) -> (x: UInt16, y: UInt16) {
        let p = convert(event.locationInWindow, from: nil)
        lastPointer = p
        let r = screen.frame
        return RDPDisplay.remotePoint(CGPoint(x: p.x - r.minX, y: p.y - r.minY), viewSize: r.size, desktop: desktop)
    }

    private func button(_ event: NSEvent, down: Bool) {
        guard let connection, allowPointer else { return }
        let b: Int
        switch event.type {
        case .leftMouseDown, .leftMouseUp: b = 0
        case .rightMouseDown, .rightMouseUp: b = 1
        default:
            // otherMouse: 2 = middle, 3 = back, 4 = forward
            b = event.buttonNumber == 2 ? 2 : event.buttonNumber == 3 ? 3 : event.buttonNumber == 4 ? 4 : -1
        }
        guard b >= 0 else { return }
        if down { buttonsDown.insert(b) } else if buttonsDown.remove(b) == nil { return }
        let p = remote(event)
        connection.sendMouseMove(x: p.x, y: p.y)
        connection.sendMouseButton(b, down: down, x: p.x, y: p.y)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onClickFocus?()
        button(event, down: true)
    }
    override func mouseUp(with event: NSEvent) { button(event, down: false) }
    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onClickFocus?()
        button(event, down: true)
    }
    override func rightMouseUp(with event: NSEvent) { button(event, down: false) }
    override func otherMouseDown(with event: NSEvent) { button(event, down: true) }
    override func otherMouseUp(with event: NSEvent) { button(event, down: false) }

    override func mouseMoved(with event: NSEvent) { move(event) }
    override func mouseDragged(with event: NSEvent) { move(event) }
    override func rightMouseDragged(with event: NSEvent) { move(event) }
    override func otherMouseDragged(with event: NSEvent) { move(event) }

    private func move(_ event: NSEvent) {
        guard let connection, allowPointer else { return }
        let p = remote(event)
        connection.sendMouseMove(x: p.x, y: p.y)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let connection, allowPointer else { return }
        if event.phase == .began { wheelX.reset(); wheelY.reset() }
        let precise = event.hasPreciseScrollingDeltas
        // Natural scrolling is already folded into the deltas (content follows fingers).
        let p = remote(event)
        for step in wheelY.feed(delta: Double(event.scrollingDeltaY), precise: precise) {
            connection.sendWheel(vertical: true, delta: step, x: p.x, y: p.y)
        }
        // Horizontal: positive deltaX means content moves right, i.e. scroll left.
        for step in wheelX.feed(delta: Double(-event.scrollingDeltaX), precise: precise) {
            connection.sendWheel(vertical: false, delta: step, x: p.x, y: p.y)
        }
    }

    // MARK: Focus

    override func becomeFirstResponder() -> Bool {
        connection?.sendFocusIn(capsLock: NSEvent.modifierFlags.contains(.capsLock))
        return true
    }

    override func resignFirstResponder() -> Bool {
        releaseAll()
        unmarkText()
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard let window else { releaseAll(); return }
        NotificationCenter.default.addObserver(self, selector: #selector(windowLostKey),
                                               name: NSWindow.didResignKeyNotification, object: window)
        onGeometryChange?()
    }

    @objc private func windowLostKey() { releaseAll() }

    /// Let go of everything held remotely (focus loss, ⌘-Tab away, disconnect):
    /// otherwise Windows keeps a stuck Shift / mouse button.
    func releaseAll() {
        if let connection {
            for sc in heldKeys.values { connection.sendKey(sc.code, extended: sc.extended, down: false) }
            for sc in heldModifiers.values { connection.sendKey(sc.code, extended: sc.extended, down: false) }
            if let sc = injected { connection.sendKey(sc.code, extended: sc.extended, down: false) }
            for b in buttonsDown {
                let p = RDPDisplay.remotePoint(CGPoint(x: lastPointer.x - screen.frame.minX, y: lastPointer.y - screen.frame.minY),
                                               viewSize: screen.frame.size, desktop: desktop)
                connection.sendMouseButton(b, down: false, x: p.x, y: p.y)
            }
        }
        heldKeys.removeAll()
        heldModifiers.removeAll()
        buttonsDown.removeAll()
        injected = nil
        commandDown = false
        commandUsed = true
    }

    // MARK: Keyboard

    private var isISO: Bool { KBGetLayoutType(Int16(LMGetKbdType())) == kKeyboardISO }

    /// An input method (Pinyin, Kana …) is the current input source: let it
    /// compose, then send what it produces as Unicode.
    private var inputMethodActive: Bool {
        guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(src, kTISPropertyInputSourceType) else { return false }
        let type = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
        return type == (kTISTypeKeyboardInputMode as String) || type == (kTISTypeKeyboardInputMethodModeEnabled as String)
    }

    override func keyDown(with event: NSEvent) {
        guard connection != nil else { return }
        let mods = event.modifierFlags.intersection([.control, .option, .command])
        if hasMarkedText() || (mods.isEmpty && inputMethodActive) {
            interpreting = event
            inputContext?.handleEvent(event)
            interpreting = nil
            return
        }
        sendDown(event)
    }

    override func keyUp(with event: NSEvent) {
        guard let connection, let sc = heldKeys.removeValue(forKey: event.keyCode) else { return }
        connection.sendKey(sc.code, extended: sc.extended, down: false)
    }

    /// Key down for `event` as a scancode, with ⌘'s stand-in pressed first.
    private func sendDown(_ event: NSEvent) {
        guard let connection, let sc = RDPKeyMap.scancode(forKeyCode: event.keyCode, iso: isISO) else { return }
        if commandDown {
            commandUsed = true
            if injected == nil {
                let stand = commandKeyMode == .windowsKey ? RDPKeyMap.leftWindows : RDPKeyMap.leftControl
                connection.sendKey(stand.code, extended: stand.extended, down: true)
                injected = stand
            }
        }
        heldKeys[event.keyCode] = sc
        connection.sendKey(sc.code, extended: sc.extended, down: true)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let connection, let mod = RDPKeyMap.modifier(forKeyCode: event.keyCode) else { return }
        let kc = event.keyCode
        switch mod {
        case .function:
            return
        case .capsLock:
            // A toggle: tap it remotely on every change.
            connection.sendKey(0x3A, extended: false, down: true)
            connection.sendKey(0x3A, extended: false, down: false)
        case .command:
            let down = event.modifierFlags.contains(.command) && heldModifiers[kc] == nil && !commandDown
            if down {
                commandDown = true
                commandUsed = false
                commandDownAt = CACurrentMediaTime()
            } else if commandDown, !event.modifierFlags.contains(.command) {
                commandDown = false
                if let sc = injected {
                    connection.sendKey(sc.code, extended: sc.extended, down: false)
                    injected = nil
                } else if commandKeyMode == .windowsKey, !commandUsed, CACurrentMediaTime() - commandDownAt < 0.5 {
                    // A bare ⌘ tap: the Windows key on its own (Start menu).
                    let w = RDPKeyMap.leftWindows
                    connection.sendKey(w.code, extended: w.extended, down: true)
                    connection.sendKey(w.code, extended: w.extended, down: false)
                }
            }
        case .shift, .control, .option:
            guard let sc = RDPKeyMap.scancode(forKeyCode: kc) else { return }
            if let held = heldModifiers.removeValue(forKey: kc) {
                connection.sendKey(held.code, extended: held.extended, down: false)
            } else {
                heldModifiers[kc] = sc
                connection.sendKey(sc.code, extended: sc.extended, down: true)
            }
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.firstResponder === self, connection != nil else {
            return super.performKeyEquivalent(with: event)
        }
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if mods.contains(.command) {
            // Mac-style editing shortcuts straight to the remote as Ctrl+key.
            if commandKeyMode == .controlShortcuts, mods == [.command] || mods == [.command, .shift],
               RDPCommandKeyMode.controlLetters.contains(event.keyCode) {
                if event.keyCode == 0x09 { onWillPaste?() }   // ⌘V
                sendDown(event)
                return true
            }
            // Wireline's own shortcuts (new tab, split, close …) win.
            commandUsed = true
            if NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return true }
            sendDown(event)
            return true
        }
        if mods.contains(.control) || mods.contains(.option) {
            // ⌃Tab, ⌥-letters … belong to the remote unless a menu item claims them.
            if NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return true }
            sendDown(event)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // Edit menu: act on the remote side.
    @objc func copy(_ sender: Any?) { ctrlCombo(0x2E) }
    @objc func cut(_ sender: Any?) { ctrlCombo(0x2D) }
    @objc func paste(_ sender: Any?) {
        onWillPaste?()
        // Give the server a moment to take the new clipboard offer first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in self?.ctrlCombo(0x2F) }
    }
    @objc override func selectAll(_ sender: Any?) { ctrlCombo(0x1E) }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)), #selector(cut(_:)), #selector(paste(_:)), #selector(selectAll(_:)):
            return connection != nil
        default:
            return true
        }
    }

    private func ctrlCombo(_ code: UInt8) {
        guard let connection else { return }
        let ctrl = RDPKeyMap.leftControl
        // ⌘ is physically held: make sure no Windows key is down with it.
        if let sc = injected, sc != ctrl {
            connection.sendKey(sc.code, extended: sc.extended, down: false)
            injected = nil
        }
        commandUsed = true
        let alreadyDown = injected == ctrl
        if !alreadyDown { connection.sendKey(ctrl.code, extended: false, down: true) }
        connection.sendKey(code, extended: false, down: true)
        connection.sendKey(code, extended: false, down: false)
        if !alreadyDown { connection.sendKey(ctrl.code, extended: false, down: false) }
    }

    // MARK: NSTextInputClient (input methods)

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        let hadMarked = hasMarkedText()
        unmarkText()
        guard let connection, !text.isEmpty else { return }
        // A key the input method passed through untouched (e.g. Pinyin's
        // English mode): send the real key, so shortcuts and games still work.
        if !hadMarked, let e = interpreting, e.characters == text, text.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 0x20 }) {
            sendDown(e)
            return
        }
        connection.sendUnicode(text)
    }

    override func doCommand(by selector: Selector) {
        // Return, arrows, Backspace … with nothing being composed.
        if let e = interpreting { sendDown(e) }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let s = (string as? NSAttributedString) ?? NSAttributedString(string: (string as? String) ?? "")
        marked = NSMutableAttributedString(attributedString: s)
        showComposition()
    }

    func unmarkText() {
        marked = NSMutableAttributedString()
        showComposition()
    }

    func selectedRange() -> NSRange { NSRange(location: marked.length, length: 0) }
    func markedRange() -> NSRange { marked.length > 0 ? NSRange(location: 0, length: marked.length) : NSRange(location: NSNotFound, length: 0) }
    func hasMarkedText() -> Bool { marked.length > 0 }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func characterIndex(for point: NSPoint) -> Int { 0 }

    /// We can't see the remote caret: put the candidate window by the
    /// composition bubble (bottom-left of where the pointer last was).
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let local = compositionLayer.isHidden ? CGRect(x: lastPointer.x, y: lastPointer.y, width: 1, height: 20)
                                              : compositionLayer.frame
        let inWindow = convert(local, to: nil)
        return window?.convertToScreen(inWindow) ?? inWindow
    }

    private func showComposition() {
        guard marked.length > 0 else { compositionLayer.isHidden = true; return }
        let text = marked.string
        let font = NSFont.systemFont(ofSize: 14)
        let w = (text as NSString).size(withAttributes: [.font: font]).width + 16
        compositionLayer.string = NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: NSColor.labelColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ])
        compositionLayer.contentsScale = backingScale
        compositionLayer.alignmentMode = .center
        let x = min(max(lastPointer.x, 8), max(8, bounds.width - w - 8))
        let y = min(max(lastPointer.y + 16, 8), max(8, bounds.height - 30))
        compositionLayer.frame = CGRect(x: x, y: y, width: w, height: 22)
        compositionLayer.isHidden = false
    }
}
