import SwiftUI
import WirelineCore

struct PortForwardView: View {
    @Environment(HostStore.self) private var store
    @Environment(ForwardStore.self) private var forwards
    @Environment(Localizer.self) private var loc
    @State private var editing: PortForward?
    @State private var showEditor = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button { editing = nil; showEditor = true } label: {
                    Label(loc("新建隧道", "New Tunnel"), systemImage: "plus").font(WL.small.weight(.medium))
                }.buttonStyle(.wlPill())
                Spacer()
                Text(loc("\(forwards.forwards.count) 条", "\(forwards.forwards.count)")).font(WL.small).foregroundStyle(WL.textDim)
            }
            .padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 4)

            if forwards.forwards.isEmpty {
                VStack(spacing: 8) {
                    Text(loc("暂无隧道", "No tunnels")).font(WL.mono(16, .bold)).foregroundStyle(WL.textDim)
                    Text(loc("把本地端口映射到远端服务，可经跳板机访问内网。",
                             "Map a local port to a remote service, optionally via a jump host."))
                        .font(WL.small).foregroundStyle(WL.textDim)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    WLListCard {
                        ForEach(forwards.forwards) { forward in
                            ForwardRow(forward: forward) {
                                forwards.toggle(forward, host: store.hosts.first { $0.alias == forward.hostAlias })
                            } onEdit: {
                                editing = forward; showEditor = true
                            } onDelete: {
                                forwards.remove(forward)
                            }
                        }
                    }
                    .padding(.horizontal, 20).padding(.vertical, 12)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .wlModal(isPresented: $showEditor) {
            ForwardEditor(existing: editing)
        }
    }
}

struct ForwardRow: View {
    @Environment(ForwardStore.self) private var forwards
    @Environment(Localizer.self) private var loc
    let forward: PortForward
    var onToggle: () -> Void
    var onEdit: () -> Void
    var onDelete: () -> Void
    @State private var hover = false

    private var running: Bool { forwards.isRunning(forward) }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: running ? "bolt.horizontal.circle.fill" : "bolt.horizontal.circle")
                .foregroundStyle(running ? WL.green : WL.textDim)
                .font(.system(size: 16))
            VStack(alignment: .leading, spacing: 3) {
                Text(forward.label ?? "localhost:\(forward.localPort)")
                    .font(WL.body).foregroundStyle(WL.textPrimary)
                Text("127.0.0.1:\(forward.localPort) → \(forward.remoteHost):\(forward.remotePort)  via \(forward.hostAlias)")
                    .font(WL.caption).foregroundStyle(WL.textDim)
                if case .failed(let msg) = forwards.states[forward.id] {
                    Text(msg).font(WL.caption).foregroundStyle(WL.red).lineLimit(2)
                }
            }
            Spacer()
            BracketButton(loc("编辑", "Edit"), action: onEdit)
            BracketButton(loc("删除", "Delete"), action: onDelete)
            Button(running ? loc("停止", "Stop") : loc("启动", "Start"), action: onToggle)
                .buttonStyle(.wlChip(on: true, tint: running ? WL.red : WL.green))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .wlRowHighlight(hover: hover)
        .wlHover($hover)
    }
}

struct ForwardEditor: View {
    @Environment(HostStore.self) private var store
    @Environment(ForwardStore.self) private var forwards
    @Environment(Localizer.self) private var loc
    @Environment(\.wlDismiss) private var dismiss
    let existing: PortForward?

    @State private var hostAlias = ""
    @State private var label = ""
    @State private var localPort = ""
    @State private var remoteHost = "127.0.0.1"
    @State private var remotePort = ""

    var body: some View {
        WLSheet(existing == nil ? loc("新建隧道", "New Tunnel") : loc("编辑隧道", "Edit Tunnel"),
                subtitle: loc("把本地端口经 SSH 映射到远端服务", "Map a local port to a remote service over SSH"),
                symbol: "point.topleft.down.to.point.bottomright.curvepath", width: 460, height: 470,
                onClose: { dismiss() }) {
            WLFormSection(loc("经由", "Via")) {
                WLFormRow(loc("跳板/主机", "Via host")) {
                    WLMenuPicker(selection: $hostAlias,
                                 options: [WLOption("", loc("选择主机…", "Select host…"))]
                                    + store.sshHosts.map { WLOption($0.alias, $0.alias) },
                                 minWidth: 200)
                }
                WLFormDivider()
                row(loc("备注", "Label")) { themedField(loc("可选，如 Prod DB", "optional, e.g. Prod DB"), $label) }
            }
            WLFormSection(loc("端口映射", "Mapping"),
                          footer: loc("远端主机填从所选主机可达的地址，如 127.0.0.1。",
                                      "The remote host is resolved from the selected host, e.g. 127.0.0.1.")) {
                row(loc("本地端口", "Local port")) { themedField(loc("如 5432", "e.g. 5432"), $localPort) }
                WLFormDivider()
                row(loc("远端主机", "Remote host")) { themedField(loc("主机可达的服务地址", "service reachable from the host"), $remoteHost) }
                WLFormDivider()
                row(loc("远端端口", "Remote port")) { themedField(loc("如 5432", "e.g. 5432"), $remotePort) }
            }
        } footer: {
            Spacer()
            Button(loc("取消", "Cancel")) { dismiss() }
                .buttonStyle(.wlSecondary).keyboardShortcut(.cancelAction)
            Button(existing == nil ? loc("添加", "Add") : loc("保存", "Save"), action: save)
                .buttonStyle(.wlPrimary).keyboardShortcut(.defaultAction)
                .disabled(!canSave)
        }
        .onAppear(perform: populate)
    }

    private var canSave: Bool {
        !hostAlias.isEmpty && Int(localPort) != nil && Int(remotePort) != nil
    }

    private func row<V: View>(_ label: String, @ViewBuilder _ content: () -> V) -> some View {
        WLFormRow(label) { content().frame(width: 220) }
    }

    private func themedField(_ prompt: String, _ text: Binding<String>) -> some View {
        TextField("", text: text, prompt: Text(prompt).foregroundStyle(WL.textDim))
            .wlField(font: WL.body)
    }

    private func populate() {
        guard let f = existing else { return }
        hostAlias = f.hostAlias
        label = f.label ?? ""
        localPort = String(f.localPort)
        remoteHost = f.remoteHost
        remotePort = String(f.remotePort)
    }

    private func save() {
        var f = existing ?? PortForward(hostAlias: hostAlias, localPort: 0,
                                        remoteHost: remoteHost, remotePort: 0)
        f.hostAlias = hostAlias
        f.label = label.isEmpty ? nil : label
        f.localPort = Int(localPort) ?? 0
        f.remoteHost = remoteHost
        f.remotePort = Int(remotePort) ?? 0
        if existing == nil { forwards.add(f) } else { forwards.update(f) }
        dismiss()
    }
}
