import Foundation

/// Result of running one command on one host.
public struct BatchResult: Identifiable, Sendable {
    public let id = UUID()
    public let alias: String
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let duration: TimeInterval

    public var succeeded: Bool { exitCode == 0 }

    public init(alias: String, exitCode: Int32, stdout: String, stderr: String, duration: TimeInterval) {
        self.alias = alias
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.duration = duration
    }
}

/// Runs a single command across many hosts concurrently and collects the
/// aggregated output. Concurrency is bounded so a 50-host fan-out doesn't
/// exhaust file descriptors.
public struct BatchExecutor: Sendable {
    public var sshPath: String
    public var maxConcurrent: Int
    public var connectTimeout: Int

    public init(sshPath: String = "/usr/bin/ssh", maxConcurrent: Int = 8, connectTimeout: Int = 10) {
        self.sshPath = sshPath
        self.maxConcurrent = max(1, maxConcurrent)
        self.connectTimeout = connectTimeout
    }

    /// Execute `command` on every host, streaming each result as it completes
    /// via `onResult` (called on an arbitrary task; hop to the main actor in UI).
    public func run(command: String, on hosts: [Host],
                    onResult: (@Sendable (BatchResult) -> Void)? = nil) async -> [BatchResult] {
        await withTaskGroup(of: BatchResult.self) { group in
            var results: [BatchResult] = []
            var index = 0
            var running = 0

            func addNext() {
                guard index < hosts.count else { return }
                let host = hosts[index]
                index += 1
                running += 1
                group.addTask { await Self.execute(sshPath: sshPath, host: host,
                                                    command: command, connectTimeout: connectTimeout) }
            }

            for _ in 0..<min(maxConcurrent, hosts.count) { addNext() }

            while running > 0 {
                guard let result = await group.next() else { break }
                running -= 1
                results.append(result)
                onResult?(result)
                addNext()
            }
            return results.sorted { $0.alias < $1.alias }
        }
    }

    static func execute(sshPath: String, host: Host, command: String,
                        connectTimeout: Int) async -> BatchResult {
        let start = Date()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshPath)
        process.arguments = SSHCommand.runArguments(for: host, command: command,
                                                     connectTimeout: connectTimeout)
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        // Never let a batch job block on an interactive password prompt.
        process.standardInput = FileHandle.nullDevice
        process.environment = {
            var env = ProcessInfo.processInfo.environment
            env["SSH_ASKPASS"] = "/usr/bin/false"
            return env
        }()

        do {
            try process.run()
        } catch {
            return BatchResult(alias: host.alias, exitCode: -1, stdout: "",
                               stderr: "Failed to launch ssh: \(error.localizedDescription)",
                               duration: Date().timeIntervalSince(start))
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return BatchResult(
            alias: host.alias,
            exitCode: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? "",
            duration: Date().timeIntervalSince(start)
        )
    }
}
