import SwiftUI

/// Registers Wireline's MCP server with the clients users run. Each writes the
/// user's own client config, so it only ever runs from a button press.
enum MCPClientSetup {
    /// `wireline-mcp`, beside the app's binary (Contents/MacOS in the bundle,
    /// the build directory in development).
    static var serverPath: String {
        (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .deletingLastPathComponent().appendingPathComponent("wireline-mcp").path
    }

    /// For any other client: the usual `mcpServers` JSON.
    static var genericJSON: String {
        """
        {
          "mcpServers": {
            "wireline": { "command": "\(serverPath)" }
          }
        }
        """
    }

    struct Outcome { var ok: Bool; var message: String }

    // MARK: Claude Code

    /// Through the user's login shell, so `claude` is found wherever it's installed.
    private static func zsh(_ command: String) async -> (status: Int32, output: String) {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/zsh")
                p.arguments = ["-lc", command]
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch { cont.resume(returning: (-1, error.localizedDescription)); return }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: (p.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
        }
    }

    static func addToClaudeCode() async -> Outcome {
        guard await zsh("command -v claude").status == 0 else {
            return Outcome(ok: false, message: "没找到 claude 命令。请先安装 Claude Code，或手动执行：claude mcp add --scope user wireline -- \"\(serverPath)\"")
        }
        if await zsh("claude mcp get wireline").status == 0 {
            return Outcome(ok: true, message: "Claude Code 里已经有 wireline 了。")
        }
        let r = await zsh("claude mcp add --scope user wireline -- " + MCPServerTools.shellQuote(serverPath))
        return r.status == 0
            ? Outcome(ok: true, message: "已添加到 Claude Code（用户级，所有项目可用）。新开的 Claude Code 会话里就能用。")
            : Outcome(ok: false, message: "添加失败：" + r.output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: Codex

    static var codexConfig: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml")
    }

    static func addToCodex() -> Outcome {
        let url = codexConfig
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if existing.contains("[mcp_servers.wireline]") {
            return Outcome(ok: true, message: "Codex 里已经有 wireline 了。")
        }
        let escaped = serverPath.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let block = (existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n")
            + "\n# Added by Wireline\n[mcp_servers.wireline]\ncommand = \"\(escaped)\"\n"
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !existing.isEmpty {
                let backup = url.appendingPathExtension("wireline-backup")
                try? FileManager.default.removeItem(at: backup)
                try FileManager.default.copyItem(at: url, to: backup)
            }
            try (existing + block).write(to: url, atomically: true, encoding: .utf8)
            return Outcome(ok: true, message: "已写入 \(url.path)" + (existing.isEmpty ? "。" : "（原文件备份为 config.toml.wireline-backup）。"))
        } catch {
            return Outcome(ok: false, message: "写入 \(url.path) 失败：\(error.localizedDescription)")
        }
    }
}

/// Settings → AI → "MCP server": the switch, who's connected, and one-click
/// registration with Claude Code / Codex.
struct MCPServerSection: View {
    @Environment(Localizer.self) private var loc
    @State private var settings = MCPServerSettings.shared
    @State private var host = MCPServerHost.shared
    @State private var status: MCPClientSetup.Outcome?
    @State private var working = false

    var body: some View {
        WLFormSection(loc("对外开放（MCP）", "MCP Server"),
                      footer: loc("让 Claude Code、Codex 等外部 AI 通过 MCP 使用 Wireline：查看会话和主机、读输出、读远程文件。现阶段只开放只读工具；发出的内容按上面的「隐私」档位脱敏。",
                                  "Let Claude Code, Codex and other AI clients use Wireline over MCP: sessions, hosts, output, remote files. Read-only tools for now; what they receive is masked per the Privacy setting.")) {
            Toggle(isOn: $settings.enabled) {
                Text(loc("允许外部 AI 使用 Wireline", "Allow AI clients to use Wireline")).font(WL.body).foregroundStyle(WL.textPrimary)
            }
            .toggleStyle(.wlSwitch).frame(minHeight: 38).wlConfigLocked("mcp-server")
            WLFormDivider()
            WLFormRow(loc("添加到客户端", "Add to a client"),
                      detail: host.lastError.map { loc("监听失败：", "Can't listen: ") + $0 }
                          ?? loc("当前连接的客户端：\(host.clientCount)", "Connected clients: \(host.clientCount)")) {
                HStack(spacing: 6) {
                    Button("Claude Code") {
                        working = true
                        Task { status = await MCPClientSetup.addToClaudeCode(); working = false }
                    }
                    Button("Codex") { status = MCPClientSetup.addToCodex() }
                    Button(loc("复制配置", "Copy JSON")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(MCPClientSetup.genericJSON, forType: .string)
                        status = .init(ok: true, message: loc("已复制，粘贴到客户端的 MCP 配置里即可。", "Copied — paste it into the client's MCP config."))
                    }
                }
                .buttonStyle(.wlSecondary).disabled(working)
            }
            if let status {
                Text(status.message)
                    .font(WL.caption).foregroundStyle(status.ok ? WL.textDim : WL.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 6)
            }
        }
    }
}
