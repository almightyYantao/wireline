import Foundation
import WirelineCore

/// Where a session's process runs: a PTY in this app (`PTYProcess`), or one the
/// session agent owns (`AgentPTY`) so it outlives the app. `TerminalIO` talks
/// to either through this.
@MainActor
protocol PTYBackend: AnyObject {
    var onOutput: ((ArraySlice<UInt8>) -> Void)? { get set }
    var onExit: ((PTYTermination) -> Void)? { get set }
    var isRunning: Bool { get }
    var pid: pid_t { get }
    /// Settable from any thread (libghostty resizes from its IO thread).
    nonisolated var windowSize: PTYWindowSize { get }
    func start(executable: String, args: [String], environment: [String],
               execName: String?, currentDirectory: String?, windowSize: winsize?) throws
    func send(_ bytes: ArraySlice<UInt8>)
    func resize(_ size: winsize)
    func foregroundJob() -> PTYForegroundJob
    /// Stop the process (SIGHUP, then SIGKILL); `onExit` isn't called.
    func terminate()
}

extension PTYProcess: PTYBackend {}
