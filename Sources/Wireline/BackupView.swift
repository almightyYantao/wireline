import SwiftUI
import UniformTypeIdentifiers
import WirelineCore

struct BackupView: View {
    @Environment(HostStore.self) private var store
    @Environment(Localizer.self) private var loc
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .export
    @State private var passphrase = ""
    @State private var confirm = ""
    @State private var message: String?
    @State private var isError = false
    @State private var dav = WebDAVConfig.shared
    @State private var davPassword = ""
    @State private var busy = false

    enum Mode: String, CaseIterable { case export, `import`, webdav }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(loc("加密备份 / 迁移", "Encrypted Backup / Migration"))
                .font(WL.body.weight(.semibold)).foregroundStyle(WL.green)
                .padding(.horizontal, 20).padding(.top, 22).padding(.bottom, 14)
            Rectangle().fill(WL.border).frame(height: 1)

            VStack(alignment: .leading, spacing: 14) {
                Picker("", selection: $mode) {
                    Text(loc("导出", "Export")).tag(Mode.export)
                    Text(loc("导入", "Import")).tag(Mode.import)
                    Text("WebDAV").tag(Mode.webdav)
                }
                .pickerStyle(.segmented).labelsHidden()

                Text(descriptionText).font(WL.small).foregroundStyle(WL.textDim)

                if mode == .webdav {
                    field(loc("服务地址", "Server URL"), "https://dav.example.com/wireline/", $dav.baseURL)
                    field(loc("用户名", "Username"), "user", $dav.username)
                    secure(loc("WebDAV 密码", "WebDAV password"), $davPassword)
                    field(loc("文件名", "Filename"), "wireline-backup.wlbk", $dav.filename)
                }

                secure(loc("加密口令", "Encryption passphrase"), $passphrase)
                if mode == .export {
                    secure(loc("确认口令", "Confirm passphrase"), $confirm)
                }
                if mode != .import {
                    Text(loc("口令不会被保存；一旦丢失，备份将无法恢复。",
                             "The passphrase is never stored. If you lose it, the backup cannot be recovered."))
                        .font(WL.caption).foregroundStyle(WL.amber)
                }
                if let message {
                    Text(message).font(WL.small).foregroundStyle(isError ? WL.red : WL.green)
                }
            }
            .padding(20)

            Spacer()
            Rectangle().fill(WL.border).frame(height: 1)
            HStack(spacing: 18) {
                if busy { Text(loc("处理中…", "Working…")).font(WL.small).foregroundStyle(WL.amber) }
                Spacer()
                BracketButton(loc("关闭", "Close")) { dismiss() }
                switch mode {
                case .export:
                    actionButton(loc("导出…", "Export…")) { runExport() }
                case .import:
                    actionButton(loc("选择文件…", "Choose File…")) { runImport() }
                case .webdav:
                    actionButton(loc("从 WebDAV 恢复", "Restore")) { runWebDAVRestore() }
                    actionButton(loc("上传到 WebDAV", "Upload")) { runWebDAVUpload() }
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 18)
        }
        .frame(width: 460, height: mode == .webdav ? 500 : 340)
        .background(WL.bg)
        .preferredColorScheme(.dark)
        .onAppear { davPassword = dav.password }
        .onChange(of: davPassword) { dav.password = davPassword }
    }

    private var descriptionText: String {
        switch mode {
        case .export: return loc("把全部 \(store.hosts.count) 台主机及其 Keychain 密码打包成一个加密文件。",
                                 "Bundle all \(store.hosts.count) hosts and their Keychain passwords into one encrypted file.")
        case .import: return loc("从 Wireline 备份文件恢复主机与密码。",
                                 "Restore hosts and passwords from a Wireline backup file.")
        case .webdav: return loc("把加密备份上传到你的 WebDAV，或从中恢复。密文才上传，服务器看不到明文。",
                                 "Upload the encrypted backup to your WebDAV, or restore from it. Only ciphertext leaves your machine.")
        }
    }

    private var canRun: Bool {
        guard !passphrase.isEmpty else { return false }
        if mode == .export { return passphrase == confirm }
        if mode == .webdav { return dav.isConfigured }
        return true
    }

    private func actionButton(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("[\(title)]").font(WL.small).foregroundStyle(canRun && !busy ? WL.green : WL.textDim)
        }.buttonStyle(.plain).disabled(!canRun || busy)
    }

    private func field(_ label: String, _ prompt: String, _ text: Binding<String>) -> some View {
        TextField("", text: text, prompt: Text("\(label) · \(prompt)").foregroundStyle(WL.textDim))
            .textFieldStyle(.plain).font(WL.mono(12)).foregroundStyle(WL.textPrimary)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(WL.surface, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(WL.border, lineWidth: 1))
    }

    private func runWebDAVUpload() {
        busy = true
        do {
            let data = try store.exportBackup(passphrase: passphrase)
            let client = WebDAVClient(config: dav)
            Task {
                do {
                    try await client.upload(data)
                    await MainActor.run { busy = false; show(loc("已上传备份到 WebDAV。", "Uploaded backup to WebDAV."), error: false) }
                } catch {
                    await MainActor.run { busy = false; show(error.localizedDescription, error: true) }
                }
            }
        } catch {
            busy = false; show(error.localizedDescription, error: true)
        }
    }

    private func runWebDAVRestore() {
        busy = true
        let client = WebDAVClient(config: dav)
        Task {
            do {
                let data = try await client.download()
                let count = try store.importBackup(data, passphrase: passphrase)
                await MainActor.run { busy = false; show(loc("已从 WebDAV 恢复 \(count) 台主机。", "Restored \(count) hosts from WebDAV."), error: false) }
            } catch {
                await MainActor.run { busy = false; show("\(error.localizedDescription)", error: true) }
            }
        }
    }

    private func secure(_ prompt: String, _ text: Binding<String>) -> some View {
        SecureField("", text: text, prompt: Text(prompt).foregroundStyle(WL.textDim))
            .textFieldStyle(.plain).font(WL.body).foregroundStyle(WL.textPrimary)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(WL.surface, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(WL.border, lineWidth: 1))
    }

    private func runExport() {
        do {
            let data = try store.exportBackup(passphrase: passphrase)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "wireline-backup.wlbk"
            panel.allowedContentTypes = [UTType(filenameExtension: "wlbk") ?? .data]
            if panel.runModal() == .OK, let url = panel.url {
                try data.write(to: url)
                show(loc("已导出 \(store.hosts.count) 台主机到 \(url.lastPathComponent)。",
                        "Exported \(store.hosts.count) hosts to \(url.lastPathComponent)."), error: false)
            }
        } catch {
            show(error.localizedDescription, error: true)
        }
    }

    private func runImport() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "wlbk") ?? .data, .json, .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let count = try store.importBackup(data, passphrase: passphrase)
            show(loc("已导入 \(count) 台主机。", "Imported \(count) hosts."), error: false)
        } catch {
            show("\(error)", error: true)
        }
    }

    private func show(_ text: String, error: Bool) {
        message = text
        isError = error
    }
}
