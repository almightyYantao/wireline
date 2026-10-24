import Foundation
import Darwin
import WirelineCore

/// wireline-agent — the session agent (docs/design/wireline-agent.md).
///
///   wireline-agent serve [--socket PATH] [--idle-exit SECONDS] [--foreground]
///       Run the agent: own the sessions' PTYs, serve the app over a Unix
///       socket (default: AgentProtocol.socketPath). One per socket path;
///       a second one exits at once. --foreground logs to stderr.
///   wireline-agent snapshot COLS ROWS < bytes > snapshot
///       Feed stdin to a headless terminal and print its snapshot (tests,
///       debugging a restore).
let args = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("wireline-agent: \(message)\n".utf8))
    exit(64)
}

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

switch args.first {
case "serve":
    let socketPath = option("--socket") ?? AgentProtocol.socketPath
    let idleExit = option("--idle-exit").flatMap(Double.init) ?? 60
    AgentLog.toStderr = args.contains("--foreground")
    signal(SIGPIPE, SIG_IGN)
    signal(SIGHUP, SIG_IGN)            // outlive the terminal / app that started us

    let dir = (socketPath as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
    chmod(dir, 0o700)
    // Single instance per socket: the lock is held for the process's life.
    let lockFD = open(socketPath + ".lock", O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
    guard lockFD >= 0 else { fail("can't open the lock file: \(String(cString: strerror(errno)))") }
    guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
        AgentLog.write("another agent already serves \(socketPath)")
        exit(0)
    }
    let server = AgentServer(socketPath: socketPath, idleExit: idleExit)
    do { try server.start() } catch { fail("can't listen on \(socketPath): \(error)") }
    // A run loop on the real main thread, not dispatchMain(): that parks the
    // main thread and drains the main queue elsewhere, which MainActor rejects.
    withExtendedLifetime(server) { while true { RunLoop.main.run() } }

case "snapshot":
    let rest = Array(args.dropFirst())
    guard rest.count == 2, let cols = UInt16(rest[0]), let rows = UInt16(rest[1]) else {
        fail("usage: wireline-agent snapshot COLS ROWS < bytes > snapshot")
    }
    guard let vt = VTTerminal(cols: cols, rows: rows) else { fail("couldn't create a terminal") }
    vt.write([UInt8](FileHandle.standardInput.readDataToEndOfFile()))
    guard let snap = vt.snapshot() else { fail("couldn't encode a snapshot") }
    FileHandle.standardOutput.write(Data(snap))

default:
    fail("usage: wireline-agent serve [--socket PATH] [--idle-exit SECONDS] [--foreground] | snapshot COLS ROWS")
}
