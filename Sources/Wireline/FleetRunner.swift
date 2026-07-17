import Foundation
import WirelineCore

/// Result of running one command on one host.
struct FleetResult: Identifiable, Sendable {
    let id = UUID()
    let alias: String
    var output: String
    var exitCode: Int32
    var ok: Bool { exitCode == 0 }
}

/// Runs a single command across many hosts concurrently, non-interactively —
/// reusing each host's ssh config, and auto-filling Keychain passwords via an
/// askpass helper (so password-auth hosts work without BatchMode).
enum FleetRunner {
    static func run(command: String, on aliases: [String],
                    keychain: KeychainService = KeychainService(),
                    timeout: Int = 20, maxConcurrent: Int = 8) async -> [FleetResult] {
        // Snapshot passwords up front (Keychain access) so the workers are pure.
        let creds: [(alias: String, password: String?)] = aliases.map { alias in
            (alias, (try? keychain.password(for: alias)) ?? nil)
        }

        var results: [FleetResult] = []
        var index = 0
        // Simple bounded concurrency with a task group.
        await withTaskGroup(of: FleetResult.self) { group in
            func addNext() {
                guard index < creds.count else { return }
                let (alias, password) = creds[index]
                index += 1
                group.addTask { await runOne(alias: alias, password: password, command: command, timeout: timeout) }
            }
            for _ in 0..<min(maxConcurrent, creds.count) { addNext() }
            while let r = await group.next() {
                results.append(r)
                addNext()
            }
        }
        // Preserve the caller's host order.
        return aliases.compactMap { a in results.first { $0.alias == a } }
    }

    /// Upload a local file/directory to `alias:remotePath` via `scp -r`, reusing the
    /// host's ssh config and Keychain password (same askpass path as `run`). The
    /// local machine is the source — this is exactly what the AI could not do
    /// before, since its only executor ran commands *on* remote hosts.
    static func upload(localPath: String, to alias: String, remotePath: String,
                       keychain: KeychainService = KeychainService(), timeout: Int = 30) async -> FleetResult {
        await scp(alias: alias, source: localPath, dest: "\(alias):\(remotePath)",
                  verb: "上传", keychain: keychain, timeout: timeout)
    }

    /// Download `alias:remotePath` to a local path via `scp -r`.
    static func download(from alias: String, remotePath: String, localPath: String,
                         keychain: KeychainService = KeychainService(), timeout: Int = 30) async -> FleetResult {
        await scp(alias: alias, source: "\(alias):\(remotePath)", dest: localPath,
                  verb: "下载", keychain: keychain, timeout: timeout)
    }

    /// Shared scp core (direction is just which side carries the `alias:` prefix).
    private static func scp(alias: String, source: String, dest: String, verb: String,
                            keychain: KeychainService, timeout: Int) async -> FleetResult {
        let password = (try? keychain.password(for: alias)) ?? nil
        return await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/scp")
                var opts = ["-r", "-o", "StrictHostKeyChecking=accept-new",
                            "-o", "ConnectTimeout=\(timeout)",
                            "-o", "NumberOfPasswordPrompts=1"]
                var env = ProcessInfo.processInfo.environment
                var askpass: URL?
                if let password, !password.isEmpty, let script = makeAskpassScript() {
                    askpass = script
                    env["SSH_ASKPASS"] = script.path
                    env["SSH_ASKPASS_REQUIRE"] = "force"
                    env["WIRELINE_ASKPASS_PW"] = password
                } else {
                    opts = ["-o", "BatchMode=yes"] + opts
                }
                p.arguments = opts + [source, dest]
                p.environment = env
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch {
                    cont.resume(returning: FleetResult(alias: alias, output: "(scp 启动失败: \(error.localizedDescription))", exitCode: -1))
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + Double(timeout) + 120) {
                    if p.isRunning { p.terminate() }
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                if let askpass { try? FileManager.default.removeItem(at: askpass) }
                let text = String(data: data, encoding: .utf8) ?? ""
                let msg = text.trimmingCharacters(in: .whitespacesAndNewlines)
                cont.resume(returning: FleetResult(
                    alias: alias,
                    output: msg.isEmpty ? (p.terminationStatus == 0 ? "\(verb)完成" : "\(verb)失败(退出码 \(p.terminationStatus))") : msg,
                    exitCode: p.terminationStatus))
            }
        }
    }

    private static func runOne(alias: String, password: String?, command: String, timeout: Int) async -> FleetResult {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                var args = ["-o", "StrictHostKeyChecking=accept-new",
                            "-o", "ConnectTimeout=\(timeout)",
                            "-o", "NumberOfPasswordPrompts=1"]
                var env = ProcessInfo.processInfo.environment
                var askpass: URL?
                if let password, !password.isEmpty, let script = makeAskpassScript() {
                    askpass = script
                    env["SSH_ASKPASS"] = script.path
                    env["SSH_ASKPASS_REQUIRE"] = "force"
                    env["WIRELINE_ASKPASS_PW"] = password
                } else {
                    args = ["-o", "BatchMode=yes"] + args   // key-only: never block on a prompt
                }
                args.append(alias)
                args.append(command)
                p.arguments = args
                p.environment = env
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch {
                    cont.resume(returning: FleetResult(alias: alias, output: "(启动失败: \(error.localizedDescription))", exitCode: -1))
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + Double(timeout) + 10) {
                    if p.isRunning { p.terminate() }
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                if let askpass { try? FileManager.default.removeItem(at: askpass) }
                let text = String(data: data, encoding: .utf8) ?? ""
                cont.resume(returning: FleetResult(alias: alias,
                                                   output: text.trimmingCharacters(in: .whitespacesAndNewlines),
                                                   exitCode: p.terminationStatus))
            }
        }
    }

    private static func makeAskpassScript() -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wireline-fleet-askpass-\(UUID().uuidString).sh")
        let script = "#!/bin/sh\nprintf '%s\\n' \"$WIRELINE_ASKPASS_PW\"\n"
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            return url
        } catch { return nil }
    }
}
