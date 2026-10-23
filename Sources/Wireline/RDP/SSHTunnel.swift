import Foundation
import WirelineCore

/// `ssh -N -L 127.0.0.1:<free port>:<host>:<port> <jump alias>` for an RDP
/// pane that goes through an SSH host. Owned by the pane's `RDPSession`:
/// started before FreeRDP dials, stopped with the session.
@MainActor
final class SSHTunnel {
    enum Failure: Error {
        case spawn(String)
        case exited(String)
        case timedOut
    }

    private var process: Process?
    private var askpass: URL?
    private var stderrBuffer = Data()
    private(set) var localPort: Int = 0

    var isRunning: Bool { process?.isRunning ?? false }

    /// Start the tunnel and wait until its local end accepts connections
    /// (ssh opens `-L` listeners only after authenticating). Returns the port.
    /// `options`: the jump host's own launch arguments (`-o …`, `-p …`).
    func start(via alias: String, password: String?, options: [String] = [], host: String, port: Int,
               timeout: TimeInterval = 25) async throws -> Int {
        stop()
        guard let lp = Self.freePort() else { throw Failure.spawn("no free local port") }
        localPort = lp
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = [
            "-N",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ControlMaster=no", "-o", "ControlPath=none",
            "-L", "127.0.0.1:\(lp):\(host):\(port)",
        ] + options + [alias]
        var env = ProcessInfo.processInfo.environment
        SSHAgentEnvironment.apply(to: &env)
        if let password, !password.isEmpty, let script = Self.makeAskpass() {
            askpass = script
            env["SSH_ASKPASS"] = script.path
            env["SSH_ASKPASS_REQUIRE"] = "force"
            env["WIRELINE_ASKPASS_PW"] = password
        }
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        p.standardError = errPipe
        stderrBuffer = Data()
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            guard !chunk.isEmpty else { h.readabilityHandler = nil; return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.stderrBuffer.append(chunk) } }
        }
        do { try p.run() } catch { throw Failure.spawn(error.localizedDescription) }
        process = p

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !p.isRunning {
                try? await Task.sleep(for: .milliseconds(50))   // let stderr drain
                throw Failure.exited(lastError)
            }
            if await Self.canConnect(port: lp) { return lp }
            try await Task.sleep(for: .milliseconds(150))
        }
        stop()
        throw Failure.timedOut
    }

    /// ssh's last meaningful stderr line ("Permission denied …", "Could not resolve …").
    var lastError: String {
        let text = String(decoding: stderrBuffer, as: UTF8.self)
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Warning: Permanently added") }
        return lines.last ?? "ssh exited"
    }

    func stop() {
        if let p = process, p.isRunning { p.terminate() }
        process = nil
        if let askpass { try? FileManager.default.removeItem(at: askpass) }
        askpass = nil
    }

    private static func freePort() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, len) == 0 && getsockname(fd, sa, &len) == 0
            }
        }
        return ok ? Int(UInt16(bigEndian: addr.sin_port)) : nil
    }

    nonisolated private static func canConnect(port: Int) async -> Bool {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let fd = socket(AF_INET, SOCK_STREAM, 0)
                guard fd >= 0 else { cont.resume(returning: false); return }
                defer { close(fd) }
                var addr = sockaddr_in()
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_addr.s_addr = inet_addr("127.0.0.1")
                addr.sin_port = UInt16(port).bigEndian
                let rc = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                cont.resume(returning: rc == 0)
            }
        }
    }

    /// Prints the password from the ssh child's environment (never on disk).
    private static func makeAskpass() -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wireline-askpass-\(UUID().uuidString).sh")
        do {
            try "#!/bin/sh\nprintf '%s\\n' \"$WIRELINE_ASKPASS_PW\"\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            return url
        } catch {
            return nil
        }
    }
}
