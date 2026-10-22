import AppKit
import GhosttyKit
import WirelineCore
import os

/// All of the byte plumbing between a `GhosttyTerminalView` and its child.
///
/// Surfaces run libghostty's manual-IO termio (Wireline's Ghostty fork,
/// `WIRELINE_GHOSTTY_MANUAL_IO`): `TerminalIO` owns the PTY, libghostty only
/// parses and draws.
///
///   child output  → `feed` → `ghostty_surface_io_feed` (any thread, copies, in order)
///   keys, pastes, query / mouse / focus replies → `io_write_cb` → `onInput` → PTY
///   grid changes  → `io_resize_cb` → `gridSize` + `onGridResize` → TIOCSWINSZ (throttled)
///
/// Both callbacks run on libghostty's IO thread with the terminal lock held
/// (the first resize: synchronously inside `ghostty_surface_new`). They get
/// a `GhosttyIOBox` — not the view — copy what they need, and hop to main;
/// they never call `ghostty_surface_*`.
///
/// When the child exits, `ghostty_surface_io_exited` is deliberately *not*
/// called: Wireline shows its own banner and reconnects by starting a new
/// process that feeds the same surface.
///
/// Built against a GhosttyKit without the fork, the engine switch refuses
/// "ghostty" (`supportsManualIO` is false) and no surface is ever created.
@MainActor
final class GhosttyIO {
    /// Whether this build can run a surface with manual IO.
    static var supportsManualIO: Bool {
        #if WIRELINE_GHOSTTY_MANUAL_IO
        true
        #else
        false
        #endif
    }

    weak var view: GhosttyTerminalView?
    /// What the IO-thread callbacks may touch.
    let box: GhosttyIOBox

    /// Escape-sequence watcher over the child's output: OSC 7 from remote
    /// hosts (libghostty only reports local ones), focus-report and
    /// alternate-screen modes (libghostty has no getter).
    private var sniffer = TerminalStreamSniffer()
    /// The program asked for focus reports (DECSET 1004).
    private(set) var focusReporting = false
    /// A full-screen program owns the alternate screen.
    private(set) var alternateScreen = false

    init(id: Int) { box = GhosttyIOBox(id: id) }

    // MARK: Surface creation

    /// Fill the IO half of `cfg` — on every surface: an inherited config
    /// doesn't carry it — and create the surface inside `body`.
    func withSurfaceConfig(_ cfg: inout ghostty_surface_config_s,
                           _ body: (inout ghostty_surface_config_s) -> ghostty_surface_t?) -> ghostty_surface_t? {
        #if WIRELINE_GHOSTTY_MANUAL_IO
        cfg.io_mode = GHOSTTY_SURFACE_IO_MANUAL
        cfg.io_userdata = Unmanaged.passUnretained(box).toOpaque()   // the surface handle keeps it alive
        cfg.io_write_cb = ghosttyIOWrite
        cfg.io_resize_cb = ghosttyIOResize
        return body(&cfg)
        #else
        // Stock libghostty would fork the user's shell here: never.
        ghosttyLog.error("manual IO needs the forked GhosttyKit; not creating a surface")
        return nil
        #endif
    }

    // MARK: Child output → emulator

    /// Output from the child (`TerminalIO` → `engine.feed`).
    func feed(_ bytes: ArraySlice<UInt8>) {
        guard !bytes.isEmpty else { return }
        flushEarlyInput()
        for event in sniffer.feed(bytes) {
            switch event {
            case .workingDirectory(let raw): view?.onDirectoryChange?(raw)
            case .privateMode(1004, let on): focusReporting = on
            case .privateMode(1049, let on), .privateMode(1047, let on), .privateMode(47, let on): alternateScreen = on
            case .privateMode: break
            }
        }
        #if WIRELINE_GHOSTTY_MANUAL_IO
        guard let surface = view?.surface?.raw else { return }
        bytes.withUnsafeBufferPointer { ghostty_surface_io_feed(surface, $0.baseAddress, UInt($0.count)) }
        #endif
    }

    // MARK: Emulator / app → child

    /// libghostty can write (e.g. a reply) before `TerminalIO` has started the
    /// child; `TerminalIO.send` would drop it. Held until the child runs —
    /// only before the first one: after an exit, typing into the dead session
    /// is dropped, as with SwiftTerm.
    private var earlyInput: [UInt8] = []
    private var childHasRun = false

    /// Bytes for the child, from libghostty (`io_write_cb`) or the app
    /// (`send(txt:)`, synthesized focus reports). Straight to the PTY — what
    /// SwiftTerm's `send` does.
    func sendToChild(_ bytes: [UInt8]) {
        guard !bytes.isEmpty, let view else { return }
        if !childHasRun {
            guard view.io?.isRunning == true else {
                if earlyInput.count < 65536 { earlyInput += bytes }
                return
            }
            flushEarlyInput()
        }
        view.onInput?(bytes[...])
    }

    private func flushEarlyInput() {
        guard !childHasRun, let view, view.io?.isRunning == true else { return }
        childHasRun = true
        guard !earlyInput.isEmpty else { return }
        let pending = earlyInput
        earlyInput = []
        view.onInput?(pending[...])
    }

    /// The view's real focus changed. libghostty is kept "focused" so the
    /// caret keeps its shape (see `keepsCaretShapeWhenUnfocused`), which
    /// stops it sending focus reports itself — send them here.
    func focusChanged(_ focused: Bool) {
        guard focusReporting else { return }
        sendToChild(Array((focused ? "\u{1b}[I" : "\u{1b}[O").utf8))
    }

    // MARK: Grid

    /// The grid as libghostty last reported it (`io_resize_cb`), nil before.
    var grid: winsize? { box.grid.withLock { $0 } }

    fileprivate func gridResized() { view?.onGridResize?() }

    // MARK: Content

    /// Text of the most recent finished command's output (OSC 133 C→D).
    func lastCommandOutput() -> String? {
        #if WIRELINE_GHOSTTY_MANUAL_IO
        guard let surface = view?.surface?.raw else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_last_command_output(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        let out = String(cString: text.text).trimmingCharacters(in: .newlines)
        return out.isEmpty ? nil : out
        #else
        return nil
        #endif
    }
}

/// The part of a surface's IO state libghostty's IO thread may touch: the
/// view's id (to find it again on main) and the last grid size.
final class GhosttyIOBox: Sendable {
    let id: Int
    let grid = OSAllocatedUnfairLock<winsize?>(initialState: nil)
    init(id: Int) { self.id = id }

    fileprivate static func from(_ p: UnsafeMutableRawPointer?) -> GhosttyIOBox? {
        p.map { Unmanaged<GhosttyIOBox>.fromOpaque($0).takeUnretainedValue() }
    }
}

#if WIRELINE_GHOSTTY_MANUAL_IO
/// Bytes libghostty encoded for the child. IO thread, terminal lock held:
/// copy, then deliver on main — always async, so order is the queue's order.
private func ghosttyIOWrite(_ userdata: UnsafeMutableRawPointer?, _ bytes: UnsafePointer<UInt8>?, _ len: Int) {
    guard let box = GhosttyIOBox.from(userdata), let bytes, len > 0 else { return }
    let id = box.id
    let copy = Array(UnsafeBufferPointer(start: bytes, count: len))
    DispatchQueue.main.async {
        MainActor.assumeIsolated { GhosttyRuntime.shared.view(id)?.ioGlue.sendToChild(copy) }
    }
}

/// The grid changed: store it (read from main as `gridSize`), then let
/// `TerminalIO` tell the PTY, throttled.
private func ghosttyIOResize(_ userdata: UnsafeMutableRawPointer?, _ cols: UInt16, _ rows: UInt16,
                             _ widthPx: UInt32, _ heightPx: UInt32) {
    guard let box = GhosttyIOBox.from(userdata) else { return }
    box.grid.withLock {
        $0 = winsize(ws_row: rows, ws_col: cols,
                     ws_xpixel: UInt16(clamping: widthPx), ws_ypixel: UInt16(clamping: heightPx))
    }
    let id = box.id
    DispatchQueue.main.async {
        MainActor.assumeIsolated { GhosttyRuntime.shared.view(id)?.ioGlue.gridResized() }
    }
}
#endif
