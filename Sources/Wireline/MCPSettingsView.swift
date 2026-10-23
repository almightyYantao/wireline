import SwiftUI

/// Management UI for MCP servers: list, connect/disconnect, add/edit/remove.
/// Presented as a modal card from Settings → AI.
struct MCPSettingsView: View {
    @Environment(Localizer.self) private var loc
    @State private var store = MCPStore.shared
    @State private var editing: MCPServerConfig?
    @State private var isNew = false
    var onClose: () -> Void = {}

    var body: some View {
        WLSheet(loc("MCP 服务器", "MCP Servers"),
                subtitle: loc("让 AI 调用外部工具", "Let the AI call external tools"),
                symbol: "point.3.connected.trianglepath.dotted", width: 560, height: 560,
                onClose: onClose) {
            WLFormSection("", footer: loc("MCP 让 AI 调用外部工具（filesystem / github / k8s…）。工具在本机通过 stdio 启动，密钥存 Keychain；写操作类调用会二次确认。",
                                          "MCP lets the AI call external tools (filesystem / github / k8s…). Servers launch locally over stdio, secrets live in the Keychain, and mutating calls ask first.")) {
                Toggle(isOn: Binding(get: { store.enabled }, set: { on in
                    store.enabled = on
                    Task { on ? await store.connectEnabled() : await store.disconnectAll() }
                })) {
                    Text(loc("启用 MCP", "Enable MCP")).font(WL.body).foregroundStyle(WL.textPrimary)
                }
                .toggleStyle(.wlSwitch)
                .frame(minHeight: 38).padding(.vertical, 4)
            }

            WLFormSection(loc("服务器", "Servers")) {
                if store.servers.isEmpty {
                    Text(loc("还没有配置 MCP server。", "No MCP servers configured yet."))
                        .font(WL.body).foregroundStyle(WL.textDim)
                        .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 30)
                } else {
                    ForEach(Array(store.servers.enumerated()), id: \.element.id) { i, s in
                        if i > 0 { WLFormDivider() }
                        serverRow(s)
                    }
                }
            }
        } footer: {
            Button {
                isNew = true
                editing = MCPServerConfig(name: "", command: "", args: [], envKeys: [], enabled: true)
            } label: {
                Label(loc("添加 Server", "Add Server"), systemImage: "plus")
            }
            .buttonStyle(.wlSecondary)
            Spacer()
            Button(loc("完成", "Done")) { onClose() }
                .buttonStyle(.wlPrimary).keyboardShortcut(.defaultAction)
        }
        .wlModal(item: $editing) { cfg in
            MCPServerEditor(config: cfg, isNew: isNew) { saved in
                if isNew { store.add(saved) } else { store.update(saved) }
                if store.enabled, saved.enabled { Task { await store.connect(saved.id) } }
                wlAnimate(Motion.flipOut) { editing = nil }
            } onCancel: { wlAnimate(Motion.flipOut) { editing = nil } }
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
            Text(s.kind == .http ? s.url : "\(s.command) \(s.args.joined(separator: " "))")
                .font(WL.mono(11)).foregroundStyle(WL.textDim).lineLimit(1)
            HStack(spacing: 6) {
                BracketButton(loc("重新连接", "Reconnect")) { Task { await store.connect(s.id) } }
                BracketButton(loc("断开", "Disconnect")) { Task { await store.disconnect(s.id) } }
                BracketButton(loc("编辑", "Edit")) { isNew = false; editing = s }
                Spacer()
                BracketButton(loc("删除", "Delete")) { store.remove(s) }
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 10)
    }

    private func statusColor(_ st: MCPConnState?) -> Color {
        switch st {
        case .connected: return WL.green
        case .connecting: return WL.amber
        case .failed: return WL.red
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
    @State private var headerRows: [EnvRow] = []
    @FocusState private var nameFocused: Bool

    private struct EnvRow: Identifiable { let id = UUID(); var key: String; var value: String }

    var body: some View {
        WLSheet(isNew ? loc("添加 MCP Server", "Add MCP Server") : loc("编辑 MCP Server", "Edit MCP Server"),
                subtitle: loc("本地 stdio 进程或远程 HTTP 服务", "A local stdio process or a remote HTTP server"),
                symbol: isNew ? "plus.square.on.square" : "slider.horizontal.3",
                width: 520, height: 520, onClose: onCancel) {
            WLFormSection(loc("基本", "General")) {
                stacked(loc("名称", "Name")) {
                    TextField("", text: $config.name, prompt: Text("github").foregroundStyle(WL.textDim))
                        .wlField(focus: $nameFocused)
                }
                WLFormDivider()
                WLSegmented(selection: $config.kind, options: [
                    WLOption(MCPKind.stdio, loc("本地 stdio", "Local stdio")),
                    WLOption(MCPKind.http, "HTTP"),
                ])
                .padding(.vertical, 10)
            }

            if config.kind == .stdio {
                WLFormSection(loc("启动", "Launch")) {
                    stacked(loc("命令", "Command")) { field("npx", $config.command) }
                    WLFormDivider()
                    stacked(loc("参数（空格分隔）", "Args (space-separated)")) {
                        field("-y @modelcontextprotocol/server-filesystem /path",
                              Binding(get: { argsText }, set: { argsText = $0 }))
                    }
                }
                keyValueSection(loc("环境变量", "Environment"),
                                footer: loc("值（密钥）存入 Keychain。", "Values (secrets) go to the Keychain."), $envRows)
            } else {
                WLFormSection(loc("连接", "Connection")) {
                    stacked(loc("服务地址 (URL)", "Server URL")) { field("https://example.com/mcp", $config.url) }
                }
                keyValueSection(loc("请求头", "Headers"),
                                footer: loc("值存入 Keychain，如 Authorization。", "Values are stored in the Keychain, e.g. Authorization."),
                                $headerRows)
            }
        } footer: {
            Spacer()
            Button(loc("取消", "Cancel")) { onCancel() }
                .buttonStyle(.wlSecondary).keyboardShortcut(.cancelAction)
            Button(loc("保存", "Save")) { save() }
                .buttonStyle(.wlPrimary).keyboardShortcut(.defaultAction)
                .disabled(!canSave)
        }
        .onAppear(perform: populate)
        .wlAutofocus($nameFocused)
    }

    private func keyValueSection(_ title: String, footer: String, _ rows: Binding<[EnvRow]>) -> some View {
        WLFormSection(title, footer: footer) {
            ForEach(rows) { $row in
                HStack(spacing: 8) {
                    TextField("KEY", text: $row.key)
                        .wlField(font: WL.mono(11))
                        .frame(width: 150)
                    SecureField(loc("值", "value"), text: $row.value)
                        .wlField(font: WL.mono(11))
                    Button { rows.wrappedValue.removeAll { $0.id == row.id } } label: {
                        Image(systemName: "trash").font(.system(size: 10))
                    }
                    .buttonStyle(.wlIcon(tint: WL.red, size: 24))
                    .help(loc("删除", "Remove"))
                }
                .padding(.vertical, 6)
                WLFormDivider()
            }
            Button { rows.wrappedValue.append(EnvRow(key: "", value: "")) } label: {
                Label(loc("添加", "Add"), systemImage: "plus")
            }
            .buttonStyle(.wlChip())
            .padding(.vertical, 8)
        }
    }

    /// Label above a full-width field.
    private func stacked<V: View>(_ label: String, @ViewBuilder _ content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(WL.small).foregroundStyle(WL.textDim)
            content()
        }
        .padding(.vertical, 10)
    }

    private func field(_ prompt: String, _ text: Binding<String>) -> some View {
        TextField("", text: text, prompt: Text(prompt).foregroundStyle(WL.textDim))
            .wlField()
    }

    private func populate() {
        argsText = config.args.joined(separator: " ")
        let store = MCPStore.shared
        envRows = config.envKeys.map { EnvRow(key: $0, value: store.envValue(key: $0, server: config.id)) }
        headerRows = config.headerKeys.map { EnvRow(key: $0, value: store.headerValue(name: $0, server: config.id)) }
    }

    private var canSave: Bool {
        guard !config.name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return config.kind == .stdio
            ? !config.command.trimmingCharacters(in: .whitespaces).isEmpty
            : !config.url.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func save() {
        let store = MCPStore.shared
        if config.kind == .stdio {
            config.args = argsText.split(separator: " ").map(String.init)
            let rows = envRows.filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
            config.envKeys = rows.map(\.key)
            for r in rows { store.setEnvValue(r.value, key: r.key, server: config.id) }
        } else {
            let rows = headerRows.filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
            config.headerKeys = rows.map(\.key)
            for r in rows { store.setHeaderValue(r.value, name: r.key, server: config.id) }
        }
        onSave(config)
    }
}
