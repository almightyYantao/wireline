import SwiftUI
import WirelineCore

/// Host properties shown in the right pane on single-click.
struct HostDetailView: View {
    @Environment(HostStore.self) private var store
    @Environment(SessionStore.self) private var sessions
    @Environment(Localizer.self) private var loc
    @Environment(\.openWindow) private var openWindow
    let host: Host
    var onEdit: (Host) -> Void
    @State private var mem = HostMemoryStore.shared

    private var status: HostStatus { store.statuses[host.alias] ?? .unknown }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                group(loc("连接", "Connection"), rows: [
                    (loc("别名", "Alias"), host.alias),
                    (loc("主机", "Host"), host.connectHostname),
                    (loc("用户", "User"), host.user ?? "—"),
                    (loc("端口", "Port"), String(host.effectivePort)),
                    (loc("认证", "Auth"), host.resolvedAuthMethod == .key ? loc("公钥", "Public key") : loc("密码", "Password")),
                    (loc("密钥", "Identity"), host.identityFile ?? "—"),
                    (loc("跳板机", "Jump host"), host.proxyJump ?? "—")
                ])
                if !host.extraOptions.isEmpty {
                    group(loc("其他选项", "Other options"), rows: host.extraOptions.map { ($0.keyword, $0.value) })
                }
                group(loc("Wireline", "Wireline"), rows: [
                    (loc("分组", "Group"), host.group ?? loc("未分组", "Ungrouped")),
                    (loc("描述", "Description"), host.descriptionText ?? "—"),
                    (loc("自动 sudo", "Auto-sudo"), host.autoSudo ? loc("开", "On") : loc("关", "Off"))
                ])
                memorySection
                Text(loc("别名走标准 ~/.ssh/config —— 终端里的 ssh \(host.alias) / scp / VS Code Remote 同样生效。",
                         "Resolves via ~/.ssh/config — `ssh \(host.alias)`, scp, and VS Code Remote all work too."))
                    .font(WL.caption).foregroundStyle(WL.textDim)
            }
            .padding(24)
        }
        .background(.clear)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Circle().fill(status.tagColor).frame(width: 10, height: 10)
            Text(host.alias).font(WL.mono(20, .bold)).foregroundStyle(WL.greenBright)
            Spacer()
            BracketButton(loc("检测", "Check")) { Task { await store.check(host) } }
            BracketButton(loc("编辑", "Edit")) { onEdit(host) }
            Button {
                connectHost(host, store: store, sessions: sessions, openWindow: openWindow)
            } label: {
                Text("[\(loc("连接", "Connect"))]").font(WL.body).foregroundStyle(WL.green)
            }.buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var memorySection: some View {
        let facts = mem.facts(for: host.alias)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(loc("AI 记忆", "AI Memory")).font(WL.small.weight(.semibold))
                    .foregroundStyle(WL.green).textCase(.uppercase)
                Spacer()
                if !facts.isEmpty {
                    BracketButton(loc("清空", "Clear")) { mem.clear(host.alias) }
                }
            }
            if facts.isEmpty {
                Text(loc("AI 在对话中了解到该主机的稳定信息后会记在这里，用于让回答更贴合本机。",
                         "The AI records durable facts about this host here to tailor its answers."))
                    .font(WL.caption).foregroundStyle(WL.textDim)
            } else {
                ForEach(facts, id: \.self) { fact in
                    HStack(alignment: .top, spacing: 8) {
                        Text("•").foregroundStyle(WL.green)
                        Text(fact).font(WL.small).foregroundStyle(WL.textPrimary).textSelection(.enabled)
                        Spacer()
                        Button { mem.remove(fact, for: host.alias) } label: {
                            Image(systemName: "xmark").font(.system(size: 8)).foregroundStyle(WL.textDim)
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func group(_ title: String, rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(WL.small.weight(.semibold)).foregroundStyle(WL.green).textCase(.uppercase)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(rows, id: \.0) { key, value in
                    HStack(alignment: .top, spacing: 14) {
                        Text(key).font(WL.small).foregroundStyle(WL.textDim)
                            .frame(width: 90, alignment: .leading)
                        Text(value).font(WL.body).foregroundStyle(WL.textPrimary).textSelection(.enabled)
                        Spacer()
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WL.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(WL.border, lineWidth: 1))
        }
    }
}
