import Foundation
import Observation

/// A snapshot of a remote server's vitals.
struct ServerStats: Sendable, Equatable {
    var cpuPercent: Double?
    var memPercent: Double?
    var memTotalGB: Double?
    var remoteTime: String?
    var reachable: Bool = false
}

/// Polls a remote host's CPU / memory / time without disturbing the interactive
/// terminal, by reusing the terminal's SSH connection over its ControlMaster
/// socket (`ssh -S <socket> host <cmd>` — no re-auth, no new session).
@Observable
@MainActor
final class StatsMonitor {
    private(set) var stats = ServerStats()
    private var task: Task<Void, Never>?

    /// Command that samples /proc twice for CPU%, reads mem, and prints time.
    nonisolated static let command = """
    grep '^cpu ' /proc/stat; sleep 0.3; grep '^cpu ' /proc/stat; \
    grep -E '^MemTotal|^MemAvailable' /proc/meminfo; date +%H:%M:%S
    """

    func start(socket: String, alias: String) {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                let result = await StatsMonitor.poll(socket: socket, alias: alias)
                if let result { self?.stats = result }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    nonisolated private static func poll(socket: String, alias: String) async -> ServerStats? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                p.arguments = ["-S", socket, "-o", "BatchMode=yes", alias, command]
                let out = Pipe()
                p.standardOutput = out
                p.standardError = FileHandle.nullDevice
                p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch {
                    continuation.resume(returning: nil); return
                }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                guard p.terminationStatus == 0,
                      let text = String(data: data, encoding: .utf8) else {
                    continuation.resume(returning: ServerStats(reachable: false)); return
                }
                continuation.resume(returning: parse(text))
            }
        }
    }

    nonisolated private static func parse(_ text: String) -> ServerStats {
        var stats = ServerStats(reachable: true)
        let lines = text.split(separator: "\n").map(String.init)
        let cpuLines = lines.filter { $0.hasPrefix("cpu ") }
        if cpuLines.count >= 2,
           let a = cpuFields(cpuLines[0]), let b = cpuFields(cpuLines[1]) {
            let totalDelta = Double(b.total - a.total)
            let idleDelta = Double(b.idle - a.idle)
            if totalDelta > 0 {
                stats.cpuPercent = max(0, min(100, (1 - idleDelta / totalDelta) * 100))
            }
        }
        var memTotal: Double?, memAvail: Double?
        for line in lines {
            if line.hasPrefix("MemTotal") { memTotal = kbValue(line) }
            if line.hasPrefix("MemAvailable") { memAvail = kbValue(line) }
        }
        if let t = memTotal, let av = memAvail, t > 0 {
            stats.memPercent = max(0, min(100, (1 - av / t) * 100))
            stats.memTotalGB = t / 1024 / 1024
        }
        if let time = lines.last(where: { $0.range(of: #"^\d{2}:\d{2}:\d{2}$"#, options: .regularExpression) != nil }) {
            stats.remoteTime = time
        }
        return stats
    }

    nonisolated private static func cpuFields(_ line: String) -> (total: Int, idle: Int)? {
        let parts = line.split(separator: " ").compactMap { Int($0) }
        guard parts.count >= 4 else { return nil }
        let total = parts.reduce(0, +)
        let idle = parts[3]              // idle is the 4th numeric field
        return (total, idle)
    }

    nonisolated private static func kbValue(_ line: String) -> Double? {
        line.split(separator: " ").compactMap { Double($0) }.first
    }
}
