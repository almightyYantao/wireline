import Foundation
import Network

/// Online status of a host from the last reachability probe.
public enum HostStatus: Sendable, Equatable {
    case unknown
    case checking
    case online(latencyMS: Int)
    case offline
}

/// Probes host reachability by opening a TCP connection to the SSH port.
/// A successful handshake (or refusal that still proves the host is up) marks
/// the host online; a timeout marks it offline.
public struct ConnectivityChecker: Sendable {
    public var timeout: TimeInterval

    public init(timeout: TimeInterval = 4.0) {
        self.timeout = timeout
    }

    public func check(host: String, port: Int) async -> HostStatus {
        let timeout = self.timeout
        return await withCheckedContinuation { continuation in
            let started = DispatchTime.now()
            let params = NWParameters.tcp
            let endpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: UInt16(clamping: port)) ?? 22
            )
            let connection = NWConnection(to: endpoint, using: params)
            let queue = DispatchQueue(label: "wireline.connectivity")

            // Resume the continuation exactly once, cancelling the connection.
            let resumed = OSAllocatedUnfairLockBox(false)
            let finish: @Sendable (HostStatus) -> Void = { status in
                let already = resumed.withLock { done -> Bool in
                    if done { return true }
                    done = true
                    return false
                }
                if already { return }
                connection.cancel()
                continuation.resume(returning: status)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
                    finish(.online(latencyMS: Int(elapsed.rounded())))
                case .failed, .cancelled:
                    finish(.offline)
                default:
                    break
                }
            }

            queue.asyncAfter(deadline: .now() + timeout) { finish(.offline) }
            connection.start(queue: queue)
        }
    }

    public func check(_ host: Host) async -> HostStatus {
        await check(host: host.connectHostname, port: host.effectivePort)
    }
}

/// A tiny lock box so the closures above can flip a "resumed" flag safely.
final class OSAllocatedUnfairLockBox<Value>: @unchecked Sendable {
    private var value: Value
    private var lock = os_unfair_lock_s()
    init(_ value: Value) { self.value = value }
    func withLock<R>(_ body: (inout Value) -> R) -> R {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return body(&value)
    }
}
