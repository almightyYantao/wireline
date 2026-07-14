import Foundation

/// Runtime state of a single tunnel.
public enum ForwardState: Sendable, Equatable {
    case stopped
    case running(pid: Int32)
    case failed(String)
}

/// Starts and stops `ssh -L` tunnels as long-lived child processes, tracking
/// which ones are live. This is the engine behind the graphical port-forwarding
/// panel: configure once, start/stop with one click.
public final class PortForwardManager: @unchecked Sendable {
    private let sshPath: String
    private var processes: [UUID: Process] = [:]
    private let lock = NSLock()

    /// Called when a tunnel's state changes (e.g. it dies unexpectedly).
    public var onStateChange: (@Sendable (UUID, ForwardState) -> Void)?

    public init(sshPath: String = "/usr/bin/ssh") {
        self.sshPath = sshPath
    }

    public func state(for id: UUID) -> ForwardState {
        lock.lock(); defer { lock.unlock() }
        guard let p = processes[id] else { return .stopped }
        return p.isRunning ? .running(pid: p.processIdentifier) : .stopped
    }

    public func isRunning(_ id: UUID) -> Bool {
        if case .running = state(for: id) { return true }
        return false
    }

    @discardableResult
    public func start(_ forward: PortForward, host: Host) -> ForwardState {
        lock.lock()
        if let existing = processes[forward.id], existing.isRunning {
            let pid = existing.processIdentifier
            lock.unlock()
            return .running(pid: pid)
        }
        lock.unlock()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshPath)
        process.arguments = SSHCommand.forwardArguments(for: host, forward: forward)
        process.standardInput = FileHandle.nullDevice
        let errPipe = Pipe()
        process.standardError = errPipe

        let id = forward.id
        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            self.lock.lock()
            self.processes[id] = nil
            self.lock.unlock()
            if proc.terminationStatus != 0 {
                let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                                 encoding: .utf8) ?? ""
                self.onStateChange?(id, .failed(err.isEmpty ? "ssh exited \(proc.terminationStatus)" : err))
            } else {
                self.onStateChange?(id, .stopped)
            }
        }

        do {
            try process.run()
        } catch {
            return .failed(error.localizedDescription)
        }
        lock.lock()
        processes[id] = process
        lock.unlock()
        let s = ForwardState.running(pid: process.processIdentifier)
        onStateChange?(id, s)
        return s
    }

    public func stop(_ id: UUID) {
        lock.lock()
        let process = processes[id]
        lock.unlock()
        process?.terminate()
    }

    public func stopAll() {
        lock.lock()
        let all = Array(processes.values)
        lock.unlock()
        all.forEach { $0.terminate() }
    }
}
