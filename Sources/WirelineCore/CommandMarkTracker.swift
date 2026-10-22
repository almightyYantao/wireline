import Foundation

/// Busy state from a terminal engine's shell-integration marks (OSC 133 C →
/// D), for sessions whose engine reports them. Once a mark has been seen the
/// marks are trusted and the output-based prompt heuristic stands down.
///
/// A command counts as "busy" only once it has run for `busyDelay` — the same
/// beat the heuristic waits — so `ls` never flickers a tab's badge. The caller
/// owns the timer: `started()` hands back a token, and `confirmBusy(_:)`
/// with it after the delay says whether the badge should go on.
public struct CommandMarkTracker: Sendable {
    public static let busyDelay: TimeInterval = 1.0

    /// The engine reports command marks: ignore the output heuristic.
    public private(set) var isActive = false
    /// Between C and D.
    public private(set) var isRunning = false
    /// The badge is on (confirmed by `confirmBusy`, cleared by `finished`).
    public private(set) var isBusy = false
    private var generation = 0

    public init() {}

    /// OSC 133;C. Returns the token for `confirmBusy` after `busyDelay`.
    public mutating func started() -> Int {
        isActive = true
        isRunning = true
        generation &+= 1
        return generation
    }

    /// The delay passed: true if that command is still the one running and
    /// the badge should go on now.
    public mutating func confirmBusy(_ token: Int) -> Bool {
        guard token == generation, isRunning, !isBusy else { return false }
        isBusy = true
        return true
    }

    /// OSC 133;D. Returns whether the badge was on (and should go off).
    public mutating func finished() -> Bool {
        isActive = true
        isRunning = false
        generation &+= 1
        defer { isBusy = false }
        return isBusy
    }

    /// The process went away mid-command: nothing is running any more. The
    /// marks stay trusted — a reconnect runs the same shell setup.
    public mutating func reset() {
        isRunning = false
        isBusy = false
        generation &+= 1
    }
}
