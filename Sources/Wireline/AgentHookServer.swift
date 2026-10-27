import AppKit
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

    /// SSH: merge the in-band (OSC) hooks into the host's ~/.claude/settings.json
    /// over SFTP, backing up the old file. Only from an explicit menu command.
    /// Returns false when they were already there.
    static func installRemoteClaudeHooks(host: Host, store: HostStore) async throws -> Bool {
        try await FileBrowserModel.withConnection(host: host, store: store) { conn in
            let path = ".claude/settings.json"
            let old: Data? = await conn.stat(path) != nil ? try await conn.download(path) : nil
            guard let new = try AgentHooks.merged(settingsJSON: old, remote: true) else { return false }
            try await conn.makeDirectoryIfMissing(".claude")
            if let old { try await conn.upload(path + ".wireline-backup", data: old) }
            try await conn.upload(path, data: new)
            return true
        }
    }

    /// The context-menu command: confirm, install, report.
    static func confirmRemoteInstall(alias: String) {
        let loc = Localizer.shared
        guard let store = HostStore.current, let host = store.hosts.first(where: { $0.alias == alias }) else { return }
        let ask = NSAlert()
        ask.messageText = loc.t("在 \(alias) 上安装 Claude Code hooks？", "Install Claude Code hooks on \(alias)?")
        ask.informativeText = loc.t(
            "通过 SFTP 往远端 ~/.claude/settings.json 合并 UserPromptSubmit / Notification / Stop 三个 hook（保留已有 hooks，旧文件备份为 settings.json.wireline-backup）。hook 把状态以终端转义序列写回本标签，其他终端会忽略。",
            "Merges UserPromptSubmit / Notification / Stop hooks into the remote ~/.claude/settings.json over SFTP (your hooks are kept; the old file is saved as settings.json.wireline-backup). The hooks report state back to this tab as a terminal escape sequence, which other terminals ignore.")
        ask.addButton(withTitle: loc.t("安装", "Install"))
        ask.addButton(withTitle: loc.t("取消", "Cancel"))
        guard ask.runModal() == .alertFirstButtonReturn else { return }
        Task {
            let done = NSAlert()
            do {
                let changed = try await installRemoteClaudeHooks(host: host, store: store)
                done.messageText = changed ? loc.t("已安装", "Installed") : loc.t("已经装过了", "Already installed")
                done.informativeText = loc.t("在 \(alias) 上新启动的 Claude Code 生效。", "Applies to Claude Code started on \(alias) from now on.")
            } catch {
                done.alertStyle = .warning
                done.messageText = loc.t("安装失败", "Couldn't install")
                done.informativeText = error.localizedDescription
            }
            done.runModal()
        }
    }

    static var hooksPresent: Bool {
        AgentHooks.hasAny(settingsJSON: try? Data(contentsOf: claudeSettingsURL))
    }

    /// Take out only Wireline's hooks, after backing up the file.
    static func uninstallClaudeHooks() throws {
        let url = claudeSettingsURL
        let old = try? Data(contentsOf: url)
        guard let old, let new = try AgentHooks.removed(settingsJSON: old) else { return }
        try old.write(to: url.appendingPathExtension("wireline-backup"), options: .atomic)
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
            HStack(spacing: 8) {
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
                        refresh()
                    }
                    .buttonStyle(.wlSecondary)
                }
                if present {
                    Button(loc("卸载", "Uninstall")) {
                        do {
                            try AgentHookServer.uninstallClaudeHooks()
                            error = nil
                        } catch {
                            self.error = loc("卸载失败：", "Couldn't uninstall: ") + error.localizedDescription
                        }
                        refresh()
                    }
                    .buttonStyle(.wlSecondary)
                    .help(loc("只移除 Wireline 加的 hooks，其余保留；原文件备份为 settings.json.wireline-backup",
                              "Removes only Wireline's hooks; the old file is backed up as settings.json.wireline-backup"))
                }
            }
        }
        .onAppear { refresh() }
    }

    @State private var present = AgentHookServer.hooksPresent

    private func refresh() {
        installed = AgentHookServer.hooksInstalled
        present = AgentHookServer.hooksPresent
    }
}
