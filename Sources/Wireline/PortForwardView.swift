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
                    Text(loc("$ 新建隧道", "$ new tunnel")).font(WL.body).foregroundStyle(WL.green)
                }.buttonStyle(.plain)
                Spacer()
                Text(loc("\(forwards.forwards.count) 条", "\(forwards.forwards.count)")).font(WL.small).foregroundStyle(WL.textDim)
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            Rectangle().fill(WL.border).frame(height: 1)

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
                    VStack(spacing: 0) {
                        ForEach(forwards.forwards) { forward in
                            ForwardRow(forward: forward) {
                                forwards.toggle(forward, host: store.hosts.first { $0.alias == forward.hostAlias })
                            } onEdit: {
                                editing = forward; showEditor = true
                            } onDelete: {
                                forwards.remove(forward)
                            }
                            Rectangle().fill(WL.border).frame(height: 1)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showEditor) {
            ForwardEditor(existing: editing)
                .environment(store)
                .environment(forwards)
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
            Button(action: onToggle) {
                Text(running ? "[\(loc("停止", "Stop"))]" : "[\(loc("启动", "Start"))]").font(WL.small)
                    .foregroundStyle(running ? WL.red : WL.green)
            }.buttonStyle(.plain)
            BracketButton(loc("编辑", "Edit"), action: onEdit)
            BracketButton(loc("删除", "Delete"), action: onDelete)
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ForwardEditor: View {
    @Environment(HostStore.self) private var store
    @Environment(ForwardStore.self) private var forwards
    @Environment(Localizer.self) private var loc
    @Environment(\.dismiss) private var dismiss
    let existing: PortForward?

    @State private var hostAlias = ""
    @State private var label = ""
    @State private var localPort = ""
    @State private var remoteHost = "127.0.0.1"
    @State private var remotePort = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(existing == nil ? loc("新建隧道", "New Tunnel") : loc("编辑隧道", "Edit Tunnel"))
                .font(WL.body.weight(.semibold)).foregroundStyle(WL.green)
                .padding(.horizontal, 20).padding(.top, 22).padding(.bottom, 14)
            Rectangle().fill(WL.border).frame(height: 1)

            VStack(alignment: .leading, spacing: 14) {
                field(loc("跳板/主机", "Via host")) {
                    Picker("", selection: $hostAlias) {
                        Text(loc("选择主机…", "Select host…")).tag("")
                        ForEach(store.hosts) { Text($0.alias).tag($0.alias) }
                    }
                    .labelsHidden().font(WL.body)
                }
                field(loc("备注", "Label")) { themedField(loc("可选，如 Prod DB", "optional, e.g. Prod DB"), $label) }
                field(loc("本地端口", "Local port")) { themedField(loc("如 5432", "e.g. 5432"), $localPort) }
                field(loc("远端主机", "Remote host")) { themedField(loc("主机可达的服务地址", "service reachable from the host"), $remoteHost) }
                field(loc("远端端口", "Remote port")) { themedField(loc("如 5432", "e.g. 5432"), $remotePort) }
            }
            .padding(18)

            Spacer()
            Rectangle().fill(WL.border).frame(height: 1)
            HStack(spacing: 18) {
                Spacer()
                BracketButton(loc("取消", "Cancel")) { dismiss() }
                Button(action: save) {
                    Text(existing == nil ? "[\(loc("添加", "Add"))]" : "[\(loc("保存", "Save"))]").font(WL.small)
                        .foregroundStyle(canSave ? WL.green : WL.textDim)
                }.buttonStyle(.plain).disabled(!canSave)
            }.padding(.horizontal, 20).padding(.vertical, 18)
        }
        .frame(width: 460, height: 430)
        .background(WL.bg)
        .preferredColorScheme(.dark)
        .onAppear(perform: populate)
    }

    private var canSave: Bool {
        !hostAlias.isEmpty && Int(localPort) != nil && Int(remotePort) != nil
    }

    private func field<V: View>(_ label: String, @ViewBuilder _ content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(WL.small).foregroundStyle(WL.textDim)
            content()
        }
    }

    private func themedField(_ prompt: String, _ text: Binding<String>) -> some View {
        TextField("", text: text, prompt: Text(prompt).foregroundStyle(WL.textDim))
            .textFieldStyle(.plain).font(WL.body).foregroundStyle(WL.textPrimary)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(WL.surface, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(WL.border, lineWidth: 1))
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
