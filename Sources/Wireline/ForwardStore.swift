import Foundation
import Observation
import WirelineCore

/// Owns the user's configured port-forwarding rules and drives the underlying
/// `ssh -L` processes. Rules persist to Application Support as JSON — they are
/// session/runtime configuration, not part of a host's identity, so they stay
/// out of `~/.ssh/config`.
@Observable
@MainActor
final class ForwardStore {
    private(set) var forwards: [PortForward] = []
    var states: [UUID: ForwardState] = [:]

    private let manager = PortForwardManager()
    private let fileURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wireline", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.fileURL = base.appendingPathComponent("forwards.json")
        load()

        manager.onStateChange = { [weak self] id, state in
            Task { @MainActor in self?.states[id] = state }
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        forwards = (try? JSONDecoder().decode([PortForward].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(forwards) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func add(_ forward: PortForward) { forwards.append(forward); save() }

    func update(_ forward: PortForward) {
        if let idx = forwards.firstIndex(where: { $0.id == forward.id }) {
            forwards[idx] = forward; save()
        }
    }

    func remove(_ forward: PortForward) {
        manager.stop(forward.id)
        forwards.removeAll { $0.id == forward.id }
        states[forward.id] = nil
        save()
    }

    func isRunning(_ forward: PortForward) -> Bool { manager.isRunning(forward.id) }

    func toggle(_ forward: PortForward, store: HostStore) {
        if manager.isRunning(forward.id) {
            manager.stop(forward.id)
        } else {
            start(forward, store: store)
        }
    }

    func start(_ forward: PortForward, store: HostStore) {
        guard !manager.isRunning(forward.id) else { return }
        if let host = store.hosts.first(where: { $0.alias == forward.hostAlias }) {
            states[forward.id] = manager.start(forward, host: host, password: store.password(for: host))
        } else {
            states[forward.id] = .failed("Host '\(forward.hostAlias)' not found in ssh config.")
        }
    }

    /// At launch: bring up the tunnels marked to start automatically.
    func startAutoForwards(store: HostStore) {
        for f in forwards where f.autoStart { start(f, store: store) }
    }

    func stopAll() { manager.stopAll() }
}
