import SwiftUI
import AppKit
import WirelineCore

struct HostEditorView: View {
    @Environment(HostStore.self) private var store
    @Environment(Localizer.self) private var loc
    @Environment(\.dismiss) private var dismiss
    let context: HostEditContext

    @State private var alias = ""
    @State private var hostname = ""
    @State private var user = ""
    @State private var portText = "22"
    @State private var authMethod: AuthMethod = .key
    @State private var identityFile = "~/.ssh/id_rsa"
    @State private var password = ""
    @State private var proxyJump = ""
    @State private var group = ""
    @State private var descriptionText = ""
    @State private var autoSudo = false
    @State private var launchArgs = ""
    @State private var availableKeys: [String] = []
    @FocusState private var aliasFocused: Bool

    private var isEditing: Bool { context.host != nil }
    private var originalAlias: String? { context.host?.alias }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isEditing ? loc("编辑主机", "Edit Host") : loc("新建主机", "New Host"))
                .font(WL.body.weight(.semibold)).foregroundStyle(WL.green)
                .padding(.horizontal, 20).padding(.top, 22).padding(.bottom, 14)
            Rectangle().fill(WL.border).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    section(loc("身份", "Identity")) {
                        field(loc("别名", "Alias")) {
                            input(loc("如 web-hk-1", "e.g. web-hk-1"), $alias).focused($aliasFocused)
                        }
                        field(loc("分组", "Group")) { input(loc("如 Hong Kong", "e.g. Hong Kong"), $group) }
                        field(loc("描述", "Description")) { input("", $descriptionText) }
                    }
                    section(loc("连接", "Connection")) {
                        field(loc("主机 / IP", "HostName / IP")) { input("", $hostname) }
                        field(loc("用户", "User")) { input("root", $user) }
                        field(loc("端口", "Port")) { input("22", $portText) }
                        field(loc("跳板机 (ProxyJump)", "Jump Host (ProxyJump)")) {
                            input(loc("可选", "optional bastion alias"), $proxyJump)
                        }
                        field(loc("启动参数", "Launch args")) {
                            input(loc("可选，如 -o HostKeyAlgorithms=+ssh-rsa",
                                      "optional, e.g. -o HostKeyAlgorithms=+ssh-rsa"), $launchArgs)
                        }
                    }
                    section(loc("认证", "Authentication")) {
                        Picker("", selection: $authMethod) {
                            Text(loc("公钥", "Public Key")).tag(AuthMethod.key)
                            Text(loc("密码", "Password")).tag(AuthMethod.password)
                        }
                        .pickerStyle(.segmented).labelsHidden()
                        if authMethod == .key {
                            field(loc("密钥文件", "Identity File")) { identityPicker }
                        } else {
                            field(loc("密码 (存入 Keychain)", "Password (stored in Keychain)")) {
                                secure($password)
                            }
                            Toggle(isOn: $autoSudo) {
                                Text(loc("登录后自动 sudo -i", "Auto-run sudo -i after login"))
                                    .font(WL.small).foregroundStyle(WL.textPrimary)
                            }.toggleStyle(.checkbox).tint(WL.green)
                        }
                    }
                }
                .padding(20)
            }

            Rectangle().fill(WL.border).frame(height: 1)
            HStack(spacing: 18) {
                if isEditing {
                    Button {
                        if let h = context.host { store.delete(h) }
                        dismiss()
                    } label: {
                        Text("[\(loc("删除", "Delete"))]").font(WL.small).foregroundStyle(WL.red)
                    }.buttonStyle(.plain)
                }
                Spacer()
                BracketButton(loc("取消", "Cancel")) { dismiss() }
                Button(action: save) {
                    Text("[\(isEditing ? loc("保存", "Save") : loc("添加", "Add"))]")
                        .font(WL.small).foregroundStyle(canSave ? WL.green : WL.textDim)
                }.buttonStyle(.plain).disabled(!canSave)
            }
            .padding(.horizontal, 20).padding(.vertical, 18)
        }
        .frame(width: 480, height: 580)
        .background(WL.bg)
        .preferredColorScheme(.dark)
        .onAppear {
            populate()
            DispatchQueue.main.async { aliasFocused = true }
        }
    }

    private var canSave: Bool { !alias.trimmingCharacters(in: .whitespaces).isEmpty }

    private func section<V: View>(_ title: String, @ViewBuilder _ content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(WL.small.weight(.semibold)).foregroundStyle(WL.green).textCase(.uppercase)
            content()
        }
    }

    private func field<V: View>(_ label: String, @ViewBuilder _ content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(WL.small).foregroundStyle(WL.textDim)
            content()
        }
    }

    /// Dropdown of private keys discovered in `~/.ssh`, plus a browse escape hatch
    /// for a key kept elsewhere. Falls back to showing the current custom path.
    private var identityPicker: some View {
        let options = (availableKeys + [identityFile])
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return HStack(spacing: 8) {
            Menu {
                ForEach(options, id: \.self) { key in
                    Button { identityFile = key } label: {
                        Text(key).font(WL.body)
                        if key == identityFile { Image(systemName: "checkmark") }
                    }
                }
            } label: {
                HStack {
                    Text(identityFile.isEmpty ? loc("选择密钥…", "Choose a key…") : identityFile)
                        .font(WL.body).foregroundStyle(identityFile.isEmpty ? WL.textDim : WL.textPrimary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 10)).foregroundStyle(WL.textDim)
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(WL.surface, in: RoundedRectangle(cornerRadius: WL.radius(5)))
                .overlay(RoundedRectangle(cornerRadius: WL.radius(5)).stroke(WL.border, lineWidth: WL.borderWidth))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden)
            Button(loc("浏览…", "Browse…")) { browseForKey() }
                .buttonStyle(.plain).font(WL.small).foregroundStyle(WL.green)
        }
    }

    /// Private keys in `~/.ssh` — files that have a matching `.pub`, presented as
    /// `~/.ssh/<name>` (skipping config/known_hosts and public keys themselves).
    private func discoverKeys() -> [String] {
        let ssh = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: ssh.path)) ?? []
        let pubs = Set(files.filter { $0.hasSuffix(".pub") }.map { String($0.dropLast(4)) })
        let skip: Set<String> = ["config", "known_hosts", "known_hosts.old", "authorized_keys"]
        return files
            .filter { !$0.hasSuffix(".pub") && !skip.contains($0) && pubs.contains($0) }
            .sorted()
            .map { "~/.ssh/\($0)" }
    }

    private func browseForKey() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            identityFile = url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
        }
    }

    private func input(_ prompt: String, _ text: Binding<String>) -> some View {
        TextField("", text: text, prompt: Text(prompt).foregroundStyle(WL.textDim))
            .textFieldStyle(.plain).font(WL.body).foregroundStyle(WL.textPrimary)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(WL.surface, in: RoundedRectangle(cornerRadius: WL.radius(5)))
            .overlay(RoundedRectangle(cornerRadius: WL.radius(5)).stroke(WL.border, lineWidth: WL.borderWidth))
    }

    private func secure(_ text: Binding<String>) -> some View {
        SecureField("", text: text)
            .textFieldStyle(.plain).font(WL.body).foregroundStyle(WL.textPrimary)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(WL.surface, in: RoundedRectangle(cornerRadius: WL.radius(5)))
            .overlay(RoundedRectangle(cornerRadius: WL.radius(5)).stroke(WL.border, lineWidth: WL.borderWidth))
    }

    private func populate() {
        availableKeys = discoverKeys()
        guard let h = context.host else {
            // New host: pre-fill the group when added from a group's + button.
            if let g = context.defaultGroup { group = g }
            // Default to a real, discovered key rather than a guessed path.
            if let first = availableKeys.first(where: { $0.contains("id_ed25519") }) ?? availableKeys.first {
                identityFile = first
            }
            return
        }
        alias = h.alias
        hostname = h.hostname ?? ""
        user = h.user ?? ""
        portText = String(h.effectivePort)
        authMethod = h.resolvedAuthMethod == .password ? .password : .key
        identityFile = h.identityFile ?? "~/.ssh/id_rsa"
        proxyJump = h.proxyJump ?? ""
        group = h.group ?? ""
        descriptionText = h.descriptionText ?? ""
        autoSudo = h.autoSudo
        launchArgs = h.launchArgs ?? ""
        if authMethod == .password {
            password = (try? store.keychain.password(for: h.alias)) ?? ""
        }
    }

    private func save() {
        var host = context.host ?? Host(alias: "")
        host.alias = alias.trimmingCharacters(in: .whitespaces)
        host.hostname = hostname.isEmpty ? nil : hostname
        host.user = user.isEmpty ? nil : user
        host.port = Int(portText) ?? 22
        host.proxyJump = proxyJump.isEmpty ? nil : proxyJump
        host.group = group.isEmpty ? nil : group
        host.descriptionText = descriptionText.isEmpty ? nil : descriptionText
        host.launchArgs = launchArgs.trimmingCharacters(in: .whitespaces).isEmpty ? nil : launchArgs.trimmingCharacters(in: .whitespaces)
        host.authMethod = authMethod
        if authMethod == .key {
            host.identityFile = identityFile.isEmpty ? nil : identityFile
            host.autoSudo = false
        } else {
            host.identityFile = nil
            host.autoSudo = autoSudo
        }
        store.upsert(host, password: authMethod == .password ? password : nil,
                     originalAlias: originalAlias)
        dismiss()
    }
}
