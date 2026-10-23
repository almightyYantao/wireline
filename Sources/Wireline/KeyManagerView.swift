import SwiftUI
import AppKit
import WirelineCore

/// One discovered SSH public key in `~/.ssh`.
struct SSHKey: Identifiable {
    let id = UUID()
    var name: String          // filename without ".pub", e.g. "id_ed25519"
    var pubPath: String
    var publicKey: String     // the full public-key line
    var fingerprint: String   // e.g. "SHA256:…"
    var type: String          // e.g. "ED25519"

    /// The private key file beside the `.pub` ("" for vault-only entries).
    var privatePath: String { pubPath.isEmpty ? "" : String(pubPath.dropLast(4)) }
}

/// Lists `~/.ssh` public keys, generates new key pairs, and deploys a key to a
/// host. Shells out to the system `ssh-keygen` / `ssh-copy-id`.
@Observable
@MainActor
final class KeyManagerModel {
    var keys: [SSHKey] = []
    var status = ""
    var busy = false
    /// Set when protecting a passphrase-encrypted key: drives the passphrase sheet.
    var passphraseRequest: SSHKey?

    let agent = SSHAgentController.shared

    private var sshDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh", isDirectory: true)
    }

    func reload() {
        Task {
            let dir = sshDir
            let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            var result: [SSHKey] = []
            for f in files where f.hasSuffix(".pub") {
                let url = dir.appendingPathComponent(f)
                guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let line = content.trimmingCharacters(in: .whitespacesAndNewlines)
                let info = await Self.exec(["/usr/bin/ssh-keygen", "-l", "-f", url.path])
                let (fp, type) = Self.parseFingerprint(info.out)
                result.append(SSHKey(name: String(f.dropLast(4)), pubPath: url.path,
                                     publicKey: line, fingerprint: fp, type: type))
            }
            // Protected keys whose `.pub` is gone still need a row (to unprotect).
            for info in agent.keys where !result.contains(where: { $0.fingerprint == info.fingerprint }) {
                result.append(SSHKey(name: (info.originalPath as NSString).lastPathComponent, pubPath: "",
                                     publicKey: info.publicKeyLine, fingerprint: info.fingerprint,
                                     type: info.keyType))
            }
            keys = result.sorted { $0.name < $1.name }
        }
    }

    // MARK: Touch ID protection

    /// Import the key into the Keychain vault behind Touch ID. Asks for the
    /// passphrase (via `passphraseRequest`) when the file is encrypted.
    func protect(_ key: SSHKey, passphrase: String? = nil) {
        let loc = Localizer.shared
        busy = true
        status = loc("正在保护 \(key.name)…", "Protecting \(key.name)…")
        Task {
            defer { busy = false }
            do {
                let info = try await agent.protect(privatePath: key.privatePath, passphrase: passphrase)
                status = agent.originalExposed(info)
                    ? loc("已用 Touch ID 保护 \(key.name)。注意：未加密的原私钥仍在 ~/.ssh，ssh 仍可不经 Touch ID 直接读取它；建议把它移到废纸篓（可随时还原）。",
                          "\(key.name) is now protected by Touch ID. Note: the unencrypted original is still in ~/.ssh, so ssh can still read it without Touch ID — consider moving it to the Trash (reversible).")
                    : loc("已用 Touch ID 保护 \(key.name)。原私钥有口令保护，保留它不影响安全。",
                          "\(key.name) is now protected by Touch ID. The original is passphrase-encrypted, so keeping it is fine.")
                reload()
            } catch SSHAgentController.ProtectError.needsPassphrase {
                status = ""
                passphraseRequest = key
            } catch {
                status = error.localizedDescription
            }
        }
    }

    func moveOriginalToTrash(_ info: ProtectedKeyInfo) {
        let loc = Localizer.shared
        Task {
            do {
                try await agent.moveOriginalToTrash(info)
                status = loc("原私钥已移到废纸篓，.pub 保留。之后用这把密钥都需要 Touch ID。",
                             "Original moved to the Trash; the .pub stays. Every use of this key now needs Touch ID.")
            } catch {
                status = error.localizedDescription
            }
        }
    }

    func unprotect(_ key: SSHKey, _ info: ProtectedKeyInfo) {
        let loc = Localizer.shared
        Task {
            do {
                try await agent.unprotect(info)
                status = info.movedToTrash
                    ? loc("已取消保护，私钥已还原到 \(info.originalPath)。", "Protection removed; the key was restored to \(info.originalPath).")
                    : loc("已取消 \(key.name) 的 Touch ID 保护。", "Touch ID protection removed from \(key.name).")
                reload()
            } catch {
                status = error.localizedDescription
            }
        }
    }

    func copySnippet() {
        guard let snippet = agent.configSnippet else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(snippet, forType: .string)
        status = Localizer.shared.t("已复制配置片段", "Snippet copied")
    }

    /// `ssh-keygen -l -f` prints e.g. "256 SHA256:abc… comment (ED25519)".
    private static func parseFingerprint(_ s: String) -> (String, String) {
        let parts = s.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let fp = parts.count > 1 ? parts[1] : ""
        var type = ""
        if let open = s.lastIndex(of: "("), let close = s.lastIndex(of: ")"), open < close {
            type = String(s[s.index(after: open)..<close])
        }
        return (fp, type)
    }

    /// Import key files from elsewhere into `~/.ssh`, fixing permissions. For a
    /// private key with no `.pub`, copies a sibling `.pub` if present, else derives
    /// one with `ssh-keygen -y` (works for keys without a passphrase).
    func importKeys(_ urls: [URL]) {
        busy = true
        status = "正在导入…"
        Task {
            let fm = FileManager.default
            try? fm.createDirectory(at: sshDir, withIntermediateDirectories: true)
            var imported = 0
            var notes: [String] = []
            for url in urls {
                let name = url.lastPathComponent
                let dest = sshDir.appendingPathComponent(name)
                guard !fm.fileExists(atPath: dest.path) else { notes.append("\(name) 已存在，跳过"); continue }
                do {
                    try fm.copyItem(at: url, to: dest)
                    let isPub = name.hasSuffix(".pub")
                    try fm.setAttributes([.posixPermissions: isPub ? 0o644 : 0o600], ofItemAtPath: dest.path)
                    imported += 1
                    if !isPub { await ensurePublicKey(for: url, privateDest: dest, name: name, notes: &notes) }
                } catch {
                    notes.append("\(name)：\(error.localizedDescription)")
                }
            }
            busy = false
            status = (imported > 0 ? "已导入 \(imported) 个文件" : "未导入")
                + (notes.isEmpty ? "" : "（\(notes.joined(separator: "；"))）")
            reload()
        }
    }

    /// Make sure an imported private key has a matching `.pub` in `~/.ssh`.
    private func ensurePublicKey(for source: URL, privateDest: URL, name: String, notes: inout [String]) async {
        let fm = FileManager.default
        let pubDest = sshDir.appendingPathComponent(name + ".pub")
        guard !fm.fileExists(atPath: pubDest.path) else { return }
        // Prefer a sibling `<name>.pub` next to the source.
        let siblingPub = source.deletingLastPathComponent().appendingPathComponent(name + ".pub")
        if fm.fileExists(atPath: siblingPub.path) {
            try? fm.copyItem(at: siblingPub, to: pubDest)
            try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: pubDest.path)
            return
        }
        // Otherwise derive it (fails silently for passphrase-protected keys).
        let r = await Self.exec(["/usr/bin/ssh-keygen", "-y", "-f", privateDest.path])
        if r.ok, !r.out.isEmpty {
            try? (r.out + "\n").write(to: pubDest, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: pubDest.path)
        } else {
            notes.append("\(name) 无法生成公钥（可能有口令）")
        }
    }

    func copyToPasteboard(_ key: SSHKey) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(key.publicKey, forType: .string)
        status = "已复制 \(key.name).pub 到剪贴板"
    }

    func generate(type: String, name: String, comment: String, passphrase: String) {
        let cleanName = name.trimmingCharacters(in: .whitespaces)
        guard !cleanName.isEmpty else { status = "请填写文件名"; return }
        let path = sshDir.appendingPathComponent(cleanName).path
        guard !FileManager.default.fileExists(atPath: path) else {
            status = "\(cleanName) 已存在，换个名字"; return
        }
        busy = true
        status = "正在生成 \(cleanName)…"
        Task {
            try? FileManager.default.createDirectory(at: sshDir, withIntermediateDirectories: true)
            var argv = ["/usr/bin/ssh-keygen", "-t", type, "-f", path,
                        "-N", passphrase, "-C", comment, "-q"]
            if type == "rsa" { argv += ["-b", "4096"] }
            let r = await Self.exec(argv)
            busy = false
            status = r.ok ? "已生成 \(cleanName) / \(cleanName).pub" : "生成失败：\(r.out)"
            reload()
        }
    }

    nonisolated private static func exec(_ argv: [String]) async -> (out: String, ok: Bool) {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: argv[0])
                p.arguments = Array(argv.dropFirst())
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch {
                    cont.resume(returning: (error.localizedDescription, false)); return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                let out = String(data: data, encoding: .utf8) ?? ""
                cont.resume(returning: (out.trimmingCharacters(in: .whitespacesAndNewlines), p.terminationStatus == 0))
            }
        }
    }
}

struct KeyManagerView: View {
    @Environment(HostStore.self) private var store
    @Environment(SessionStore.self) private var sessions
    @Environment(Localizer.self) private var loc
    @Environment(\.openWindow) private var openWindow

    @State private var model = KeyManagerModel()
    @State private var genType = "ed25519"
    @State private var genName = "id_ed25519"
    @State private var genComment = ""
    @State private var genPass = ""
    @AppStorage(TouchIDGate.graceKey) private var graceSeconds = 300

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                existingKeys
                agentSection
                generateForm
                if !model.status.isEmpty {
                    Text(model.status).font(WL.small).foregroundStyle(WL.textDim)
                        .padding(.horizontal, 4)
                        .transition(.opacity)
                }
            }
            .animation(Motion.state, value: model.status)
            .padding(22)
        }
        .onAppear {
            if genComment.isEmpty {
                genComment = "\(NSUserName())@\(ProcessInfo.processInfo.hostName)"
            }
            model.reload()
        }
        .wlModal(item: $model.passphraseRequest) { key in passphraseSheet(key) }
    }

    private var existingKeys: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(loc("现有密钥", "Existing keys")).font(WL.caption.weight(.semibold)).foregroundStyle(WL.textDim)
                    .textCase(.uppercase).tracking(0.6)
                Spacer()
                Button(loc("刷新", "Refresh")) { model.reload() }.buttonStyle(.wlSecondary)
                Button(loc("导入…", "Import…")) { pickAndImport() }.buttonStyle(.wlSecondary)
            }
            .padding(.leading, 4)
            VStack(alignment: .leading, spacing: 0) {
                if model.keys.isEmpty {
                    Text(loc("~/.ssh 下没有找到公钥。", "No public keys found in ~/.ssh."))
                        .font(WL.small).foregroundStyle(WL.textDim)
                        .frame(maxWidth: .infinity, minHeight: 60)
                } else {
                    ForEach(Array(model.keys.enumerated()), id: \.element.id) { i, key in
                        if i > 0 { WLFormDivider() }
                        keyRow(key)
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 4)
            .wlCard()
        }
    }

    private func keyRow(_ key: SSHKey) -> some View {
        let protected = model.agent.info(forFingerprint: key.fingerprint) != nil
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: protected ? "touchid" : "key.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(protected ? WL.green : WL.amber)
                    .frame(width: 28, height: 28)
                    .background((protected ? WL.green : WL.amber).opacity(0.12),
                                in: RoundedRectangle(cornerRadius: WL.radius(9), style: .continuous))
                    .help(protected ? loc("每次使用都需要 Touch ID", "Every use requires Touch ID") : "")
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(key.name).font(WL.body).foregroundStyle(WL.textPrimary)
                        if !key.type.isEmpty {
                            Text(key.type).font(WL.caption).foregroundStyle(WL.textDim)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(WL.track, in: Capsule())
                        }
                        if protected {
                            Text("Touch ID").font(WL.caption.weight(.semibold)).foregroundStyle(WL.green)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(WL.green.opacity(0.12), in: Capsule())
                                .transition(.wlBadge)
                        }
                    }
                    Text(key.fingerprint).font(WL.caption).foregroundStyle(WL.textDim)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                Spacer(minLength: 8)
                Button(loc("复制公钥", "Copy")) { model.copyToPasteboard(key) }.buttonStyle(.wlSecondary)
                if !key.pubPath.isEmpty { deployMenu(key) }
            }
            protectionRow(key)
        }
        .padding(.vertical, 10)
        .animation(Motion.state, value: protected)
    }

    /// Protect / unprotect actions, plus the "original still readable" warning.
    @ViewBuilder
    private func protectionRow(_ key: SSHKey) -> some View {
        if let info = model.agent.info(forFingerprint: key.fingerprint) {
            let exposed = model.agent.originalExposed(info)
            VStack(alignment: .leading, spacing: 8) {
                if exposed {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10))
                            .foregroundStyle(WL.amber).padding(.top, 1)
                        Text(loc("未加密的原私钥仍在 \(info.originalPath)，ssh 可以不经 Touch ID 直接读取它。",
                                 "The unencrypted original is still at \(info.originalPath); ssh can read it without Touch ID."))
                            .font(WL.caption).foregroundStyle(WL.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(WL.amber.opacity(0.1), in: RoundedRectangle(cornerRadius: WL.radius(9), style: .continuous))
                } else if info.movedToTrash {
                    Text(loc("原私钥已在废纸篓；取消保护会把它还原。", "The original is in the Trash; removing protection restores it."))
                        .font(WL.caption).foregroundStyle(WL.textDim)
                }
                HStack(spacing: 8) {
                    Spacer()
                    Button(loc("取消保护", "Remove protection")) { model.unprotect(key, info) }
                        .buttonStyle(.wlSecondary)
                    if exposed {
                        Button(loc("把原私钥移到废纸篓", "Move original to Trash")) { model.moveOriginalToTrash(info) }
                            .buttonStyle(.wlPrimary)
                    }
                }
            }
            .padding(.leading, 38)
        } else if !key.privatePath.isEmpty, FileManager.default.fileExists(atPath: key.privatePath) {
            HStack {
                Spacer()
                Button { model.protect(key) } label: {
                    Label(loc("用 Touch ID 保护", "Protect with Touch ID"), systemImage: "touchid")
                }
                .buttonStyle(.wlSecondary)
            }
        }
    }

    private func passphraseSheet(_ key: SSHKey) -> some View {
        WLPromptSheet(title: loc("输入 \(key.name) 的口令", "Passphrase for \(key.name)"),
                      subtitle: loc("口令只用来解密一份临时副本，导入后副本立即删除，口令不保存。",
                                    "Only decrypts a temporary copy, deleted right after import. Not stored."),
                      symbol: "touchid", label: loc("口令", "Passphrase"),
                      confirmTitle: loc("继续", "Continue"), secure: true) { pass in
            model.protect(key, passphrase: pass)
        }
    }

    private var agentSection: some View {
        WLFormSection(loc("Touch ID 密钥代理", "Touch ID Key Agent"),
                      footer: loc("验证通过后，这段时间内再用受保护的密钥不再弹 Touch ID；锁屏或睡眠后立即失效。",
                                  "After you approve, protected keys are reused without another prompt for this long. Cleared on screen lock and sleep.")) {
            WLFormRow(loc("状态", "Status"),
                      detail: model.agent.isRunning
                        ? loc("Wireline 打开的 ssh / sftp / scp 通过它使用受保护的密钥，其他密钥照常转发给系统原有的 ssh-agent。",
                              "ssh / sftp / scp started by Wireline use protected keys through it; other keys go to your existing ssh-agent.")
                        : loc("保护至少一把密钥后自动启动。", "Starts automatically once a key is protected.")) {
                HStack(spacing: 6) {
                    Circle().fill(model.agent.isRunning ? WL.green : WL.textDim.opacity(0.5)).frame(width: 7, height: 7)
                    Text(model.agent.isRunning ? loc("运行中", "Running") : loc("未启动", "Idle"))
                        .font(WL.small).foregroundStyle(model.agent.isRunning ? WL.green : WL.textDim)
                }
            }
            if let err = model.agent.lastError {
                Text(err).font(WL.small).foregroundStyle(WL.red).padding(.bottom, 8)
            }
            WLFormDivider()
            WLFormRow(loc("免重复验证", "Re-use approval")) {
                WLSegmented(selection: $graceSeconds,
                            options: TouchIDGate.graceChoices.map { WLOption($0, graceLabel($0)) }, fill: false)
            }
            if let snippet = model.agent.configSnippet {
                WLFormDivider()
                VStack(alignment: .leading, spacing: 8) {
                    Text(loc("想让你自己的终端也用 Touch ID？把下面这段加到 ~/.ssh/config 开头（Wireline 不会自动修改该文件，且仅在 Wireline 运行时可用）：",
                             "Want your own terminal to use Touch ID too? Add this to the top of ~/.ssh/config (Wireline never edits it, and it only works while Wireline is running):"))
                        .font(WL.caption).foregroundStyle(WL.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(alignment: .top) {
                        Text(snippet)
                            .font(WL.mono(11)).foregroundStyle(WL.textPrimary).textSelection(.enabled)
                        Spacer()
                        Button(loc("复制", "Copy")) { model.copySnippet() }.buttonStyle(.wlSecondary)
                    }
                    .padding(10)
                    .background(WL.fieldFill, in: RoundedRectangle(cornerRadius: WL.radius(9), style: .continuous))
                }
                .padding(.vertical, 12)
            }
        }
    }

    private func graceLabel(_ seconds: Int) -> String {
        seconds == 0 ? loc("每次", "Every time") : loc("\(seconds / 60) 分钟", "\(seconds / 60) min")
    }

    private func deployMenu(_ key: SSHKey) -> some View {
        Menu {
            if store.sshHosts.isEmpty {
                Text(loc("没有主机", "No hosts"))
            } else {
                ForEach(store.sshHosts) { host in
                    Button(host.alias) { deploy(key, to: host) }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(loc("部署到…", "Deploy to…"))
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
            }
        }
        .menuStyle(.button).buttonStyle(.wlSecondary).menuIndicator(.hidden).fixedSize()
    }

    private var generateForm: some View {
        WLFormSection(loc("生成新密钥", "Generate a New Key")) {
            WLFormRow(loc("类型", "Type")) {
                WLSegmented(selection: $genType, options: [
                    WLOption("ed25519", "ed25519"), WLOption("rsa", "rsa (4096)"), WLOption("ecdsa", "ecdsa"),
                ], fill: false)
            }
            WLFormDivider()
            WLFormRow(loc("文件名", "File")) { field(text: $genName) }
            WLFormDivider()
            WLFormRow(loc("备注", "Comment")) { field(text: $genComment) }
            WLFormDivider()
            WLFormRow(loc("口令", "Passphrase")) {
                SecureField("", text: $genPass, prompt: Text(loc("可留空", "optional")).foregroundStyle(WL.textDim))
                    .frame(width: 240).wlField(font: WL.small)
            }
            WLFormDivider()
            HStack {
                Spacer()
                Button(model.busy ? loc("生成中…", "Generating…") : loc("生成", "Generate")) {
                    model.generate(type: genType, name: genName, comment: genComment, passphrase: genPass)
                }
                .buttonStyle(.wlPrimary)
                .disabled(model.busy || genName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.vertical, 10)
        }
    }

    private func field(text: Binding<String>) -> some View {
        TextField("", text: text).frame(width: 240).wlField(font: WL.small)
    }

    /// Pick key files from anywhere and import them into `~/.ssh`.
    private func pickAndImport() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.showsHiddenFiles = true
        panel.message = loc("选择要导入的密钥文件（私钥和/或 .pub）",
                            "Choose key files to import (private key and/or .pub)")
        panel.prompt = loc("导入", "Import")
        if panel.runModal() == .OK { model.importKeys(panel.urls) }
    }

    /// Deploy the key by running `ssh-copy-id` in a fresh local shell, so any
    /// password prompt is handled interactively in the PTY.
    private func deploy(_ key: SSHKey, to host: Host) {
        let id = sessions.openLocalShell()
        openWindow(id: "main")
        model.status = "在终端里向 \(host.alias) 部署 \(key.name).pub…"
        // Give the shell a moment to spin up before feeding the command.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            sessions.session(id)?.terminalView.send(txt: "ssh-copy-id -i \(key.pubPath) \(host.alias)\n")
        }
    }
}
