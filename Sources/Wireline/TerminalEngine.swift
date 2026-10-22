import AppKit
import struct SwiftTerm.SearchOptions

/// A terminal renderer: parses the child's output and draws it, and turns the
/// user's typing into bytes for the child. It never owns the process — that's
/// `TerminalIO` — so SwiftTerm and libghostty can sit behind the same session.
/// Everything the app does with a terminal view goes through here.
@MainActor
protocol TerminalEngine: NSView {
    // MARK: Byte plumbing (with TerminalIO)

    /// The session's PTY side (resize flushing, output observation).
    var io: TerminalIO? { get set }
    /// Bytes for the child: keystrokes, pastes, query replies.
    var onInput: ((ArraySlice<UInt8>) -> Void)? { get set }
    /// The grid changed size (`TerminalIO` tells the PTY, throttled — unless
    /// `coalescesResize`).
    var onGridResize: (() -> Void)? { get set }
    /// The engine resizes the PTY itself, in step with its grid
    /// (`TerminalIO.ptyWindowSize`, from any thread), coalescing a drag on its
    /// own: `TerminalIO` must not throttle or send a size of its own.
    var coalescesResize: Bool { get }
    /// Output from the child, to parse and draw.
    func feed(_ bytes: ArraySlice<UInt8>)
    /// The grid size (and its pixel size) to report to the PTY.
    var gridSize: winsize { get }
    /// The throttled grid size has just reached the PTY.
    func didDeliverResize()

    /// Type `txt` as if the user had (goes to the child via `onInput`).
    func send(txt: String)
    /// Draw `text` locally — notices, separators — without the child seeing it.
    func feed(text: String)

    // MARK: Events

    /// ⌘W while this terminal is focused: close just this session.
    var onCloseRequested: (() -> Void)? { get set }
    /// OSC 7 working directory (raw payload).
    var onDirectoryChange: ((String?) -> Void)? { get set }
    /// A program-set window title (OSC 0/2).
    var onTitleReport: ((String) -> Void)? { get set }
    /// A path was ⌘-clicked.
    var onOpenPath: ((String) -> Void)? { get set }
    /// A click landed in this pane.
    var onClickFocus: (() -> Void)? { get set }
    /// Whether this view's session is the active pane.
    var isActivePane: (() -> Bool)? { get set }

    // MARK: Presentation

    func applyAppearance(_ appearance: TerminalAppearance)
    /// Off while an overlay covers the terminal, so TUIs don't see the pointer.
    var allowMouseReporting: Bool { get set }
    /// An image of the current screen, for the frozen frame during layout animation.
    func snapshotImage() -> NSImage?
    /// Called after every chunk of output is rendered, while set.
    var outputObserver: (() -> Void)? { get set }
    /// Send a pending throttled size to the PTY now. True if one was pending.
    @discardableResult func flushPendingResize() -> Bool

    // MARK: Content

    /// Scroll to the previous (−1) / next (+1) prompt.
    @discardableResult func jumpToPrompt(_ delta: Int) -> Bool
    /// Text of the most recent finished command's output.
    func lastCommandOutput() -> String?
    /// Scrollback + screen with colours, for restore on next launch (empty while
    /// a full-screen app owns the alternate screen).
    var renderedBuffer: Data { get }

    // MARK: Search

    func findNext(_ term: String, options: SearchOptions, scrollToResult: Bool) -> Bool
    func findPrevious(_ term: String, options: SearchOptions, scrollToResult: Bool) -> Bool
    func searchMatchSummary(_ term: String, options: SearchOptions, limit: Int) -> (index: Int, total: Int)
    func clearSearch()
}

extension TerminalEngine {
    @discardableResult
    func findNext(_ term: String, options: SearchOptions) -> Bool {
        findNext(term, options: options, scrollToResult: true)
    }
    @discardableResult
    func findPrevious(_ term: String, options: SearchOptions) -> Bool {
        findPrevious(term, options: options, scrollToResult: true)
    }
    func searchMatchSummary(_ term: String, options: SearchOptions) -> (index: Int, total: Int) {
        searchMatchSummary(term, options: options, limit: 1000)
    }
}

/// How a terminal should look, from the app's settings and theme.
struct TerminalAppearance: Equatable {
    var theme: TerminalTheme
    var font: NSFont
    var gpu: Bool
    var cursorShape: CursorShape
    var cursorBlink: Bool
}

/// Which renderer new sessions use (`terminal-engine` in the config file).
enum TerminalEngineKind: String, CaseIterable, Sendable {
    case swiftterm, ghostty

    /// The engine for a new session: the setting, unless libghostty can't run
    /// here (not started, or a GhosttyKit without manual IO) — then SwiftTerm.
    @MainActor
    static func makeEngine(frame: CGRect) -> any TerminalEngine {
        let wanted = UserDefaults.standard.string(forKey: "terminalEngine").flatMap(Self.init) ?? .swiftterm
        if wanted == .ghostty {
            if GhosttyTerminalView.isAvailable { return GhosttyTerminalView(frame: frame) }
            if !warnedFallback {
                warnedFallback = true
                let why = GhosttyRuntime.shared.failure ?? "this GhosttyKit has no manual-IO backend"
                ghosttyLog.warning("terminal-engine = ghostty unavailable (\(why, privacy: .public)); using SwiftTerm")
            }
        }
        return WirelineTerminalView(frame: frame)
    }

    @MainActor private static var warnedFallback = false
}

/// The ⌘-click path rule both engines use.
enum TerminalPathToken {
    static func token(in chars: [Character], at col: Int) -> String? {
        guard col >= 0, col < chars.count, !chars[col].isWhitespace else { return nil }
        let stop: (Character) -> Bool = { $0.isWhitespace || "'\"`()[]{}<>|,;".contains($0) }
        var a = col, b = col
        while a > 0, !stop(chars[a - 1]) { a -= 1 }
        while b + 1 < chars.count, !stop(chars[b + 1]) { b += 1 }
        var token = String(chars[a...b])
        // Drop a trailing ":line:col" (compiler output) and sentence punctuation.
        if let r = token.range(of: #"(:\d+)+:?$"#, options: .regularExpression) { token.removeSubrange(r) }
        while let last = token.last, ".:".contains(last) { token.removeLast() }
        guard !token.contains("://"), token.contains("/") || token.hasPrefix("~") else { return nil }
        return token
    }
}

