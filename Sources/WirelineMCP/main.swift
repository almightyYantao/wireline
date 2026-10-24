import Foundation
import Darwin
import WirelineCore

/// `wireline-mcp`: what an MCP client (Claude Code, Codex …) launches over
/// stdio. It relays newline-delimited JSON-RPC to the running Wireline app over
/// its Unix socket; every tool, the privacy masking and the approvals live in
/// the app (docs/design/mcp-server.md).
///
/// Not running? Launch it in the background and wait. Still unreachable? Answer
/// as a minimal server whose one tool says why, so the client can tell the user.

setvbuf(stdout, nil, _IONBF, 0)
signal(SIGPIPE, SIG_IGN)

func log(_ s: String) { FileHandle.standardError.write(Data(("[wireline-mcp] " + s + "\n").utf8)) }

/// The .app this binary sits in (Contents/MacOS/wireline-mcp), if any.
func enclosingApp() -> URL? {
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let app = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return app.pathExtension == "app" ? app : nil
}

/// `WIRELINE_MCP_SOCKET` points at another app instance (tests, dev builds);
/// then nothing is launched.
let override = ProcessInfo.processInfo.environment["WIRELINE_MCP_SOCKET"]
let socketPath = override ?? MCPBridge.socketPath

func connect() -> Int32? { try? AgentConnection.connect(path: socketPath) }

func launchApp() {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    // -g: don't steal focus from the terminal the client runs in.
    p.arguments = enclosingApp().map { ["-g", $0.path] } ?? ["-g", "-b", MCPBridge.bundleID]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
    p.waitUntilExit()
}

func connectOrLaunch() -> Int32? {
    if let fd = connect() { return fd }
    guard override == nil else { return nil }
    log("Wireline isn't running; launching it")
    launchApp()
    let deadline = Date().addingTimeInterval(15)
    while Date() < deadline {
        usleep(250_000)
        if let fd = connect() { return fd }
    }
    return nil
}

func writeAll(_ fd: Int32, _ bytes: UnsafeRawBufferPointer) -> Bool {
    var off = 0
    while off < bytes.count {
        let n = write(fd, bytes.baseAddress! + off, bytes.count - off)
        if n > 0 { off += n } else if n < 0, errno == EINTR { continue } else { return false }
    }
    return true
}

/// Copy `from` to `to` until either side closes.
func pump(_ from: Int32, _ to: Int32) {
    var buf = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let n = buf.withUnsafeMutableBytes { read(from, $0.baseAddress, $0.count) }
        if n < 0, errno == EINTR { continue }
        guard n > 0 else { return }
        guard buf.withUnsafeBytes({ writeAll(to, UnsafeRawBufferPointer(rebasing: $0[0..<n])) }) else { return }
    }
}

func serveOffline(reason: String) -> Never {
    while let line = readLine(strippingNewline: true) {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty,
              let reply = MCPBridge.offlineReply(to: line, reason: reason) else { continue }
        print(reply)
    }
    exit(0)
}

guard let fd = connectOrLaunch() else {
    log("can't reach Wireline at \(socketPath)")
    serveOffline(reason: "Wireline 没有运行，也没能自动启动。请先打开 Wireline（需要 1.4 或更新版本），然后重新连接这个 MCP server。"
                 + " / Wireline isn't running and couldn't be started. Open Wireline, then reconnect this MCP server.")
}

// Only ever talk to a genuine Wireline: same signing team, or (unsigned dev
// builds) the binary beside us.
if case .refused(let why) = PeerIdentity.check(fd: fd) {
    log("refusing the process on the socket: \(why)")
    serveOffline(reason: "Wireline 的 MCP socket 上不是可信的 Wireline 进程（\(why)），已拒绝连接。"
                 + " / The process on Wireline's MCP socket isn't a trusted Wireline (\(why)).")
}

// Client → app on a thread; app → client here. Either side closing ends us.
Thread.detachNewThread {
    pump(STDIN_FILENO, fd)
    exit(0)
}
pump(fd, STDOUT_FILENO)
exit(0)
