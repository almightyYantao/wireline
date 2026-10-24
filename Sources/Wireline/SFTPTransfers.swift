import Foundation
import Observation

/// The SFTP browser's transfer queue: one file at a time, in chunks, with
/// progress, pause / resume (from where it stopped) and retry.
@Observable
@MainActor
final class TransferQueue {
    enum Direction { case upload, download }
    enum State: Equatable { case queued, running, paused, done, failed(String) }

    struct Item: Identifiable {
        let id = UUID()
        let direction: Direction
        /// What the row shows: the file name, or its path inside a folder being copied.
        let name: String
        let remotePath: String
        let localURL: URL
        var total: UInt64
        var done: UInt64 = 0
        var state: State = .queued

        var fraction: Double {
            if state == .done { return 1 }
            return total == 0 ? 0 : min(1, Double(done) / Double(total))
        }
    }

    private(set) var items: [Item] = []
    private let conn: SFTPConnection
    private var runner: Task<Void, Never>?
    /// Heard after each item lands (the panes refresh).
    var onItemFinished: ((Item) -> Void)?
    /// Heard when nothing is left to run.
    var onIdle: (() -> Void)?

    init(conn: SFTPConnection) { self.conn = conn }

    /// Something is queued or moving.
    var isActive: Bool { items.contains { $0.state == .queued || $0.state == .running } }

    func enqueue(_ new: [Item]) {
        guard !new.isEmpty else { return }
        items += new
        pump()
    }

    func pause(_ id: UUID) {
        guard let i = index(id), items[i].state == .queued || items[i].state == .running else { return }
        items[i].state = .paused        // a running one stops after its current window
    }

    func resume(_ id: UUID) {
        guard let i = index(id) else { return }
        switch items[i].state {
        case .paused, .failed: items[i].state = .queued; pump()
        default: break
        }
    }

    func remove(_ id: UUID) { items.removeAll { $0.id == id } }   // a running one stops at its next window
    func clearFinished() { items.removeAll { $0.state == .done } }

    func cancelAll() {
        runner?.cancel()
        items.removeAll()
    }

    private func index(_ id: UUID) -> Int? { items.firstIndex { $0.id == id } }

    private func pump() {
        guard runner == nil else { return }
        runner = Task { [weak self] in
            while let self, !Task.isCancelled,
                  let next = self.items.first(where: { $0.state == .queued }) {
                await self.run(next.id)
            }
            self?.runner = nil
            self?.onIdle?()
        }
    }

    private func run(_ id: UUID) async {
        guard let i = index(id) else { return }
        items[i].state = .running
        let item = items[i]
        let step: @Sendable (UInt64) async -> Bool = { [weak self] n in
            await MainActor.run { self?.advance(id, by: n) ?? false }
        }
        do {
            let finished: Bool
            switch item.direction {
            case .download:
                finished = try await conn.download(item.remotePath, to: item.localURL, from: item.done, step: step)
            case .upload:
                finished = try await conn.upload(item.localURL, to: item.remotePath, from: item.done, step: step)
            }
            guard finished, let j = index(id) else { return }
            items[j].state = .done
            items[j].done = max(items[j].done, items[j].total)
            onItemFinished?(items[j])
        } catch {
            guard let j = index(id) else { return }
            let s = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            items[j].state = .failed(s.count > 120 ? String(s.prefix(120)) + "…" : s)
        }
    }

    /// A window landed: count it, and say whether to keep going.
    private func advance(_ id: UUID, by n: UInt64) -> Bool {
        guard !Task.isCancelled, let i = index(id) else { return false }
        items[i].done += n
        return items[i].state == .running
    }
}
