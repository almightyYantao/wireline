import SwiftUI
import AppKit
import WirelineCore

struct PortForwardView: View {
    @Environment(HostStore.self) private var store
    @Environment(ForwardStore.self) private var forwards
    @Environment(Localizer.self) private var loc
    @State private var editing: PortForward?
    @State private var showEditor = false
    @State private var showDiscovery = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button { editing = nil; showEditor = true } label: {
                    Label(loc("新建隧道", "New Tunnel"), systemImage: "plus").font(WL.small.weight(.medium))
                }.buttonStyle(.wlPill())
                Button { showDiscovery = true } label: {
                    Label(loc("发现远端端口", "Discover Ports"), systemImage: "dot.radiowaves.left.and.right")
                        .font(WL.small.weight(.medium))
                }.buttonStyle(.wlPill())
                Spacer()
                Text(loc("\(forwards.forwards.count) 条", "\(forwards.forwards.count)")).font(WL.small).foregroundStyle(WL.textDim)
            }
            .padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 4)

            if forwards.forwards.isEmpty {
                VStack(spacing: 8) {
                    Text(loc("暂无隧道", "No tunnels")).font(WL.mono(16, .bold)).foregroundStyle(WL.textDim)
                    Text(loc("本地端口映射到远端服务（-L）、把本机服务开到服务器上（-R），或开一个 SOCKS 代理（-D）。",
                             "Reach a remote service locally (-L), expose a local one on the server (-R), or open a SOCKS proxy (-D)."))
                        .font(WL.small).foregroundStyle(WL.textDim)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    WLListCard {
                        ForEach(forwards.forwards) { forward in
                            ForwardRow(forward: forward) {
                                forwards.toggle(forward, store: store)
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
        .wlModal(isPresented: $showDiscovery) {
            PortDiscoverySheet()
        }
    }
}

extension PortForward.Kind {
    @MainActor func title(_ loc: Localizer) -> String {
        switch self {
        case .local:   return loc.t("本地 -L", "Local -L")
        case .remote:  return loc.t("远程 -R", "Remote -R")
        case .dynamic: return loc.t("SOCKS -D", "SOCKS -D")
        }
    }
}

/// Open `http://localhost:<port>` — the usual next step after forwarding a web port.
@MainActor func openLocalPort(_ port: Int) {
    if let url = URL(string: "http://localhost:\(port)") { NSWorkspace.shared.open(url) }
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

    private var defaultTitle: String {
        switch forward.kind {
        case .local:   return "localhost:\(forward.localPort)"
        case .remote:  return "\(forward.hostAlias):\(forward.remotePort)"
        case .dynamic: return "SOCKS :\(forward.localPort)"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: running ? "bolt.horizontal.circle.fill" : "bolt.horizontal.circle")
                .foregroundStyle(running ? WL.green : WL.textDim)
                .font(.system(size: 16))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(forward.label ?? defaultTitle)
                        .font(WL.body).foregroundStyle(WL.textPrimary)
                    Text(forward.kind.title(loc)).font(WL.caption).foregroundStyle(WL.textDim)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(WL.textPrimary.opacity(0.06), in: Capsule())
                    if forward.autoStart {
                        Image(systemName: "power.circle").font(.system(size: 10)).foregroundStyle(WL.textDim)
                            .help(loc("Wireline 启动时自动开启", "Starts with Wireline"))
                    }
                }
                Text(forward.kind == .remote ? forward.summary : "\(forward.summary)  via \(forward.hostAlias)")
                    .font(WL.caption).foregroundStyle(WL.textDim)
                if case .failed(let msg) = forwards.states[forward.id] {
                    Text(msg).font(WL.caption).foregroundStyle(WL.red).lineLimit(2)
                }
            }
            Spacer()
            if running, forward.kind == .local {
                BracketButton(loc("打开", "Open")) { openLocalPort(forward.localPort) }
            }
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

    @State private var kind: PortForward.Kind = .local
    @State private var hostAlias = ""
    @State private var label = ""
    @State private var localPort = ""
    @State private var remoteHost = "127.0.0.1"
    @State private var remotePort = ""
    @State private var autoStart = false

    var body: some View {
        WLSheet(existing == nil ? loc("新建隧道", "New Tunnel") : loc("编辑隧道", "Edit Tunnel"),
                subtitle: subtitle,
                symbol: "point.topleft.down.to.point.bottomright.curvepath", width: 460, height: 560,
                onClose: { dismiss() }) {
            WLSegmented(selection: $kind, options: PortForward.Kind.allCases.map { WLOption($0, $0.title(loc)) })
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
            mapping
            WLFormSection(loc("启动", "Startup")) {
                Toggle(isOn: $autoStart) {
                    WLFormRow(loc("随 Wireline 启动", "Start with Wireline"),
                              detail: loc("打开 Wireline 时自动开启这条隧道", "Bring this tunnel up when Wireline opens")) { EmptyView() }
                }
                .toggleStyle(.wlSwitch)
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

    private var subtitle: String {
        switch kind {
        case .local:   return loc("把本地端口经 SSH 映射到远端服务", "Map a local port to a remote service over SSH")
        case .remote:  return loc("让服务器上的端口连回这台 Mac 上的服务", "Let a port on the server reach a service on this Mac")
        case .dynamic: return loc("本地开一个 SOCKS5 代理，流量从所选主机出去", "A local SOCKS5 proxy whose traffic exits from the host")
        }
    }

    @ViewBuilder private var mapping: some View {
        switch kind {
        case .local:
            WLFormSection(loc("端口映射", "Mapping"),
                          footer: loc("远端主机填从所选主机可达的地址，如 127.0.0.1。",
                                      "The remote host is resolved from the selected host, e.g. 127.0.0.1.")) {
                row(loc("本地端口", "Local port")) { themedField(loc("如 5432", "e.g. 5432"), $localPort) }
                WLFormDivider()
                row(loc("远端主机", "Remote host")) { themedField(loc("主机可达的服务地址", "service reachable from the host"), $remoteHost) }
                WLFormDivider()
                row(loc("远端端口", "Remote port")) { themedField(loc("如 5432", "e.g. 5432"), $remotePort) }
            }
        case .remote:
            WLFormSection(loc("端口映射", "Mapping"),
                          footer: loc("服务器默认只在它自己的 127.0.0.1 上监听；要对外开放需服务器 sshd 开启 GatewayPorts。",
                                      "The server listens on its own loopback unless its sshd enables GatewayPorts.")) {
                row(loc("服务器端口", "Server port")) { themedField(loc("如 8080", "e.g. 8080"), $remotePort) }
                WLFormDivider()
                row(loc("本机地址", "Local address")) { themedField(loc("这台 Mac 可达的地址", "reachable from this Mac"), $remoteHost) }
                WLFormDivider()
                row(loc("本机端口", "Local port")) { themedField(loc("如 3000", "e.g. 3000"), $localPort) }
            }
        case .dynamic:
            WLFormSection(loc("代理", "Proxy"),
                          footer: loc("浏览器或系统代理设成 SOCKS5 127.0.0.1:端口即可。",
                                      "Point a browser or the system proxy at SOCKS5 127.0.0.1:<port>.")) {
                row(loc("本地端口", "Local port")) { themedField(loc("如 1080", "e.g. 1080"), $localPort) }
            }
        }
    }

    private var canSave: Bool {
        guard !hostAlias.isEmpty, Int(localPort) != nil else { return false }
        return kind == .dynamic || (Int(remotePort) != nil && !remoteHost.isEmpty)
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
        kind = f.kind
        hostAlias = f.hostAlias
        label = f.label ?? ""
        localPort = String(f.localPort)
        remoteHost = f.remoteHost
        remotePort = f.remotePort == 0 ? "" : String(f.remotePort)
        autoStart = f.autoStart
    }

    private func save() {
        var f = existing ?? PortForward(hostAlias: hostAlias, localPort: 0,
                                        remoteHost: remoteHost, remotePort: 0)
        f.kind = kind
        f.hostAlias = hostAlias
        f.label = label.isEmpty ? nil : label
        f.localPort = Int(localPort) ?? 0
        f.remoteHost = kind == .dynamic ? "" : remoteHost
        f.remotePort = kind == .dynamic ? 0 : Int(remotePort) ?? 0
        // -R's bind is on the server; leave it to sshd rather than pin loopback.
        if kind == .remote, existing?.kind != .remote { f.bindAddress = nil }
        else if kind != .remote, f.bindAddress == nil { f.bindAddress = "127.0.0.1" }
        f.autoStart = autoStart
        if existing == nil { forwards.add(f) } else { forwards.update(f) }
        dismiss()
    }
}

/// VS Code's "Ports" view: list what a host is listening on and forward any
/// of it to this Mac in one click.
struct PortDiscoverySheet: View {
    @Environment(HostStore.self) private var store
    @Environment(ForwardStore.self) private var forwards
    @Environment(SessionStore.self) private var sessions
    @Environment(Localizer.self) private var loc
    @Environment(\.wlDismiss) private var dismiss

    @State private var hostAlias = ""
    @State private var scanning = false
    @State private var ports: [ListeningPort]?
    @State private var error: String?

    var body: some View {
        WLSheet(loc("发现远端端口", "Discover Ports"),
                subtitle: loc("列出主机上正在监听的 TCP 端口，一键转发到本机", "List the host's listening TCP ports and forward one here"),
                symbol: "dot.radiowaves.left.and.right", width: 520, height: 520,
                onClose: { dismiss() }) {
            HStack(spacing: 8) {
                WLMenuPicker(selection: $hostAlias,
                             options: [WLOption("", loc("选择主机…", "Select host…"))]
                                + store.sshHosts.map { WLOption($0.alias, $0.alias) },
                             minWidth: 220)
                Button(scanning ? loc("扫描中…", "Scanning…") : loc("扫描", "Scan"), action: scan)
                    .buttonStyle(.wlPill())
                    .disabled(hostAlias.isEmpty || scanning)
                Spacer()
            }
            if let error {
                Text(error).font(WL.caption).foregroundStyle(WL.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let ports {
                if ports.isEmpty {
                    Text(loc("没有找到监听中的端口", "No listening ports found"))
                        .font(WL.small).foregroundStyle(WL.textDim)
                } else {
                    WLListCard {
                        ForEach(ports) { p in portRow(p) }
                    }
                }
            }
        } footer: {
            Spacer()
            Button(loc("完成", "Done")) { dismiss() }
                .buttonStyle(.wlSecondary).keyboardShortcut(.cancelAction)
        }
        .onAppear {
            // Start from the host you're looking at.
            if hostAlias.isEmpty, let s = sessions.activeSession, case .ssh = s.kind { hostAlias = s.alias }
            if !hostAlias.isEmpty { scan() }
        }
        .onChange(of: hostAlias) { _, _ in ports = nil; error = nil }
    }

    private func existing(_ p: ListeningPort) -> PortForward? {
        forwards.forwards.first { $0.kind == .local && $0.hostAlias == hostAlias && $0.remotePort == p.port }
    }

    private func portRow(_ p: ListeningPort) -> some View {
        HStack(spacing: 12) {
            Text("\(p.port)").font(WL.mono(13, .semibold)).foregroundStyle(WL.textPrimary)
                .frame(width: 56, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.process ?? "—").font(WL.body).foregroundStyle(p.process == nil ? WL.textDim : WL.textPrimary)
                Text(p.addresses.joined(separator: ", ")).font(WL.caption).foregroundStyle(WL.textDim).lineLimit(1)
            }
            Spacer()
            if let f = existing(p) {
                if forwards.isRunning(f) {
                    BracketButton("localhost:\(f.localPort)") { openLocalPort(f.localPort) }
                } else {
                    Button(loc("启动", "Start")) { forwards.start(f, store: store) }
                        .buttonStyle(.wlChip(on: true, tint: WL.green))
                }
            } else {
                Button(loc("转发", "Forward")) { forward(p) }
                    .buttonStyle(.wlChip(on: true, tint: WL.green))
            }
        }
        .padding(.vertical, 2)
    }

    private func scan() {
        guard !hostAlias.isEmpty else { return }
        let alias = hostAlias
        scanning = true; error = nil
        Task {
            let result = await FleetRunner.run(command: ListeningPorts.command, on: [alias]).first
            guard alias == hostAlias else { return }
            scanning = false
            let found = ListeningPorts.parse(result?.output ?? "")
            ports = found
            if found.isEmpty, let r = result, !r.ok {
                error = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    private func forward(_ p: ListeningPort) {
        let taken = Set(forwards.forwards.filter { $0.kind != .remote }.map(\.localPort))
        let f = PortForward(hostAlias: hostAlias, localPort: LocalPorts.firstFree(preferring: p.port, taken: taken),
                            remoteHost: p.forwardTarget, remotePort: p.port,
                            label: p.process.map { "\($0) :\(p.port)" })
        forwards.add(f)
        forwards.start(f, store: store)
    }
}
