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
}

/// Lists `~/.ssh` public keys, generates new key pairs, and deploys a key to a
/// host. Shells out to the system `ssh-keygen` / `ssh-copy-id`.
@Observable
@MainActor
final class KeyManagerModel {
    var keys: [SSHKey] = []
    var status = ""
    var busy = false

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
            keys = result.sorted { $0.name < $1.name }
        }
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                existingKeys
                Rectangle().fill(WL.border).frame(height: 1)
                generateForm
                if !model.status.isEmpty {
                    Text(model.status).font(WL.small).foregroundStyle(WL.textDim)
                }
            }
            .padding(18)
        }
        .onAppear {
            if genComment.isEmpty {
                genComment = "\(NSUserName())@\(ProcessInfo.processInfo.hostName)"
            }
            model.reload()
        }
    }

    private var existingKeys: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(loc("现有密钥", "Existing keys")).font(WL.body.weight(.semibold)).foregroundStyle(WL.green)
                Spacer()
                BracketButton(loc("导入", "Import")) { pickAndImport() }
                BracketButton(loc("刷新", "Refresh")) { model.reload() }
            }
            if model.keys.isEmpty {
                Text(loc("~/.ssh 下没有找到公钥。", "No public keys found in ~/.ssh."))
                    .font(WL.small).foregroundStyle(WL.textDim)
            } else {
                ForEach(model.keys) { key in keyRow(key) }
            }
        }
    }

    private func keyRow(_ key: SSHKey) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "key.fill").foregroundStyle(WL.amber).font(WL.small)
                Text(key.name).font(WL.body).foregroundStyle(WL.textPrimary)
                if !key.type.isEmpty {
                    Text(key.type).font(WL.caption).foregroundStyle(WL.textDim)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(WL.surface, in: Capsule())
                }
                Spacer()
                BracketButton(loc("复制公钥", "Copy")) { model.copyToPasteboard(key) }
                deployMenu(key)
            }
            Text(key.fingerprint).font(WL.caption).foregroundStyle(WL.textDim).textSelection(.enabled)
        }
        .padding(10)
        .background(WL.surface.opacity(0.4), in: RoundedRectangle(cornerRadius: WL.radius(6)))
    }

    private func deployMenu(_ key: SSHKey) -> some View {
        Menu {
            if store.hosts.isEmpty {
                Text(loc("没有主机", "No hosts"))
            } else {
                ForEach(store.hosts) { host in
                    Button(host.alias) { deploy(key, to: host) }
                }
            }
        } label: {
            Text("[\(loc("部署到…", "Deploy to…"))]").font(WL.small).foregroundStyle(WL.textDim)
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    private var generateForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(loc("生成新密钥", "Generate a new key")).font(WL.body.weight(.semibold)).foregroundStyle(WL.green)
            HStack(spacing: 8) {
                Text(loc("类型", "Type")).font(WL.small).foregroundStyle(WL.textDim).frame(width: 56, alignment: .leading)
                Picker("", selection: $genType) {
                    Text("ed25519").tag("ed25519")
                    Text("rsa (4096)").tag("rsa")
                    Text("ecdsa").tag("ecdsa")
                }.labelsHidden().pickerStyle(.menu).fixedSize()
            }
            field(loc("文件名", "File"), text: $genName)
            field(loc("备注", "Comment"), text: $genComment)
            HStack(spacing: 8) {
                Text(loc("口令", "Passphrase")).font(WL.small).foregroundStyle(WL.textDim).frame(width: 56, alignment: .leading)
                SecureField(loc("可留空", "optional"), text: $genPass)
                    .textFieldStyle(.plain).font(WL.small).foregroundStyle(WL.textPrimary)
                    .padding(6).background(WL.bg.opacity(0.6), in: RoundedRectangle(cornerRadius: WL.radius(5)))
                    .overlay(RoundedRectangle(cornerRadius: WL.radius(5)).stroke(WL.border, lineWidth: WL.borderWidth))
            }
            BracketButton(model.busy ? loc("生成中…", "Generating…") : loc("生成", "Generate")) {
                model.generate(type: genType, name: genName, comment: genComment, passphrase: genPass)
            }
        }
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Text(label).font(WL.small).foregroundStyle(WL.textDim).frame(width: 56, alignment: .leading)
            TextField("", text: text)
                .textFieldStyle(.plain).font(WL.small).foregroundStyle(WL.textPrimary)
                .padding(6).background(WL.bg.opacity(0.6), in: RoundedRectangle(cornerRadius: WL.radius(5)))
                .overlay(RoundedRectangle(cornerRadius: WL.radius(5)).stroke(WL.border, lineWidth: WL.borderWidth))
        }
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
