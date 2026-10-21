import AppKit
import GhosttyKit
import WirelineCore

/// Who runs a libghostty surface's child process.
enum GhosttyIOMode {
    /// Wireline's `TerminalIO` owns the PTY; libghostty only parses and draws.
    /// Needs the manual-IO termio backend from Wireline's Ghostty fork.
    case manual
    /// libghostty forks and owns the child itself. Debug harness only — none
    /// of `TerminalIO` (ZMODEM, passwords, logging, …) sees its bytes.
    case exec(command: String?, workingDirectory: String?, environment: [String: String])
}

/// All of the byte plumbing between a `GhosttyTerminalView` and its child, in
/// one place so the switch to manual IO is one flag:
///
///   swiftSettings: [.define("WIRELINE_GHOSTTY_MANUAL_IO")]   (Package.swift, Wireline target)
///
/// once Vendor/GhosttyKit.xcframework comes from the fork. The fork's C API, as
/// this file expects it (adjust here if the names land differently):
///
///   // ghostty_surface_config_s gains:
///   ghostty_surface_io_mode_e  io_mode;        // GHOSTTY_SURFACE_IO_EXEC (default) | GHOSTTY_SURFACE_IO_MANUAL
///   void (*io_write_cb)(void *userdata, const uint8_t *bytes, size_t len);   // bytes for the child
///   void (*io_resize_cb)(void *userdata, uint16_t cols, uint16_t rows, uint32_t width_px, uint32_t height_px);
///   void ghostty_surface_io_feed(ghostty_surface_t, const uint8_t *bytes, size_t len);  // child output
///   bool ghostty_surface_read_last_command_output(ghostty_surface_t, ghostty_text_s *); // see lastCommandOutput
///
/// `userdata` in both callbacks is the surface userdata (the view's id). The
/// callbacks may come from libghostty's IO thread; bytes are copied and
/// delivered on the main actor in order.
///
/// Until then (spike GhosttyKit, stock termio): `feed` drops the bytes,
/// `onInput` never fires, and the engine switch refuses "ghostty" — only the
/// harness runs a surface, in `.exec` mode.
@MainActor
final class GhosttyIO {
    /// Whether this build can run a surface in `.manual` mode.
    static var supportsManualIO: Bool {
        #if WIRELINE_GHOSTTY_MANUAL_IO
        true
        #else
        false
        #endif
    }

    let mode: GhosttyIOMode
    weak var view: GhosttyTerminalView?

    /// Escape-sequence watcher over the child's output (manual mode): OSC 7
    /// from remote hosts (libghostty only reports local ones), focus-report
    /// and alternate-screen modes (libghostty has no getter).
    private var sniffer = TerminalStreamSniffer()
    /// The program asked for focus reports (DECSET 1004).
    private(set) var focusReporting = false
    /// A full-screen program owns the alternate screen.
    private(set) var alternateScreen = false

    init(mode: GhosttyIOMode) { self.mode = mode }

    var isManual: Bool { if case .manual = mode { true } else { false } }

    // MARK: Surface creation

    /// Fill the IO half of `cfg` and create the surface inside `body`
    /// (C strings live exactly as long as that call; libghostty copies them).
    func withSurfaceConfig(_ cfg: inout ghostty_surface_config_s,
                           _ body: (inout ghostty_surface_config_s) -> ghostty_surface_t?) -> ghostty_surface_t? {
        switch mode {
        case .manual:
            #if WIRELINE_GHOSTTY_MANUAL_IO
            cfg.io_mode = GHOSTTY_SURFACE_IO_MANUAL
            cfg.io_write_cb = ghosttyIOWrite
            cfg.io_resize_cb = ghosttyIOResize
            return body(&cfg)
            #else
            // Stock libghostty would fork the user's shell here: never in the app.
            ghosttyLog.error("manual IO needs the forked GhosttyKit; not creating a surface")
            return nil
            #endif
        case let .exec(command, workingDirectory, environment):
            let keys = environment.keys.sorted()
            let cKeys = keys.map { strdup($0) }
            let cValues = keys.map { strdup(environment[$0] ?? "") }
            let cCommand = command.flatMap { strdup($0) }
            let cDirectory = workingDirectory.flatMap { strdup($0) }
            defer {
                (cKeys + cValues + [cCommand, cDirectory]).forEach { free($0) }
            }
            var env = zip(cKeys, cValues).map { ghostty_env_var_s(key: UnsafePointer($0), value: UnsafePointer($1)) }
            cfg.command = UnsafePointer(cCommand)
            cfg.working_directory = UnsafePointer(cDirectory)
            return env.withUnsafeMutableBufferPointer { buf in
                cfg.env_vars = buf.baseAddress
                cfg.env_var_count = buf.count
                return body(&cfg)
            }
        }
    }

    // MARK: Child output → emulator

    /// Output from the child (`TerminalIO` → `engine.feed`).
    func feed(_ bytes: ArraySlice<UInt8>) {
        guard !bytes.isEmpty else { return }
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
        bytes.withUnsafeBufferPointer { buf in
            ghostty_surface_io_feed(surface, buf.baseAddress, buf.count)
        }
        #else
        if !Self.warnedFeed {
            Self.warnedFeed = true
            ghosttyLog.warning("GhosttyIO.feed: no manual-IO API in this GhosttyKit; output dropped")
        }
        #endif
    }

    private static var warnedFeed = false

    // MARK: App → child

    /// Bytes the app wants the child to see as typed (`send(txt:)`, focus
    /// reports): straight to the PTY in manual mode, no emulator involved —
    /// what SwiftTerm's `send` does.
    func sendToChild(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        switch mode {
        case .manual:
            view?.onInput?(bytes[...])
        case .exec:
            // libghostty owns the PTY: its `text:` binding writes raw bytes
            // (Zig string escapes, so escape everything non-printable).
            guard let surface = view?.surface?.raw else { return }
            let action = "text:" + bytes.map { b -> String in
                switch b {
                case UInt8(ascii: "\\"): return "\\\\"
                case 0x20..<0x7F: return String(UnicodeScalar(b))
                default: return String(format: "\\x%02x", b)
                }
            }.joined()
            _ = action.withCString { ghostty_surface_binding_action(surface, $0, UInt(strlen($0))) }
        }
    }

    /// The view's real focus changed. libghostty is kept "focused" so the
    /// caret keeps its shape (see `keepsCaretShapeWhenUnfocused`), which
    /// would also stop it sending focus reports — send them ourselves.
    func focusChanged(_ focused: Bool, synthesizeReports: Bool) {
        guard synthesizeReports, focusReporting, isManual else { return }
        sendToChild(Array((focused ? "\u{1b}[I" : "\u{1b}[O").utf8))
    }

    // MARK: Content the fork adds

    /// Text of the most recent finished command's output (OSC 133 C→D).
    /// Stock libghostty has no API for it (its `copy`/`select` bindings don't
    /// cover command output), so nil until the fork's
    /// `ghostty_surface_read_last_command_output`.
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

    // MARK: Emulator → child (fork callbacks land here)

    fileprivate func childBytes(_ bytes: [UInt8]) { view?.onInput?(bytes[...]) }
    fileprivate func gridResized() { view?.onGridResize?() }
}

#if WIRELINE_GHOSTTY_MANUAL_IO
/// Keystrokes, pastes and query answers libghostty encoded for the child.
/// May run on libghostty's IO thread: copy, then deliver on main in order
/// (always async, so a main-thread call can't overtake queued ones).
private func ghosttyIOWrite(_ userdata: UnsafeMutableRawPointer?, _ bytes: UnsafePointer<UInt8>?, _ len: Int) {
    guard let bytes, len > 0 else { return }
    let id = Int(bitPattern: userdata)
    let copy = Array(UnsafeBufferPointer(start: bytes, count: len))
    DispatchQueue.main.async {
        MainActor.assumeIsolated { GhosttyRuntime.shared.view(id)?.ioGlue.childBytes(copy) }
    }
}

/// The grid changed size; `TerminalIO` reads `gridSize` (from
/// `ghostty_surface_size`) and TIOCSWINSZes, throttled.
private func ghosttyIOResize(_ userdata: UnsafeMutableRawPointer?, _ cols: UInt16, _ rows: UInt16,
                             _ widthPx: UInt32, _ heightPx: UInt32) {
    let id = Int(bitPattern: userdata)
    DispatchQueue.main.async {
        MainActor.assumeIsolated { GhosttyRuntime.shared.view(id)?.ioGlue.gridResized() }
    }
}
#endif
