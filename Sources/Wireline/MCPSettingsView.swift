import SwiftUI

/// Management UI for MCP servers: list, connect/disconnect, add/edit/remove.
/// Presented as a sheet from Settings → AI.
struct MCPSettingsView: View {
    @Environment(Localizer.self) private var loc
    @State private var store = MCPStore.shared
    @State private var editing: MCPServerConfig?
    @State private var isNew = false
    var onClose: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(WL.border).frame(height: 1)
            content
        }
        .frame(width: 560, height: 560)
        .background(WL.bg)
        .preferredColorScheme(.dark)
        .sheet(item: $editing) { cfg in
            MCPServerEditor(config: cfg, isNew: isNew) { saved in
                if isNew { store.add(saved) } else { store.update(saved) }
                if store.enabled, saved.enabled { Task { await store.connect(saved.id) } }
                editing = nil
            } onCancel: { editing = nil }
            .environment(loc)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("> mcp servers").font(WL.mono(15, .bold)).foregroundStyle(WL.green)
            Spacer()
            Toggle(isOn: Binding(get: { store.enabled }, set: { on in
                store.enabled = on
                Task { on ? await store.connectEnabled() : await store.disconnectAll() }
            })) {
                Text(loc("启用 MCP", "Enable MCP")).font(WL.small).foregroundStyle(WL.textPrimary)
            }.toggleStyle(.checkbox).tint(WL.green)
            Button(loc("完成", "Done")) { onClose() }.buttonStyle(.plain)
                .font(WL.small).foregroundStyle(WL.green)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(loc("MCP 让 AI 调用外部工具（filesystem / github / k8s…）。工具在本机通过 stdio 启动，密钥存 Keychain；写操作类调用会二次确认。",
                         "MCP lets the AI call external tools (filesystem / github / k8s…). Servers launch locally over stdio, secrets live in the Keychain, and mutating calls ask first."))
                    .font(WL.caption).foregroundStyle(WL.textDim)

                if store.servers.isEmpty {
                    Text(loc("还没有配置 MCP server。", "No MCP servers configured yet."))
                        .font(WL.body).foregroundStyle(WL.textDim)
                        .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 40)
                } else {
                    ForEach(store.servers) { s in serverRow(s) }
                }

                Button {
                    isNew = true
                    editing = MCPServerConfig(name: "", command: "", args: [], envKeys: [], enabled: true)
                } label: {
                    Label(loc("添加 Server", "Add Server"), systemImage: "plus")
                        .font(WL.small).foregroundStyle(WL.green)
                }
                .buttonStyle(.plain).padding(.top, 4)
            }
            .padding(18)
        }
    }

    private func serverRow(_ s: MCPServerConfig) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(statusColor(store.state[s.id])).frame(width: 8, height: 8)
                Text(s.name.isEmpty ? loc("(未命名)", "(unnamed)") : s.name)
                    .font(WL.body.weight(.semibold)).foregroundStyle(WL.textPrimary)
                Spacer()
                Text(statusText(store.state[s.id])).font(WL.caption).foregroundStyle(WL.textDim)
            }
            Text("\(s.command) \(s.args.joined(separator: " "))")
                .font(WL.mono(11)).foregroundStyle(WL.textDim).lineLimit(1)
            HStack(spacing: 14) {
                Button(loc("重新连接", "Reconnect")) { Task { await store.connect(s.id) } }
                Button(loc("断开", "Disconnect")) { Task { await store.disconnect(s.id) } }
                Button(loc("编辑", "Edit")) { isNew = false; editing = s }
                Button(loc("删除", "Delete"), role: .destructive) { store.remove(s) }
                Spacer()
            }
            .font(WL.caption).buttonStyle(.plain).foregroundStyle(WL.green)
        }
        .padding(12)
        .background(WL.surface, in: RoundedRectangle(cornerRadius: WL.radius(7)))
        .overlay(RoundedRectangle(cornerRadius: WL.radius(7)).stroke(WL.border, lineWidth: WL.borderWidth))
    }

    private func statusColor(_ st: MCPConnState?) -> Color {
        switch st {
        case .connected: return WL.green
        case .connecting: return WL.amber
        case .failed: return .red
        default: return WL.textDim
        }
    }

    private func statusText(_ st: MCPConnState?) -> String {
        switch st {
        case .connected(let n): return loc("已连接 · \(n) 个工具", "connected · \(n) tools")
        case .connecting: return loc("连接中…", "connecting…")
        case .failed(let m): return loc("失败：\(m.prefix(60))", "failed: \(m.prefix(60))")
        default: return loc("未连接", "stopped")
        }
    }
}

/// Add/edit one MCP server.
private struct MCPServerEditor: View {
    @Environment(Localizer.self) private var loc
    @State var config: MCPServerConfig
    let isNew: Bool
    var onSave: (MCPServerConfig) -> Void
    var onCancel: () -> Void

    @State private var argsText = ""
    @State private var envRows: [EnvRow] = []

    private struct EnvRow: Identifiable { let id = UUID(); var key: String; var value: String }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isNew ? "> add server" : "> edit server").font(WL.mono(14, .bold)).foregroundStyle(WL.green)
                Spacer()
            }.padding(.horizontal, 18).padding(.vertical, 14)
            Rectangle().fill(WL.border).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    field(loc("名称", "Name"), "github", $config.name)
                    field(loc("命令", "Command"), "npx", $config.command)
                    field(loc("参数（空格分隔）", "Args (space-separated)"), "-y @modelcontextprotocol/server-filesystem /path",
                          Binding(get: { argsText }, set: { argsText = $0 }))
                    envSection
                }
                .padding(18)
            }

            Rectangle().fill(WL.border).frame(height: 1)
            HStack {
                Spacer()
                Button(loc("取消", "Cancel")) { onCancel() }.buttonStyle(.plain).foregroundStyle(WL.textDim)
                Button(loc("保存", "Save")) { save() }.buttonStyle(.plain).foregroundStyle(WL.green)
                    .disabled(config.name.trimmingCharacters(in: .whitespaces).isEmpty || config.command.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .font(WL.small).padding(.horizontal, 18).padding(.vertical, 12)
        }
        .frame(width: 520, height: 480)
        .background(WL.bg)
        .onAppear(perform: populate)
    }

    private var envSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(loc("环境变量（密钥存 Keychain）", "Environment (secrets go to Keychain)"))
                    .font(WL.small).foregroundStyle(WL.textDim)
                Spacer()
                Button { envRows.append(EnvRow(key: "", value: "")) } label: {
                    Image(systemName: "plus").font(.system(size: 10)).foregroundStyle(WL.green)
                }.buttonStyle(.plain)
            }
            ForEach($envRows) { $row in
                HStack(spacing: 8) {
                    TextField("KEY", text: $row.key).textFieldStyle(.plain).font(WL.mono(11))
                        .frame(width: 150).padding(6)
                        .background(WL.surface, in: RoundedRectangle(cornerRadius: WL.radius(5)))
                    SecureField(loc("值", "value"), text: $row.value).textFieldStyle(.plain).font(WL.mono(11))
                        .padding(6).background(WL.surface, in: RoundedRectangle(cornerRadius: WL.radius(5)))
                    Button { envRows.removeAll { $0.id == row.id } } label: {
                        Image(systemName: "trash").font(.system(size: 10)).foregroundStyle(.red)
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    private func field(_ label: String, _ prompt: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(WL.small).foregroundStyle(WL.textDim)
            TextField("", text: text, prompt: Text(prompt).foregroundStyle(WL.textDim))
                .textFieldStyle(.plain).font(WL.mono(12)).foregroundStyle(WL.textPrimary)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(WL.surface, in: RoundedRectangle(cornerRadius: WL.radius(5)))
                .overlay(RoundedRectangle(cornerRadius: WL.radius(5)).stroke(WL.border, lineWidth: WL.borderWidth))
        }
    }

    private func populate() {
        argsText = config.args.joined(separator: " ")
        let store = MCPStore.shared
        envRows = config.envKeys.map { EnvRow(key: $0, value: store.envValue(key: $0, server: config.id)) }
    }

    private func save() {
        config.args = argsText.split(separator: " ").map(String.init)
        let store = MCPStore.shared
        let rows = envRows.filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
        config.envKeys = rows.map(\.key)
        for r in rows { store.setEnvValue(r.value, key: r.key, server: config.id) }
        onSave(config)
    }
}
