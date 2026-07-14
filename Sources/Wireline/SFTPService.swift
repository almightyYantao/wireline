import Foundation
import Observation
import Citadel
import Crypto
import NIOCore
import WirelineCore

/// One remote entry in a directory listing.
struct SFTPEntry: Identifiable, Sendable {
    var id: String { name }
    let name: String
    let isDir: Bool
    let size: UInt64
    let permissions: UInt32
}

/// Owns the (non-Sendable) SSH client + SFTP channel inside a single isolation
/// domain, so the rest of the app only ever exchanges Sendable values with it.
actor SFTPConnection {
    enum Credential: Sendable { case password(String); case key(String) }
    struct Fail: LocalizedError { let msg: String; var errorDescription: String? { msg } }

    private var client: SSHClient?
    private var sftp: SFTPClient?

    /// Connect and list the home directory in one atomic actor call, so no
    /// concurrent `close()` can clear the channel between the two steps.
    func connectAndList(hostname: String, port: Int, user: String,
                        credential: Credential) async throws -> (String, [SFTPEntry]) {
        let auth: SSHAuthenticationMethod
        switch credential {
        case .password(let p):
            auth = .passwordBased(username: user, password: p)
        case .key(let k):
            if let ed = try? Curve25519.Signing.PrivateKey(sshEd25519: k) {
                auth = .ed25519(username: user, privateKey: ed)
            } else if let rsa = try? Insecure.RSA.PrivateKey(sshRsa: k) {
                auth = .rsa(username: user, privateKey: rsa)
            } else {
                throw Fail(msg: "暂不支持该密钥（可能已加密或类型不支持），可改用密码认证。")
            }
        }
        let c = try await SSHClient.connect(
            host: hostname, port: port,
            authenticationMethod: auth,
            hostKeyValidator: .acceptAnything(),
            reconnect: .never
        )
        let s = try await c.openSFTP()
        self.client = c
        self.sftp = s
        let home = (try? await s.getRealPath(atPath: ".")) ?? "."
        let items = try await listEntries(sftp: s, path: home)
        return (home, items)
    }

    func list(_ path: String) async throws -> [SFTPEntry] {
        guard let sftp else { throw Fail(msg: "连接已断开，请重新打开。") }
        return try await listEntries(sftp: sftp, path: path)
    }

    private func listEntries(sftp: SFTPClient, path: String) async throws -> [SFTPEntry] {
        let names = try await sftp.listDirectory(atPath: path)
        var items: [SFTPEntry] = []
        for name in names {
            for c in name.components where c.filename != "." && c.filename != ".." {
                let perm = c.attributes.permissions ?? 0
                let isDir = (perm & 0o170000) == 0o040000 || c.longname.hasPrefix("d")
                items.append(SFTPEntry(name: c.filename, isDir: isDir,
                                       size: c.attributes.size ?? 0, permissions: perm))
            }
        }
        items.sort { ($0.isDir ? 0 : 1, $0.name.lowercased()) < ($1.isDir ? 0 : 1, $1.name.lowercased()) }
        return items
    }

    func makeDirectory(_ path: String) async throws {
        guard let sftp else { throw Fail(msg: "未连接") }
        try await sftp.createDirectory(atPath: path)
    }

    func remove(_ path: String, isDir: Bool) async throws {
        guard let sftp else { throw Fail(msg: "未连接") }
        if isDir { try await sftp.rmdir(at: path) } else { try await sftp.remove(at: path) }
    }

    func rename(_ from: String, to: String) async throws {
        guard let sftp else { throw Fail(msg: "未连接") }
        try await sftp.rename(at: from, to: to)
    }

    func download(_ path: String) async throws -> Data {
        guard let sftp else { throw Fail(msg: "未连接") }
        return try await sftp.withFile(filePath: path, flags: .read) { file -> Data in
            var buf = try await file.readAll()
            return Data(buf.readBytes(length: buf.readableBytes) ?? [])
        }
    }

    func upload(_ path: String, data: Data) async throws {
        guard let sftp else { throw Fail(msg: "未连接") }
        var tmp = ByteBufferAllocator().buffer(capacity: data.count)
        tmp.writeBytes(data)
        let buf = tmp
        try await sftp.withFile(filePath: path, flags: [.write, .create, .truncate]) { file in
            try await file.write(buf)
        }
    }

    func close() async {
        try? await sftp?.close()
        sftp = nil
        client = nil   // dropping the last reference closes the SSH transport
    }
}

/// Drives the visual SFTP browser for one host and publishes state to SwiftUI.
@Observable
@MainActor
final class FileBrowserModel {
    let host: Host
    private let store: HostStore
    private let conn = SFTPConnection()

    private(set) var path = "/"
    private(set) var entries: [SFTPEntry] = []
    private(set) var connecting = false
    private(set) var connected = false
    /// True when no usable credential was found — the UI should ask for a password.
    private(set) var needsPassword = false
    var status: String?
    /// Called after any upload/download finishes, so the panes can refresh.
    var onTransferComplete: (() -> Void)?

    init(host: Host, store: HostStore) {
        self.host = host
        self.store = store
    }

    func connect() {
        guard !connecting, !connected else { return }
        guard let credential = resolveCredential() else {
            needsPassword = true
            status = "该主机需要密码，请在下方输入。"
            return
        }
        performConnect(credential)
    }

    /// Retry connecting with a password the user typed, saving it to the Keychain.
    func connect(withPassword password: String) {
        guard !password.isEmpty else { return }
        needsPassword = false
        try? store.keychain.setPassword(password, for: host.alias)
        performConnect(.password(password))
    }

    private func performConnect(_ credential: SFTPConnection.Credential) {
        guard !connecting, !connected else { return }
        connecting = true
        status = "连接中…"
        let user = host.user ?? NSUserName()
        let hostname = host.connectHostname
        let port = host.effectivePort
        Task {
            do {
                let (home, items) = try await conn.connectAndList(
                    hostname: hostname, port: port, user: user, credential: credential)
                path = home
                entries = items
                connected = true
                status = nil
            } catch {
                status = "连接失败：\(friendly(error))"
            }
            connecting = false
        }
    }

    /// Returns the credential to try, or nil when the host needs a password we
    /// don't have yet.
    private func resolveCredential() -> SFTPConnection.Credential? {
        // 1) An explicit IdentityFile in the config wins.
        if let idf = host.identityFile, !idf.isEmpty, let key = readKey(idf) {
            return .key(key)
        }
        // 2) A password saved in the Keychain.
        if let pw = store.password(for: host), !pw.isEmpty {
            return .password(pw)
        }
        // 3) Fall back to the default identity keys (what plain `ssh` tries when
        //    no IdentityFile is set), so agent/default-key hosts still work.
        if host.identityFile == nil || host.identityFile?.isEmpty == true {
            for candidate in ["~/.ssh/id_ed25519", "~/.ssh/id_rsa", "~/.ssh/id_ecdsa"] {
                if let key = readKey(candidate) { return .key(key) }
            }
        }
        return nil
    }

    private func readKey(_ path: String) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        return try? String(contentsOfFile: expanded, encoding: .utf8)
    }

    func load(_ newPath: String) async {
        do {
            entries = try await conn.list(newPath)
            path = newPath
        } catch {
            status = "读取目录失败：\(friendly(error))"
        }
    }

    func refresh() { guard connected else { return }; Task { await load(path) } }
    func open(_ e: SFTPEntry) {
        guard connected, e.isDir else { return }
        Task { await load(join(path, e.name)) }
    }
    func goUp() {
        guard connected else { return }
        let parent = (path as NSString).deletingLastPathComponent
        Task { await load(parent.isEmpty ? "/" : parent) }
    }
    func go(to p: String) { guard connected else { return }; Task { await load(p) } }

    var breadcrumbs: [(name: String, path: String)] {
        var result = [(name: "/", path: "/")]
        var acc = ""
        for part in path.split(separator: "/") {
            acc += "/\(part)"
            result.append((name: String(part), path: acc))
        }
        return result
    }

    func makeDirectory(_ name: String) {
        guard !name.isEmpty else { return }
        Task {
            do { try await conn.makeDirectory(join(path, name)); await load(path) }
            catch { status = "新建文件夹失败：\(friendly(error))" }
        }
    }

    func delete(_ e: SFTPEntry) {
        Task {
            do { try await conn.remove(join(path, e.name), isDir: e.isDir); await load(path) }
            catch { status = "删除失败：\(friendly(error))" }
        }
    }

    func rename(_ e: SFTPEntry, to newName: String) {
        guard !newName.isEmpty else { return }
        Task {
            do { try await conn.rename(join(path, e.name), to: join(path, newName)); await load(path) }
            catch { status = "重命名失败：\(friendly(error))" }
        }
    }

    func download(_ e: SFTPEntry, toDirectory dir: URL) {
        download(e, to: dir.appendingPathComponent(e.name))
    }

    func download(_ e: SFTPEntry, to localURL: URL) {
        guard !e.isDir else { return }
        status = "下载中：\(e.name)…"
        let remote = join(path, e.name)
        Task {
            do {
                let data = try await conn.download(remote)
                try data.write(to: localURL)
                status = "已下载：\(e.name)（\(data.count) 字节）"
            } catch { status = "下载失败：\(friendly(error))" }
            onTransferComplete?()
        }
    }

    func upload(from localURL: URL) {
        let name = localURL.lastPathComponent
        status = "上传中：\(name)…"
        let remote = join(path, name)
        Task {
            do {
                let data = try Data(contentsOf: localURL)
                try await conn.upload(remote, data: data)
                await load(path)
                status = "已上传：\(name)"
            } catch { status = "上传失败：\(friendly(error))" }
            onTransferComplete?()
        }
    }

    func disconnect() {
        connected = false
        Task { await conn.close() }
    }

    private func join(_ base: String, _ name: String) -> String {
        base == "/" ? "/\(name)" : "\(base)/\(name)"
    }

    private func friendly(_ error: Error) -> String {
        let s = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        return s.count > 140 ? String(s.prefix(140)) + "…" : s
    }
}
