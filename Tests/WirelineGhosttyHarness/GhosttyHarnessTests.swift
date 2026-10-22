import AppKit
import XCTest
import struct SwiftTerm.SearchOptions
import GhosttyKit
import WirelineCore
@testable import Wireline

/// End-to-end check of the libghostty engine the way a session runs it: one
/// `GhosttyTerminalView` with manual IO, wired to a real `TerminalIO` (its
/// `PTYProcess` PTY runs `/bin/zsh -l`) exactly as `TerminalSession.init`
/// does, in a window that never takes focus, driven through the view's own
/// key path.
///
/// Opens a window and a shell, so it only runs when asked:
///
///   WIRELINE_GHOSTTY_HARNESS=1 swift test --filter WirelineGhosttyHarness
///
/// Results go to stdout and /tmp/wireline-ghostty-harness/ (log, snapshot PNG).
@MainActor
final class GhosttyHarnessTests: XCTestCase {
    private let outDir = URL(fileURLWithPath: "/tmp/wireline-ghostty-harness", isDirectory: true)
    private var logLines: [String] = []

    private func log(_ s: String) {
        logLines.append(s)
        print("[harness] \(s)")
    }

    /// Spin the main run loop (libghostty's wakeups are main-queue blocks).
    @discardableResult
    private func wait(_ timeout: TimeInterval, until done: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if done() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return done()
    }

    private func pump(_ seconds: TimeInterval) { _ = wait(seconds) { false } }

    private func screen(_ view: GhosttyTerminalView) -> String {
        guard let s = view.surface?.raw else { return "" }
        var text = ghostty_text_s()
        let sel = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        guard ghostty_surface_read_text(s, sel, &text) else { return "" }
        defer { ghostty_surface_free_text(s, &text) }
        return String(cString: text.text)
    }

    /// Visible rows, top first.
    private func viewport(_ view: GhosttyTerminalView) -> [String] {
        guard let s = view.surface?.raw else { return [] }
        var text = ghostty_text_s()
        let sel = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        guard ghostty_surface_read_text(s, sel, &text) else { return [] }
        defer { ghostty_surface_free_text(s, &text) }
        return String(cString: text.text).components(separatedBy: "\n")
    }

    private static let keyCodes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38,
        "k": 40, "n": 45, "m": 46, " ": 49, "'": 39, "-": 27, ";": 41,
    ]

    /// Type through the view's real key path: NSEvents into its window, which
    /// hands them to the first responder (keyDown → interpretKeyEvents → libghostty).
    private func type(_ text: String, into window: NSWindow) {
        for ch in text {
            post(String(ch), keyCode: Self.keyCodes[Character(ch.lowercased())] ?? 0, window: window)
        }
    }

    private func post(_ chars: String, keyCode: UInt16, flags: NSEvent.ModifierFlags = [], window: NSWindow) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: chars,
                                           charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode)
            else { continue }
            window.sendEvent(e)
        }
    }

    private func pressReturn(_ window: NSWindow) { post("\r", keyCode: 36, window: window) }

    func testGhosttyEngineEndToEnd() throws {
        guard ProcessInfo.processInfo.environment["WIRELINE_GHOSTTY_HARNESS"] == "1" else {
            throw XCTSkip("set WIRELINE_GHOSTTY_HARNESS=1 to run the libghostty harness (opens a window)")
        }
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        defer { try? logLines.joined(separator: "\n").write(to: outDir.appendingPathComponent("harness.log"), atomically: true, encoding: .utf8) }

        // Resources as bundle.sh lays them out, from the repo's Vendor/.
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        setenv("GHOSTTY_RESOURCES_DIR", repo.appendingPathComponent("Vendor/ghostty-share/ghostty").path, 1)

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        XCTAssertTrue(GhosttyRuntime.shared.start(), "runtime: \(GhosttyRuntime.shared.failure ?? "?")")
        log("runtime started, manual IO compiled in: \(GhosttyIO.supportsManualIO)")

        // A predictable shell: login zsh, but our own tiny rc instead of the user's.
        let zdot = outDir.appendingPathComponent("zdotdir", isDirectory: true)
        try? FileManager.default.createDirectory(at: zdot, withIntermediateDirectories: true)
        // OSC 133 marks (Wireline's own zsh integration does the same), a
        // title, and OSC 7 from a *remote-looking* host — libghostty drops
        // those, the stream sniffer must not.
        try #"""
            PROMPT=$'%{\e]133;A\a%}wl%% %{\e]133;B\a%}'
            unsetopt PROMPT_SP
            preexec() { print -n "\e]133;C\a" }
            precmd() { print -n "\e]133;D;$?\a\e]2;wl-title\a\e]7;file://wl-remote-host$PWD\a" }
            """#.write(to: zdot.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)

        let window = HarnessWindow(contentRect: NSRect(x: 120, y: 120, width: 720, height: 420),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = "Wireline libghostty harness"
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        let wallpaper = HarnessWallpaper(frame: NSRect(x: 0, y: 0, width: 720, height: 420))
        wallpaper.autoresizingMask = [.width, .height]
        window.contentView = wallpaper

        let view = GhosttyTerminalView(frame: wallpaper.bounds)
        XCTAssertNotNil(view.surface, "surface created")
        // Engine ⇄ PTY, as TerminalSession.init wires it. Every byte the
        // child gets is also recorded.
        let io = TerminalIO(password: nil, autoSudo: false)
        var toChild: [UInt8] = []
        var disconnects: [Int32?] = []
        view.io = io
        io.engine = view
        view.onInput = { [weak io] bytes in toChild += bytes; io?.send(bytes) }
        io.onDisconnected = { disconnects.append($0) }
        let env = ["TERM=xterm-256color", "COLORTERM=truecolor", "LANG=en_US.UTF-8", "ZDOTDIR=\(zdot.path)",
                   "HOME=\(NSHomeDirectory())", "USER=\(NSUserName())", "PATH=/usr/bin:/bin:/usr/sbin:/sbin"]
        func launch() {
            io.start(executable: "/bin/zsh", args: ["-l"], environment: env, execName: "-zsh",
                     currentDirectory: NSTemporaryDirectory())
        }
        // Hosted the way the app hosts it (freeze / snapshot / commit around layout animations).
        let container = TerminalContainerView(term: view)
        container.frame = wallpaper.bounds
        container.autoresizingMask = [.width, .height]
        var gridResizes = 0, titles: [String] = [], dirs: [String] = [], closes = 0, opened: [String] = []
        view.onGridResize = { [weak io] in gridResizes += 1; io?.gridDidChange() }
        view.onTitleReport = { titles.append($0) }
        view.onDirectoryChange = { dirs.append($0 ?? "nil") }
        view.onCloseRequested = { closes += 1 }
        view.onOpenPath = { opened.append($0) }
        var shellEvents: [ShellCommandEvent] = []
        view.onShellCommand = { shellEvents.append($0) }
        wallpaper.addSubview(container)

        var appearance = TerminalAppearance(theme: .wireline, font: TerminalFont.preferred(size: 13)!,
                                            gpu: true, cursorShape: .bar, cursorBlink: true)
        view.applyAppearance(appearance)
        window.orderFrontRegardless()            // never activate: don't steal focus
        window.makeFirstResponder(view)
        log("window \(window.windowNumber) key=\(window.isKeyWindow) firstResponder=\(window.firstResponder === view)")
        pump(0.1)                               // the real size reaches io_resize_cb first
        launch()
        log("child started via TerminalIO/PTYProcess, pid \(io.childPID), grid \(view.gridSize.ws_col)×\(view.gridSize.ws_row)")

        // 1. The shell comes up.
        let prompt = wait(10) { screen(view).contains("wl%") }
        log("prompt: \(prompt)")
        XCTAssertTrue(prompt, "zsh prompt; screen:\n\(screen(view))")

        // 2. Type `echo hi` + Return through the key path.
        type("echo hi", into: window)
        pressReturn(window)
        let echoed = wait(5) { screen(view).split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "hi" } }
        log("typed `echo hi` ⏎ → output line 'hi': \(echoed)")
        XCTAssertTrue(echoed, "screen:\n\(screen(view))")

        // 3. IME: marked text (preedit), then the commit outside keyDown.
        type("echo ", into: window)
        view.setMarkedText("zhong wen", selectedRange: NSRange(location: 9, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        pump(0.2)
        let preeditShown = view.hasMarkedText()
        view.insertText("中文", replacementRange: NSRange(location: NSNotFound, length: 0))
        pressReturn(window)
        let chinese = wait(5) { screen(view).split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "中文" } }
        log("IME: preedit set \(preeditShown), commit '中文' echoed: \(chinese)")
        XCTAssertTrue(chinese)

        // 4. send(txt:) (straight to the PTY, like SwiftTerm's send).
        view.send(txt: "echo sent-ok\r")
        let sent = wait(5) { screen(view).contains("\nsent-ok") }
        log("send(txt:) → 'sent-ok': \(sent)")
        XCTAssertTrue(sent)

        // 4b. Click focus, and ⌘-click on a path (no URL → our path rule).
        view.send(txt: "echo see /usr/share/zsh:12:3 now\r")
        let pathRow = wait(5) { viewport(view).contains { $0.hasPrefix("see /usr") } }
        var clicks = 0
        view.onClickFocus = { clicks += 1 }
        if pathRow, let row = viewport(view).firstIndex(where: { $0.hasPrefix("see /usr") }) {
            let cell = view.cellSize
            let point = NSPoint(x: (CGFloat(8) + 0.5) * cell.width, y: view.bounds.height - (CGFloat(row) + 0.5) * cell.height)
            let loc = view.convert(point, to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let e = NSEvent.mouseEvent(with: type, location: loc, modifierFlags: .command,
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                if type == .leftMouseDown { view.mouseDown(with: e) } else { view.mouseUp(with: e) }
            }
        }
        log("click → onClickFocus ×\(clicks); ⌘-click on '/usr/share/zsh:12:3' → onOpenPath \(opened)")
        XCTAssertEqual(clicks, 1)
        XCTAssertEqual(opened, ["/usr/share/zsh"])

        // 5. Resize: the grid follows and onGridResize fires.
        let before = view.gridSize, resizesBefore = gridResizes
        window.setContentSize(NSSize(width: 960, height: 560))
        _ = wait(5) { view.gridSize.ws_col != before.ws_col && gridResizes > resizesBefore }
        let after = view.gridSize
        let cell = view.cellSize
        let expectCols = Int(view.bounds.width / cell.width), expectRows = Int(view.bounds.height / cell.height)
        log("resize 720×420 → 960×560: grid \(before.ws_col)×\(before.ws_row) → \(after.ws_col)×\(after.ws_row) "
            + "(expected \(expectCols)×\(expectRows), cell \(cell.width)×\(cell.height)pt, px \(after.ws_xpixel)×\(after.ws_ypixel)), "
            + "onGridResize ×\(gridResizes - resizesBefore)")
        XCTAssertGreaterThan(after.ws_col, before.ws_col)
        XCTAssertEqual(Int(after.ws_col), expectCols)
        XCTAssertEqual(Int(after.ws_row), expectRows)
        XCTAssertGreaterThan(gridResizes, resizesBefore)
        // TerminalIO throttles TIOCSWINSZ (50 ms); deliver it now, as a container commit does.
        view.flushPendingResize()
        view.send(txt: "stty size\r")
        let stty = wait(5) { screen(view).contains("\n\(after.ws_row) \(after.ws_col)") }
        log("child sees `stty size` = \(after.ws_row) \(after.ws_col): \(stty)")
        XCTAssertTrue(stty)

        // 6. Appearance at runtime: bigger font → bigger cells, fewer columns.
        let cellBefore = view.cellSize
        appearance.font = NSFont(descriptor: appearance.font.fontDescriptor, size: 18) ?? appearance.font
        appearance.theme = TerminalTheme.presets.first { $0.name != "Wireline" } ?? .wireline
        appearance.cursorShape = .block
        view.applyAppearance(appearance)
        pump(0.4)
        log("appearance: font 13 → 18, theme → \(appearance.theme.name): cell \(cellBefore) → \(view.cellSize), grid \(view.gridSize.ws_col)×\(view.gridSize.ws_row)")
        XCTAssertGreaterThan(view.cellSize.height, cellBefore.height)

        // 7. Search.
        _ = view.findNext("echo", options: .init(caseSensitive: false, regex: false))
        let found = wait(3) { view.searchMatchSummary("echo", options: .init(caseSensitive: false, regex: false)).total > 0 }
        let summary = view.searchMatchSummary("echo", options: .init(caseSensitive: false, regex: false))
        log("search 'echo': \(summary.index)/\(summary.total) (async: \(found))")
        XCTAssertTrue(found)
        view.clearSearch()

        // 7b. Case-sensitive search (the fork's set_search_case_sensitive).
        view.send(txt: "echo Needle needle NEEDLE\r")
        _ = wait(5) { screen(view).contains("\nNeedle needle NEEDLE") }
        func count(_ caseSensitive: Bool) -> Int {
            let o = SearchOptions(caseSensitive: caseSensitive, regex: false)
            _ = view.findNext("needle", options: o)
            _ = wait(3) { view.searchMatchSummary("needle", options: o).total > 0 }
            pump(0.2)
            return view.searchMatchSummary("needle", options: o).total
        }
        let insensitive = count(false), sensitive = count(true), insensitiveAgain = count(false)
        view.clearSearch()
        log("search 'needle': case-insensitive \(insensitive), case-sensitive \(sensitive), back \(insensitiveAgain)")
        XCTAssertEqual(insensitive, 6)       // the command line and its output
        XCTAssertEqual(sensitive, 2)
        XCTAssertEqual(insensitiveAgain, 6)

        // 8. Last command output (OSC 133) and jump to prompt.
        view.send(txt: "printf 'last-1\\nlast-2\\n'\r")
        let last = wait(5) { view.lastCommandOutput() == "last-1\nlast-2" }
        log("lastCommandOutput → \(String(reflecting: view.lastCommandOutput())) (\(last))")
        XCTAssertTrue(last)
        log("jumpToPrompt(-1) → \(view.jumpToPrompt(-1)), jumpToPrompt(1) → \(view.jumpToPrompt(1))")
        _ = view.binding("scroll_to_bottom")

        // 8b. OSC 7: the remote-looking host reaches onDirectoryChange (sniffer).
        log("titles \(titles.suffix(1)), OSC 7 \(dirs.suffix(1)) → parseOSC7Path \(dirs.last.flatMap(TerminalSession.parseOSC7Path) ?? "nil")")
        XCTAssertTrue(dirs.contains { $0.hasPrefix("file://wl-remote-host/") }, "\(dirs)")
        XCTAssertTrue(titles.contains("wl-title"))

        // 8c. Scrollbar (TerminalScrollbar over the libghostty view, fed by SCROLLBAR).
        try checkScrollbar(view, container: container, window: window)

        // 8d. Command marks: C from the stream sniffer, D from COMMAND_FINISHED.
        shellEvents = []
        view.send(txt: "false\r")
        let falseDone = wait(5) { shellEvents.contains { if case .finished = $0 { true } else { false } } }
        let falseEvents = shellEvents
        shellEvents = []
        view.send(txt: "sleep 1\r")
        let sleepDone = wait(5) { shellEvents.contains { if case .finished = $0 { true } else { false } } }
        let sleepEvents = shellEvents
        log("shell marks: `false` → \(falseEvents) (\(falseDone)); `sleep 1` → \(sleepEvents) (\(sleepDone))")
        XCTAssertEqual(falseEvents.first, .started)
        if case let .finished(code, duration)? = falseEvents.last {
            XCTAssertEqual(code, 1)
            XCTAssertLessThan(duration, 1)
        } else { XCTFail("`false`: no COMMAND_FINISHED") }
        XCTAssertEqual(sleepEvents.first, .started)
        if case let .finished(code, duration)? = sleepEvents.last {
            XCTAssertEqual(code, 0)
            XCTAssertTrue((0.9...3).contains(duration), "\(duration)")
        } else { XCTFail("`sleep 1`: no COMMAND_FINISHED") }

        // 9. ⌘W → onCloseRequested (this view is the focused pane).
        _ = window.performKeyEquivalent(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13)!)
        log("⌘W → onCloseRequested ×\(closes)")
        XCTAssertGreaterThanOrEqual(closes, 1)

        // 10. Focus: key + first responder = full caret; otherwise the same shape
        // at 35%, steady. The window can't really become key without activating
        // this process (which would take focus from the user), so it pretends.
        appearance.cursorBlink = false
        view.applyAppearance(appearance)
        window.pretendKey = true
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        let focusedKey = wait(1) { view.isFocused }
        let caretFocused = cursorAlpha(view)
        window.makeFirstResponder(nil)
        let resigned = wait(1) { !view.isFocused }
        let caretUnfocused = cursorAlpha(view)
        window.makeFirstResponder(view)
        _ = wait(1) { view.isFocused }
        log("focus: key+first responder → \(focusedKey), resigned → \(resigned); block caret mean alpha "
            + "focused \(caretFocused) vs unfocused \(caretUnfocused) (expect ≈255 vs ≈89, same block shape); app active \(NSApp.isActive)")
        XCTAssertTrue(focusedKey)
        XCTAssertTrue(resigned)
        XCTAssertGreaterThan(caretFocused, 200)
        XCTAssertTrue((60...120).contains(caretUnfocused), "dimmed, not hollow (a hollow block's centre would be ~0)")
        XCTAssertFalse(NSApp.isActive, "the harness must not activate itself")

        // 10a. Focus reports: a program that sets DECSET 1004 gets ESC[O / ESC[I
        // (synthesized: libghostty itself stays "focused").
        view.send(txt: "printf '\\e[?1004h'; echo fr-on\r")
        _ = wait(5) { screen(view).contains("\nfr-on") }
        let reportsOn = view.ioGlue.focusReporting
        toChild = []
        window.makeFirstResponder(nil)
        _ = wait(1) { !view.isFocused }
        window.makeFirstResponder(view)
        _ = wait(1) { view.isFocused }
        pump(0.1)
        let reports = String(decoding: toChild, as: UTF8.self)
        view.send(txt: "\u{03}printf '\\e[?1004l'; echo fr-off\r")
        _ = wait(5) { screen(view).contains("\nfr-off") }
        toChild = []
        window.makeFirstResponder(nil); _ = wait(1) { !view.isFocused }
        window.makeFirstResponder(view); _ = wait(1) { view.isFocused }
        log("focus reports: 1004 seen \(reportsOn), sent \(reports.debugDescription); after 1004l sent \(String(decoding: toChild, as: UTF8.self).debugDescription)")
        XCTAssertTrue(reportsOn)
        XCTAssertEqual(reports, "\u{1b}[O\u{1b}[I")
        XCTAssertTrue(toChild.isEmpty)

        // 10b. Container freeze → resize under the cover → commit.
        if !window.occlusionState.contains(.visible), let s = view.surface?.raw {
            ghostty_surface_set_occlusion(s, true)
            ghostty_surface_refresh(s)
            pump(0.3)
        }
        let gridFrozen = view.gridSize
        let hostedViews = container.subviews.count        // terminal + scrollbar
        container.freeze()
        let cover = container.subviews.count > hostedViews, hidden = view.alphaValue == 0
        let barOnTop = container.subviews.last === container.scrollbar
        container.setFrameSize(NSSize(width: container.bounds.width - 200, height: container.bounds.height))
        pump(0.05)
        let heldDuringFreeze = view.gridSize.ws_col == gridFrozen.ws_col
        container.commit(animated: false)
        pump(0.3)
        log("container: freeze → cover \(cover), terminal hidden \(hidden) (reduce motion: \(Motion.reduce)); "
            + "grid held while frozen \(heldDuringFreeze); commit → \(gridFrozen.ws_col) → \(view.gridSize.ws_col) cols, "
            + "visible \(view.alphaValue == 1), cover gone \(container.subviews.count == hostedViews), scrollbar above cover \(barOnTop)")
        if !Motion.reduce { XCTAssertTrue(cover && hidden && heldDuringFreeze && barOnTop) }
        XCTAssertEqual(container.subviews.count, hostedViews)
        XCTAssertLessThan(view.gridSize.ws_col, gridFrozen.ws_col)
        XCTAssertEqual(view.alphaValue, 1)
        container.setFrameSize(wallpaper.bounds.size)
        pump(0.3)

        // 11. renderedBuffer (VT export via the intercepted clipboard).
        let buffer = view.renderedBuffer
        let bufferText = String(decoding: buffer, as: UTF8.self)
        log("renderedBuffer: \(buffer.count) bytes, has 'sent-ok': \(bufferText.contains("sent-ok")), "
            + "starts with OSC 10/11: \(buffer.starts(with: [0x1B, 0x5D, 0x31])), CRLF: \(bufferText.contains("\r\n"))")
        XCTAssertTrue(bufferText.contains("sent-ok"))
        XCTAssertFalse(buffer.starts(with: [0x1B, 0x5D, 0x31]))
        XCTAssertNotEqual(NSPasteboard.general.string(forType: .string)?.hasSuffix("screen.txt"), true,
                          "the export path must not land on the pasteboard")

        // 12. Snapshot keeps alpha; glyph edges are clean premultiplied colour (no halo).
        log("occlusion visible: \(window.occlusionState.contains(.visible)), layer \(Swift.type(of: view.layer!)), contents \(view.layer?.contents.map { String(describing: Swift.type(of: $0)) } ?? "nil")")
        if !window.occlusionState.contains(.visible), let s = view.surface?.raw {
            // Covered (another app fullscreen / screen locked): libghostty stops
            // drawing occluded surfaces. Tell it this one is visible so a frame lands.
            ghostty_surface_set_occlusion(s, true)
            ghostty_surface_refresh(s)
        }
        pump(0.5)
        let snap = view.snapshotImage()
        XCTAssertNotNil(snap)
        if let snap, let cg = snap.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let rep = NSBitmapImageRep(cgImage: cg)
            try? rep.representation(using: .png, properties: [:])?.write(to: outDir.appendingPathComponent("snapshot.png"))
            let stats = Self.alphaStats(rep, fg: appearance.theme.foreground)
            log("snapshot \(rep.pixelsWide)×\(rep.pixelsHigh): transparent \(stats.clear)%, opaque \(stats.opaque)%, "
                + "partial \(stats.partial)%, premultiplied-valid \(stats.validPremul)%, "
                + "edge colour error vs fg (unpremultiplied, 0–255) \(stats.edgeError)")
            XCTAssertGreaterThan(stats.clear, 50, "background must be transparent")
            XCTAssertGreaterThan(stats.validPremul, 99.9)
        }
        // For comparison: what cacheDisplay sees of a layer-hosting Metal view.
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            log("cacheDisplay (old path): \(Self.alphaStats(rep, fg: appearance.theme.foreground).opaque)% opaque pixels")
        }

        // 13. No config diagnostics from any generated config.
        log("config diagnostics: \(GhosttyRuntime.diagnostics)")
        XCTAssertEqual(GhosttyRuntime.diagnostics, [])
        log("grid resizes \(gridResizes)")

        // 14. Reconnect into the same view (TerminalSession.reconnect), without
        // ghostty_surface_io_exited: the old child exits, a new one feeds on.
        // It dies inside a "full-screen app": alternate screen, focus reports,
        // mouse tracking, hidden cursor all left on.
        view.send(txt: "echo PRIMARY-''MARK\r")     // quotes: only the output reads PRIMARY-MARK
        XCTAssertTrue(wait(5) { screen(view).contains("\nPRIMARY-MARK") })
        view.send(txt: "printf '\\033[?1049h\\033[?1004h\\033[?1000h\\033[?25l\\033[5;10HALT-'SCREEN; sleep 0.3; exit 3\r")
        let exited = wait(5) { !disconnects.isEmpty }
        log("child exit → onDisconnected \(disconnects) (\(exited)); typing while dead reaches the child: \(io.isRunning)")
        XCTAssertTrue(exited)
        pump(0.2)                               // libghostty parses on its IO thread
        let leftOn = (view.ioGlue.alternateScreen, view.ioGlue.focusReporting)
        let altShown = screen(view).contains("ALT-SCREEN")
        // As TerminalSession.reconnect does it.
        io.resetForReconnect()
        view.feed(text: TerminalModeReset.afterChildExit)
        let resetOff = (view.ioGlue.alternateScreen, view.ioGlue.focusReporting)
        pump(0.2)
        let primary = screen(view)
        view.feed(text: "\r\n\u{1b}[2m──────── 重新连接 / reconnecting ────────\u{1b}[0m\r\n")
        pump(0.2)
        let rows = screen(view).components(separatedBy: "\n")
        let markRow = rows.lastIndex { $0.trimmingCharacters(in: .whitespaces) == "PRIMARY-MARK" }
        let sepRow = rows.lastIndex { $0.contains("reconnecting") }
        log("mode reset: alt/focus left on \(leftOn) → \(resetOff); primary screen back \(!primary.contains("ALT-SCREEN") && primary.contains("PRIMARY-MARK")); "
            + "mark row \(markRow ?? -1), separator row \(sepRow ?? -1)")
        XCTAssertTrue(leftOn == (true, true), "sniffer saw the modes go on")
        XCTAssertTrue(altShown)
        XCTAssertTrue(resetOff == (false, false), "sniffer saw the reset")
        XCTAssertFalse(primary.contains("ALT-SCREEN"))
        XCTAssertTrue(primary.contains("\nPRIMARY-MARK"))
        if let markRow, let sepRow { XCTAssertGreaterThan(sepRow, markRow + 1, "separator below the old prompt line, nothing overwritten") }
        else { XCTFail("mark / separator rows missing:\n\(rows.suffix(12).joined(separator: "\n"))") }
        launch()
        let again = wait(10) { screen(view).components(separatedBy: "reconnecting").last?.contains("wl%") == true }
        type("echo again", into: window)
        pressReturn(window)
        let againOut = wait(5) { screen(view).split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "again" } }
        view.send(txt: "stty size\r")
        let g = view.gridSize
        let sttyAgain = wait(5) { screen(view).components(separatedBy: "reconnecting").last?.contains("\n\(g.ws_row) \(g.ws_col)") == true }
        log("reconnect: new prompt \(again), typed 'echo again' → \(againOut), new child's stty size \(g.ws_row) \(g.ws_col) → \(sttyAgain)")
        XCTAssertTrue(againOut)
        XCTAssertTrue(sttyAgain)

        // Tear down: shell exits, view and surface go away cleanly.
        view.send(txt: "exit\r")
        _ = wait(5) { disconnects.count >= 2 }
        view.removeFromSuperview()
        window.close()
        pump(0.3)
        log("done")
    }

    /// A line-based wheel event (positive = back into history).
    private func wheel(_ lines: Int32) -> NSEvent? {
        CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0)
            .flatMap(NSEvent.init(cgEvent:))
    }

    private func mouse(_ type: NSEvent.EventType, at p: NSPoint, in view: NSView) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(p, to: nil), modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: view.window?.windowNumber ?? 0,
                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    /// Scroll back with the wheel → the bar shows; drag its thumb → the
    /// viewport follows; back at the bottom it fades; streaming output at the
    /// bottom never shows it.
    private func checkScrollbar(_ view: GhosttyTerminalView, container: TerminalContainerView, window: NSWindow) throws {
        let bar = try XCTUnwrap(container.scrollbar)
        // SCROLLBAR comes from draws: make sure this surface draws.
        if let s = view.surface?.raw { ghostty_surface_set_occlusion(s, true) }
        var changes = 0
        let forward = view.onScrollChange
        view.onScrollChange = { changes += 1; forward?() }
        view.send(txt: "seq 1 400\r")
        _ = wait(5) { screen(view).contains("\n400\n") }
        _ = wait(2) { view.canScroll && view.scrollPosition >= 0.999 }
        pump(1.6)                                   // any earlier reveal has faded
        let atBottom = (view.canScroll, view.scrollPosition, bar.alphaValue)
        log("scrollbar after `seq 1 400`: canScroll \(atBottom.0), position \(atBottom.1), thumb \(view.scrollThumbsize), "
            + "state \(String(describing: view.scrollbar)), alpha \(atBottom.2), SCROLLBAR changes \(changes)")
        XCTAssertTrue(atBottom.0)
        XCTAssertEqual(atBottom.1, 1)
        XCTAssertLessThan(atBottom.2, 0.05, "hidden while following the bottom")

        // Wheel up.
        for _ in 0..<4 { if let e = wheel(5) { view.scrollWheel(with: e) } }
        let back = wait(2) { view.scrollPosition < 0.999 }
        pump(0.5)                                   // reveal animation
        let barLoc = window.contentView!.convert(bar.convert(NSPoint(x: bar.bounds.maxX - 6, y: bar.bounds.midY), to: nil), from: nil)
        let hit = window.contentView!.hitTest(barLoc)
        log("wheel up ×4: scrolled back \(back), position \(view.scrollPosition), bar alpha \(bar.alphaValue), "
            + "hit-test on the thumb column → \(hit.map { String(describing: Swift.type(of: $0)) } ?? "nil")")
        XCTAssertTrue(back)
        XCTAssertGreaterThan(bar.alphaValue, 0.9, "revealed on scroll")
        XCTAssertTrue(hit === bar, "the visible bar takes clicks in its column")

        // Drag the thumb to the top, then to the middle.
        func rows() -> [String] { screen(view).components(separatedBy: "\n") }
        bar.mouseDown(with: mouse(.leftMouseDown, at: NSPoint(x: bar.bounds.maxX - 6, y: bar.bounds.midY), in: bar))
        bar.mouseDragged(with: mouse(.leftMouseDragged, at: NSPoint(x: bar.bounds.maxX - 6, y: 0), in: bar))
        let top = wait(2) { view.scrollbar?.offset == 0 && viewport(view).first == rows().first }
        let topRow = viewport(view).first ?? ""
        bar.mouseDragged(with: mouse(.leftMouseDragged, at: NSPoint(x: bar.bounds.maxX - 6, y: bar.bounds.midY), in: bar))
        let mid = wait(2) {
            guard let s = view.scrollbar, s.offset > 0, Int(s.offset) < rows().count else { return false }
            return viewport(view).first == rows()[Int(s.offset)]
        }
        let midState = view.scrollbar, midRow = viewport(view).first ?? ""
        bar.mouseUp(with: mouse(.leftMouseUp, at: NSPoint(x: bar.bounds.maxX - 6, y: bar.bounds.midY), in: bar))
        log("drag thumb → top: offset 0, viewport row 0 = screen row 0 (\(topRow.debugDescription)): \(top); "
            + "→ middle: \(String(describing: midState)), position \(view.scrollPosition), viewport row 0 \(midRow.debugDescription) "
            + "= screen row at offset: \(mid)")
        XCTAssertTrue(top)
        XCTAssertTrue(mid)
        XCTAssertTrue((0.3...0.7).contains(view.scrollPosition), "\(view.scrollPosition)")

        // Drag to the bottom: follows output again, the bar fades out.
        bar.mouseDown(with: mouse(.leftMouseDown, at: NSPoint(x: bar.bounds.maxX - 6, y: bar.bounds.maxY), in: bar))
        bar.mouseUp(with: mouse(.leftMouseUp, at: NSPoint(x: bar.bounds.maxX - 6, y: bar.bounds.maxY), in: bar))
        let bottom = wait(2) { view.scrollPosition >= 0.999 }
        let faded = wait(3) { bar.alphaValue < 0.05 }
        log("drag thumb → bottom: position \(view.scrollPosition) (\(bottom)), faded \(faded)")
        XCTAssertTrue(bottom)
        XCTAssertTrue(faded)

        // Streaming at the bottom: SCROLLBAR keeps changing, the bar stays hidden.
        changes = 0
        var maxAlpha: CGFloat = 0, samples = 0
        view.send(txt: "yes | head -2000; echo stream-done\r")
        let streamed = wait(10) {
            maxAlpha = max(maxAlpha, bar.alphaValue); samples += 1
            return screen(view).contains("\nstream-done")
        }
        pump(0.3)
        maxAlpha = max(maxAlpha, bar.alphaValue)
        log("streaming `yes | head -2000` at the bottom: done \(streamed), SCROLLBAR changes \(changes), "
            + "max bar alpha over \(samples) samples \(maxAlpha), position \(view.scrollPosition)")
        XCTAssertTrue(streamed)
        XCTAssertGreaterThan(changes, 0)
        XCTAssertLessThan(maxAlpha, 0.01, "never shown while following the bottom")
        view.onScrollChange = forward
    }

    /// The SwiftTerm engine keeps the same bar, now hosted by the container.
    func testSwiftTermScrollbar() throws {
        guard ProcessInfo.processInfo.environment["WIRELINE_GHOSTTY_HARNESS"] == "1" else {
            throw XCTSkip("set WIRELINE_GHOSTTY_HARNESS=1 to run the harness (opens a window)")
        }
        NSApplication.shared.setActivationPolicy(.accessory)
        let window = HarnessWindow(contentRect: NSRect(x: 160, y: 160, width: 640, height: 360),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let term = WirelineTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        let container = TerminalContainerView(term: term)
        container.frame = window.contentView!.bounds
        window.contentView!.addSubview(container)
        window.orderFrontRegardless()
        pump(0.1)
        let bar = try XCTUnwrap(container.scrollbar)
        var changes = 0
        let forward = term.onScrollChange
        term.onScrollChange = { changes += 1; forward?() }
        var maxAlpha: CGFloat = 0
        for i in 1...300 { term.feed(text: "line \(i)\r\n"); if i % 30 == 0 { pump(0.02); maxAlpha = max(maxAlpha, bar.alphaValue) } }
        pump(0.3)
        maxAlpha = max(maxAlpha, bar.alphaValue)
        let streamChanges = changes
        let nativeHidden = term.subviews.compactMap { $0 as? NSScroller }.allSatisfy(\.isHidden)
        term.scroll(toPosition: 0)
        pump(0.5)
        let shownOnScroll = bar.alphaValue
        let position = term.scrollPosition
        // Drag the thumb to the middle.
        bar.mouseDown(with: mouse(.leftMouseDown, at: NSPoint(x: bar.bounds.maxX - 6, y: bar.bounds.midY), in: bar))
        bar.mouseUp(with: mouse(.leftMouseUp, at: NSPoint(x: bar.bounds.maxX - 6, y: bar.bounds.midY), in: bar))
        let dragged = term.scrollPosition
        term.scroll(toPosition: 1)
        let faded = wait(3) { bar.alphaValue < 0.05 }
        log("SwiftTerm: 300 lines at the bottom → onScrollChange ×\(streamChanges), max alpha \(maxAlpha); native scroller hidden \(nativeHidden); "
            + "scroll(toPosition: 0) → position \(position), alpha \(shownOnScroll); thumb drag to middle → \(dragged); back to bottom → faded \(faded)")
        XCTAssertGreaterThan(streamChanges, 0)
        XCTAssertLessThan(maxAlpha, 0.01)
        XCTAssertTrue(nativeHidden)
        XCTAssertEqual(position, 0)
        XCTAssertGreaterThan(shownOnScroll, 0.9)
        XCTAssertTrue((0.3...0.7).contains(dragged), "\(dragged)")
        XCTAssertTrue(faded)
        window.close()
        pump(0.2)
    }

    /// Mean alpha over the middle of the cursor's cell, from a fresh frame.
    private func cursorAlpha(_ view: GhosttyTerminalView) -> Int {
        guard let s = view.surface?.raw else { return -1 }
        ghostty_surface_set_occlusion(s, true)      // draw even if the window is covered
        ghostty_surface_refresh(s)
        pump(0.35)
        var x = 0.0, y = 0.0, w = 0.0, h = 0.0
        ghostty_surface_ime_point(s, &x, &y, &w, &h)
        guard let cg = view.snapshotImage()?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return -1 }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.bitmapData else { return -1 }
        let scale = Double(rep.pixelsWide) / Double(view.bounds.width)
        let cell = view.cellSize
        let alphaIndex = rep.bitmapFormat.contains(.alphaFirst) ? 0 : 3
        // x is the cell's midpoint, y its bottom (top-left origin, points).
        let x0 = Int((x - Double(cell.width) * 0.25) * scale), x1 = Int((x + Double(cell.width) * 0.25) * scale)
        let y0 = Int((y - Double(cell.height) * 0.75) * scale), y1 = Int((y - Double(cell.height) * 0.25) * scale)
        var sum = 0, n = 0
        for py in max(0, y0)..<min(rep.pixelsHigh, y1) {
            for px in max(0, x0)..<min(rep.pixelsWide, x1) {
                sum += Int(data[py * rep.bytesPerRow + px * rep.samplesPerPixel + alphaIndex]); n += 1
            }
        }
        return n == 0 ? -1 : sum / n
    }

    /// Alpha distribution of a snapshot, and how far partially-covered pixels'
    /// colour is from the text colour once unpremultiplied (a halo shows up as
    /// a large error: dark or background-tinted fringes).
    private static func alphaStats(_ rep: NSBitmapImageRep, fg: [Double])
        -> (clear: Double, opaque: Double, partial: Double, validPremul: Double, edgeError: Int) {
        guard let data = rep.bitmapData else { return (0, 0, 0, 0, 0) }
        let w = rep.pixelsWide, h = rep.pixelsHigh, bpr = rep.bytesPerRow, spp = rep.samplesPerPixel
        let alphaFirst = rep.bitmapFormat.contains(.alphaFirst)
        var clear = 0, opaque = 0, partial = 0, valid = 0, total = 0
        var err = 0.0, errN = 0
        for y in stride(from: 0, to: h, by: 2) {
            for x in stride(from: 0, to: w, by: 2) {
                let p = data + y * bpr + x * spp
                guard spp >= 4 else { opaque += 1; total += 1; continue }
                let (r, g, b, a) = alphaFirst ? (p[1], p[2], p[3], p[0]) : (p[0], p[1], p[2], p[3])
                total += 1
                if a == 0 { clear += 1 } else if a == 255 { opaque += 1 } else { partial += 1 }
                if r <= a && g <= a && b <= a { valid += 1 }
                if a > 20 && a < 235 {
                    // Only foreground-coloured text: a tinted (green/red) cell would skew it.
                    let ur = Double(r) / Double(a), ug = Double(g) / Double(a), ub = Double(b) / Double(a)
                    let d = (abs(ur - fg[0]) + abs(ug - fg[1]) + abs(ub - fg[2])) / 3
                    if d < 0.35 { err += d; errN += 1 }
                }
            }
        }
        func pct(_ n: Int) -> Double { total == 0 ? 0 : (Double(n) * 1000 / Double(total)).rounded() / 10 }
        return (pct(clear), pct(opaque), pct(partial), pct(valid), errN == 0 ? -1 : Int(err / Double(errN) * 255))
    }
}

/// Never really key (that would mean activating the test process and taking
/// focus from the user's app); `pretendKey` stands in for it.
private final class HarnessWindow: NSWindow {
    var pretendKey = false
    override var isKeyWindow: Bool { pretendKey }
}

/// A loud gradient behind the terminal, standing in for the app wallpaper.
private final class HarnessWallpaper: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSGradient(colors: [.systemPurple, .systemOrange, .systemTeal])?.draw(in: bounds, angle: 35)
    }
}
