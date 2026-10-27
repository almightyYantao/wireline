import Foundation
import Observation
import WirelineCore

/// Listens on `AgentHooks.socketPath` for Claude Code hook events from local
/// panes (`nc -U`, one line per connection) and hands them to the island,
/// whose tracker then trusts them over its guesses.
@MainActor
final class AgentHookServer {
    static let shared = AgentHookServer()

    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clients: [ObjectIdentifier: AgentConnection] = [:]
    /// Set once the socket is up; local shells only get the env vars then.
    private(set) var listening = false

    func start(path: String = AgentHooks.socketPath) {
        guard listenFD < 0 else { return }
        // Another Wireline already serves it: leave its socket alone.
        if let fd = try? AgentConnection.connect(path: path) { close(fd); return }
        do {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            listenFD = try AgentConnection.listen(path: path)
        } catch {
            return
        }
        let src = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: .main)
        src.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.acceptAll() } }
        acceptSource = src
        src.resume()
        listening = true
    }

    private func acceptAll() {
        while true {
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else { return }
            let conn = AgentConnection(fd: fd, queue: .main)
            guard conn.peerUID == getuid() else { conn.close(); continue }
            var buffer: [UInt8] = []
            let key = ObjectIdentifier(conn)
            conn.onBytes = { [weak conn] bytes in
                MainActor.assumeIsolated {
                    buffer += bytes
                    guard let nl = buffer.firstIndex(of: 0x0A) else {
                        if buffer.count > 256 * 1024 { conn?.close() }
                        return
                    }
                    if let msg = AgentHooks.parse(String(decoding: buffer[..<nl], as: UTF8.self)) {
                        IslandCenter.shared.agentHook(msg.sessionID, msg.event)
                    }
                    conn?.close()
                }
            }
            conn.onClose = { [weak self] in
                MainActor.assumeIsolated { self?.clients[key] = nil }
            }
            clients[key] = conn
            conn.start()
        }
    }

    /// For a local shell's environment.
    func environment(for session: UUID) -> [String] {
        guard listening else { return [] }
        return ["\(AgentHooks.sessionEnv)=\(session.uuidString)", "\(AgentHooks.socketEnv)=\(AgentHooks.socketPath)"]
    }

    // MARK: - ~/.claude/settings.json

    static var claudeSettingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    static var hooksInstalled: Bool {
        AgentHooks.isInstalled(settingsJSON: try? Data(contentsOf: claudeSettingsURL))
    }

    /// Add Wireline's hooks, keeping everything else. A backup of the old
    /// file sits next to it.
    static func installClaudeHooks() throws {
        let url = claudeSettingsURL
        let old = try? Data(contentsOf: url)
        guard let new = try AgentHooks.merged(settingsJSON: old) else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let old { try old.write(to: url.appendingPathExtension("wireline-backup"), options: .atomic) }
        try new.write(to: url, options: .atomic)
    }
}

import SwiftUI

/// Settings → General: put Wireline's hooks into ~/.claude/settings.json.
struct ClaudeHooksRow: View {
    @Environment(Localizer.self) private var loc
    @State private var installed = AgentHookServer.hooksInstalled
    @State private var error: String?

    var body: some View {
        WLFormRow(loc("Claude Code 精确状态", "Claude Code exact status"),
                  detail: error ?? loc("往 ~/.claude/settings.json 合并 hooks（保留你已有的 hooks），本地标签里的 Claude Code 会直接报告工作中 / 等你 / 完成。新开的本地标签生效。",
                                       "Merges hooks into ~/.claude/settings.json (your own hooks are kept) so Claude Code in local tabs reports working / waiting / done itself. Applies to newly opened local tabs.")) {
            if installed {
                Label(loc("已安装", "Installed"), systemImage: "checkmark.circle.fill")
                    .font(WL.small).foregroundStyle(WL.green)
            } else {
                Button(loc("为 Claude Code 安装 hooks", "Install hooks for Claude Code")) {
                    do {
                        try AgentHookServer.installClaudeHooks()
                        error = nil
                    } catch {
                        self.error = loc("安装失败：", "Couldn't install: ") + error.localizedDescription
                    }
                    installed = AgentHookServer.hooksInstalled
                }
                .buttonStyle(.wlSecondary)
            }
        }
        .onAppear { installed = AgentHookServer.hooksInstalled }
    }
}
