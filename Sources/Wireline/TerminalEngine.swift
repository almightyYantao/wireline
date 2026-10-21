import AppKit

/// A terminal renderer: parses the child's output and draws it, and turns the
/// user's typing into bytes for the child. It never owns the process — that's
/// `TerminalIO` — so SwiftTerm and libghostty can sit behind the same session.
@MainActor
protocol TerminalEngine: AnyObject {
    /// Output from the child, to parse and draw.
    func feed(_ bytes: ArraySlice<UInt8>)
    /// The grid size (and its pixel size) to report to the PTY.
    var gridSize: winsize { get }
    /// The throttled grid size has just reached the PTY.
    func didDeliverResize()
}
