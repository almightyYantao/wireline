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

    enum Mode: String, CaseIterable { case export, `import` }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("// \(loc("加密备份 / 迁移", "Encrypted Backup / Migration"))")
                .font(WL.body).foregroundStyle(WL.green)
                .padding(.horizontal, 20).padding(.top, 22).padding(.bottom, 14)
            Rectangle().fill(WL.border).frame(height: 1)

            VStack(alignment: .leading, spacing: 14) {
                Picker("", selection: $mode) {
                    Text(loc("导出", "Export")).tag(Mode.export)
                    Text(loc("导入", "Import")).tag(Mode.import)
                }
                .pickerStyle(.segmented).labelsHidden()

                Text(mode == .export
                     ? loc("把全部 \(store.hosts.count) 台主机及其 Keychain 密码打包成一个加密文件。",
                           "Bundle all \(store.hosts.count) hosts and their Keychain passwords into one encrypted file.")
                     : loc("从 Wireline 备份文件恢复主机与密码。",
                           "Restore hosts and passwords from a Wireline backup file."))
                    .font(WL.small).foregroundStyle(WL.textDim)

                secure(loc("口令", "Passphrase"), $passphrase)
                if mode == .export {
                    secure(loc("确认口令", "Confirm passphrase"), $confirm)
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
                Spacer()
                BracketButton(loc("关闭", "Close")) { dismiss() }
                Button {
                    mode == .export ? runExport() : runImport()
                } label: {
                    Text("[\(mode == .export ? loc("导出…", "Export…") : loc("选择文件…", "Choose File…"))]")
                        .font(WL.small).foregroundStyle(canRun ? WL.green : WL.textDim)
                }.buttonStyle(.plain).disabled(!canRun)
            }
            .padding(.horizontal, 20).padding(.vertical, 18)
        }
        .frame(width: 460, height: 340)
        .background(WL.bg)
        .preferredColorScheme(.dark)
    }

    private var canRun: Bool {
        !passphrase.isEmpty && (mode == .import || passphrase == confirm)
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
