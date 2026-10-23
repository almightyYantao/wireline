import SwiftUI
import UniformTypeIdentifiers
import WirelineCore

struct BackupView: View {
    @Environment(HostStore.self) private var store
    @Environment(Localizer.self) private var loc
    @Environment(\.wlDismiss) private var dismiss
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
        WLSheet(loc("加密备份 / 迁移", "Encrypted Backup / Migration"),
                subtitle: loc("主机与 Keychain 密码打包加密，可导出、导入或同步到 WebDAV",
                              "Hosts and Keychain passwords, encrypted — export, import or sync via WebDAV"),
                symbol: "lock.shield", width: 460, height: mode == .webdav ? 640 : 420,
                onClose: { dismiss() }) {
            VStack(alignment: .leading, spacing: 8) {
                WLSegmented(selection: $mode, options: [
                    WLOption(Mode.export, loc("导出", "Export")),
                    WLOption(Mode.import, loc("导入", "Import")),
                    WLOption(Mode.webdav, "WebDAV"),
                ])
                Text(descriptionText).font(WL.small).foregroundStyle(WL.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }

            if mode == .webdav {
                WLFormSection("WebDAV", footer: loc("将写入：", "Will write to: ") + davTargetPreview) {
                    stacked(loc("目录地址（到文件夹，以 / 结尾）", "Folder URL (a directory, ends with /)")) {
                        field("https://host:端口/路径/", $dav.baseURL)
                    }
                    WLFormDivider()
                    stacked(loc("用户名", "Username")) { field("your-account", $dav.username) }
                    WLFormDivider()
                    stacked(loc("密码（多数网盘需用「应用专用密码」）", "Password (often an app-specific password)")) {
                        secure("", $davPassword)
                    }
                    WLFormDivider()
                    stacked(loc("备份文件名（不含路径）", "Backup file name (no path)")) {
                        field("wireline-backup.wlbk", $dav.filename)
                    }
                }
                WLFormSection(loc("定时备份", "Scheduled backup"),
                              footer: loc("定时备份需填好上面的地址/账号/加密口令；开启后加密口令会存入 Keychain 以便无人值守上传。",
                                          "Auto-backup needs the URL/account/passphrase above; the passphrase is saved to the Keychain so uploads can run unattended.")) {
                    Toggle(isOn: $dav.autoBackup) {
                        Text(loc("定时自动备份", "Scheduled auto-backup")).font(WL.body).foregroundStyle(WL.textPrimary)
                    }
                    .toggleStyle(.wlSwitch)
                    .frame(minHeight: 38).padding(.vertical, 4)
                    if dav.autoBackup {
                        WLFormDivider()
                        WLFormRow(loc("间隔", "Every")) {
                            WLStepper(value: $dav.autoIntervalHours, range: 1...168,
                                      format: { loc("\(Int($0)) 小时", "\(Int($0)) h") })
                        }
                    }
                }
            }

            WLFormSection(loc("加密口令", "Passphrase"),
                          footer: mode != .import
                            ? loc("口令不会被保存；一旦丢失，备份将无法恢复。",
                                  "The passphrase is never stored. If you lose it, the backup cannot be recovered.")
                            : nil) {
                stacked(loc("加密口令", "Encryption passphrase")) { secure("", $passphrase) }
                if mode == .export {
                    WLFormDivider()
                    stacked(loc("确认口令", "Confirm passphrase")) { secure("", $confirm) }
                }
            }

            if let message {
                Text(message).font(WL.small).foregroundStyle(isError ? WL.red : WL.green)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        } footer: {
            if busy { Text(loc("处理中…", "Working…")).font(WL.small).foregroundStyle(WL.amber) }
            Spacer()
            Button(loc("关闭", "Close")) { dismiss() }
                .buttonStyle(.wlSecondary).keyboardShortcut(.cancelAction)
            switch mode {
            case .export:
                Button(loc("导出…", "Export…")) { runExport() }
                    .buttonStyle(.wlPrimary).keyboardShortcut(.defaultAction)
                    .disabled(!canRun || busy)
            case .import:
                Button(loc("选择文件…", "Choose File…")) { runImport() }
                    .buttonStyle(.wlPrimary).keyboardShortcut(.defaultAction)
                    .disabled(!canRun || busy)
            case .webdav:
                // No Return shortcut here: either action touches the remote copy.
                Button(loc("从 WebDAV 恢复", "Restore")) { runWebDAVRestore() }
                    .buttonStyle(.wlSecondary)
                    .disabled(!canRun || busy)
                Button(loc("上传到 WebDAV", "Upload")) { runWebDAVUpload() }
                    .buttonStyle(.wlPrimary)
                    .disabled(!canRun || busy)
            }
        }
        .onAppear { davPassword = dav.password }
        .onChange(of: davPassword) { dav.password = davPassword }
        .onChange(of: dav.autoBackup) { applyAuto() }
        .onChange(of: dav.autoIntervalHours) { applyAuto() }
        .onChange(of: passphrase) { if dav.autoBackup { applyAuto() } }
    }

    /// Label above a full-width field.
    private func stacked<V: View>(_ label: String, @ViewBuilder _ content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(WL.small).foregroundStyle(WL.textDim)
            content()
        }
        .padding(.vertical, 10)
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

    /// Persist the passphrase for unattended backup and (re)start the scheduler.
    private func applyAuto() {
        dav.savedPassphrase = dav.autoBackup ? passphrase : ""
        store.startAutoBackup()
    }

    /// Live preview of the exact URL the backup will be written to / read from.
    private var davTargetPreview: String {
        let base = dav.baseURL.isEmpty ? "…" : (dav.baseURL.hasSuffix("/") ? dav.baseURL : dav.baseURL + "/")
        let name = dav.filename.isEmpty ? "wireline-backup.wlbk" : dav.filename
        return base + name
    }

    private var canRun: Bool {
        guard !passphrase.isEmpty else { return false }
        if mode == .export { return passphrase == confirm }
        if mode == .webdav { return dav.isConfigured }
        return true
    }

    private func field(_ prompt: String, _ text: Binding<String>) -> some View {
        TextField("", text: text, prompt: Text(prompt).foregroundStyle(WL.textDim))
            .wlField()
    }

    private func runWebDAVUpload() {
        dav.password = davPassword            // ensure the latest password is committed
        busy = true
        do {
            let data = try store.exportBackup(passphrase: passphrase)
            let client = WebDAVClient(config: dav)
            Task {
                do {
                    await client.ensureCollection()          // create folder if missing
                    try await client.upload(data)
                    // Read it back to confirm it really persisted, and where.
                    let readback = try await client.download()
                    let ok = readback.count == data.count
                    await MainActor.run {
                        busy = false
                        show(ok
                             ? loc("已上传并校验：\(client.targetDescription)（\(data.count) 字节）",
                                   "Uploaded & verified: \(client.targetDescription) (\(data.count) bytes)")
                             : loc("上传后回读大小不一致，请检查 WebDAV 路径/权限。",
                                   "Read-back size mismatch — check the WebDAV path/permissions."),
                             error: !ok)
                    }
                } catch {
                    await MainActor.run { busy = false; show(loc("上传失败：", "Upload failed: ") + error.localizedDescription, error: true) }
                }
            }
        } catch {
            busy = false; show(error.localizedDescription, error: true)
        }
    }

    private func runWebDAVRestore() {
        dav.password = davPassword
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
            .wlField(font: WL.body)
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
