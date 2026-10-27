import Foundation
import WirelineCore

/// Completion data for SSH panes: remote history and directory listings over
/// a private SFTP connection per host. Never prompts — hosts that need Touch
/// ID or a typed password are skipped. Answers within `timeout` from what it
/// has; slow fetches keep filling the cache for the next keystroke.
actor RemoteCompletionProvider {
    static let shared = RemoteCompletionProvider()

    private struct HostState {
        var conn: SFTPConnection?
        var connecting: Task<SFTPConnection?, Never>?
        var failedAt: Date?
        var history: (Date, [String])?
        var historyTask: Task<Void, Never>?
        var listings: [String: (Date, [String])] = [:]
        var listingTasks: [String: Task<[String], Never>] = [:]
        var typed: [String] = []
    }

    private var hosts: [String: HostState] = [:]
    static let timeout: Duration = .milliseconds(600)

    func record(_ line: String, alias: String) {
        var s = hosts[alias] ?? HostState()
        s.typed.removeAll { $0 == line }
        s.typed.insert(line, at: 0)
        if s.typed.count > 500 { s.typed.removeLast() }
        hosts[alias] = s
    }

    func data(for ctx: CompletionContext, alias: String, cwd: String?,
              credential: SFTPConnection.Credential?, hostname: String, port: Int, user: String) async -> CompletionData {
        let needs = CompletionEngine.needs(for: ctx)
        var d = CompletionData()
        let target = (credential: credential, hostname: hostname, port: port, user: user)
        if needs.contains(.history) {
            if hosts[alias]?.history == nil || Date().timeIntervalSince(hosts[alias]!.history!.0) > 120 {
                startHistory(alias, target)
            }
            d.history = (hosts[alias]?.typed ?? []) + (hosts[alias]?.history?.1 ?? [])
        }
        if needs.contains(.paths), let dir = RemoteCompletionPaths.directory(for: ctx.current, cwd: cwd) {
            d.pathEntries = await listing(dir, alias: alias, target)
        }
        return d
    }

    private typealias Target = (credential: SFTPConnection.Credential?, hostname: String, port: Int, user: String)

    private func connection(_ alias: String, _ t: Target) async -> SFTPConnection? {
        var s = hosts[alias] ?? HostState()
        if let c = s.conn { return c }
        if let failed = s.failedAt, Date().timeIntervalSince(failed) < 60 { return nil }
        if let task = s.connecting { return await task.value }
        guard let cred = t.credential else { return nil }
        switch cred { case .password, .key: break; default: return nil }
        let task = Task<SFTPConnection?, Never> {
            let c = SFTPConnection()
            do {
                _ = try await c.connectAndList(hostname: t.hostname, port: t.port, user: t.user, credential: cred)
                return c
            } catch { return nil }
        }
        s.connecting = task
        hosts[alias] = s
        let c = await task.value
        hosts[alias]?.connecting = nil
        hosts[alias]?.conn = c
        if c == nil { hosts[alias]?.failedAt = Date() }
        return c
    }

    private func startHistory(_ alias: String, _ t: Target) {
        guard hosts[alias]?.historyTask == nil else { return }
        let task = Task {
            var lines: [String] = []
            if let c = await connection(alias, t) {
                for f in [".zsh_history", ".bash_history"] {
                    guard let st = await c.stat(f), !st.isDir else { continue }
                    guard st.size < 4 << 20, let data = try? await c.download(f) else { continue }
                    lines += CompletionParsers.history(String(decoding: data.suffix(1 << 20), as: UTF8.self))
                }
            }
            finishHistory(alias, lines)
        }
        hosts[alias, default: HostState()].historyTask = task
    }

    private func finishHistory(_ alias: String, _ lines: [String]) {
        hosts[alias]?.history = (Date(), lines)
        hosts[alias]?.historyTask = nil
    }

    private func listing(_ dir: String, alias: String, _ t: Target) async -> [String] {
        if let (at, names) = hosts[alias]?.listings[dir], Date().timeIntervalSince(at) < 15 { return names }
        let task: Task<[String], Never>
        if let running = hosts[alias]?.listingTasks[dir] {
            task = running
        } else {
            task = Task {
                guard let c = await connection(alias, t), let entries = try? await c.list(dir) else { return [] }
                let names = entries.prefix(2000).map { $0.isDir ? $0.name + "/" : $0.name }
                storeListing(alias, dir, names)
                return names
            }
            hosts[alias, default: HostState()].listingTasks[dir] = task
        }
        // Answer in time or with nothing; the task still fills the cache.
        return await withTaskGroup(of: [String]?.self) { group in
            group.addTask { await task.value }
            group.addTask { try? await Task.sleep(for: Self.timeout); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? []
        }
    }

    private func storeListing(_ alias: String, _ dir: String, _ names: [String]) {
        hosts[alias]?.listings[dir] = (Date(), names)
        hosts[alias]?.listingTasks[dir] = nil
        if (hosts[alias]?.listings.count ?? 0) > 200 { hosts[alias]?.listings.removeAll() }
    }

    func reset(_ alias: String) async {
        let c = hosts[alias]?.conn
        hosts[alias]?.conn = nil
        hosts[alias]?.listings = [:]
        await c?.close()
    }
}
