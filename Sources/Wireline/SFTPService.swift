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
    enum Credential: Sendable {
        case password(String)
        case key(String)
        /// A Touch ID–protected key; `FileBrowserModel` turns it into `.vaultKey`
        /// after authorization, before connecting.
        case protected(fingerprint: String)
        case vaultKey(SSHPrivateKey, material: String)
    }
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
        case .protected:
            throw Fail(msg: "Protected key used without authorization")
        case .vaultKey(let key, let material):
            switch key.kind {
            case .ed25519(let seed):
                auth = .ed25519(username: user, privateKey: try Curve25519.Signing.PrivateKey(rawRepresentation: seed))
            case .ecdsa(.p256, let d):
                auth = .p256(username: user, privateKey: try P256.Signing.PrivateKey(rawRepresentation: d))
            case .ecdsa(.p384, let d):
                auth = .p384(username: user, privateKey: try P384.Signing.PrivateKey(rawRepresentation: d))
            case .ecdsa(.p521, let d):
                auth = .p521(username: user, privateKey: try P521.Signing.PrivateKey(rawRepresentation: d))
            case .rsa:
                auth = .rsa(username: user, privateKey: try Insecure.RSA.PrivateKey(sshRsa: material))
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

    // MARK: Chunked transfers (the transfer queue)

    /// A file's size and kind; nil when it isn't there.
    func stat(_ path: String) async -> (size: UInt64, isDir: Bool)? {
        guard let sftp, let a = try? await sftp.getAttributes(at: path) else { return nil }
        return (a.size ?? 0, ((a.permissions ?? 0) & 0o170000) == 0o040000)
    }

    /// Everything under directory `root`, as paths relative to it (parents
    /// before their children).
    func walk(_ root: String) async throws -> [(relative: String, isDir: Bool, size: UInt64)] {
        guard let sftp else { throw Fail(msg: "未连接") }
        var out: [(relative: String, isDir: Bool, size: UInt64)] = []
        var pending = [""]
        while !pending.isEmpty {
            let rel = pending.removeFirst()
            for e in try await listEntries(sftp: sftp, path: rel.isEmpty ? root : "\(root)/\(rel)") {
                let r = rel.isEmpty ? e.name : "\(rel)/\(e.name)"
                out.append((r, e.isDir, e.size))
                if e.isDir { pending.append(r) }
            }
        }
        return out
    }

    func makeDirectoryIfMissing(_ path: String) async throws {
        guard let sftp else { throw Fail(msg: "未连接") }
        if await stat(path)?.isDir == true { return }
        try await sftp.createDirectory(atPath: path)
    }

    /// Requests kept in flight at once: over a link with latency, one request
    /// per round trip would cap throughput at chunk ÷ RTT.
    private static let window = 8
    private static let readPiece: UInt32 = 64 * 1024
    private static let writePiece = 32_000   // Citadel's own write slice (swift-nio-ssh#99)

    /// Copy `remote` into `local`, starting at byte `offset` (0 truncates; more
    /// resumes). `step` hears the bytes landed after each window and returns
    /// false to stop. Returns whether the whole file is in.
    func download(_ remote: String, to local: URL, from offset: UInt64,
                  step: @escaping @Sendable (UInt64) async -> Bool) async throws -> Bool {
        guard let sftp else { throw Fail(msg: "连接已断开") }
        let fm = FileManager.default
        if !fm.fileExists(atPath: local.path) { fm.createFile(atPath: local.path, contents: nil) }
        let out = try FileHandle(forWritingTo: local)
        defer { try? out.close() }
        try out.truncate(atOffset: offset)
        return try await sftp.withFile(filePath: remote, flags: .read) { file in
            try await Self.pumpDown(file, into: out, from: offset, step: step)
        }
    }

    private nonisolated static func pumpDown(_ opened: SFTPFile, into out: FileHandle, from offset: UInt64,
                                             step: @escaping @Sendable (UInt64) async -> Bool) async throws -> Bool {
        nonisolated(unsafe) let file = opened
        var pos = offset
        while true {
            let base = pos
            let pieces = try await withThrowingTaskGroup(of: (UInt64, ByteBuffer).self) { group in
                for i in 0..<Self.window {
                    let at = base + UInt64(i) * UInt64(Self.readPiece)
                    group.addTask { (at, try await file.read(from: at, length: Self.readPiece)) }
                }
                var got: [(UInt64, ByteBuffer)] = []
                for try await r in group { got.append(r) }
                return got.sorted { $0.0 < $1.0 }
            }
            // Keep the contiguous run; a short read ends it (the rest is re-read).
            var landed: UInt64 = 0
            for (at, buffer) in pieces {
                guard at == pos, buffer.readableBytes > 0 else { break }
                var b = buffer
                let bytes = b.readBytes(length: b.readableBytes) ?? []
                try out.seek(toOffset: pos)
                try out.write(contentsOf: bytes)
                pos += UInt64(bytes.count)
                landed += UInt64(bytes.count)
                if bytes.count < Int(Self.readPiece) { break }
            }
            if landed == 0 { return true }                 // EOF
            if !(await step(landed)) { return false }
        }
    }

    /// Copy `local` to `remote`, starting at byte `offset` (0 truncates; more
    /// resumes). Same `step` contract as `download`.
    func upload(_ local: URL, to remote: String, from offset: UInt64,
                step: @escaping @Sendable (UInt64) async -> Bool) async throws -> Bool {
        guard let sftp else { throw Fail(msg: "连接已断开") }
        let input = try FileHandle(forReadingFrom: local)
        defer { try? input.close() }
        try input.seek(toOffset: offset)
        let flags: SFTPOpenFileFlags = offset == 0 ? [.write, .create, .truncate] : [.write, .create]
        return try await sftp.withFile(filePath: remote, flags: flags) { file in
            try await Self.pumpUp(file, from: input, at: offset, step: step)
        }
    }

    private nonisolated static func pumpUp(_ opened: SFTPFile, from input: FileHandle, at offset: UInt64,
                                           step: @escaping @Sendable (UInt64) async -> Bool) async throws -> Bool {
        nonisolated(unsafe) let file = opened
        var pos = offset
        while true {
            guard let data = try input.read(upToCount: Self.window * Self.writePiece), !data.isEmpty
            else { return true }
            let base = pos
            try await withThrowingTaskGroup(of: Void.self) { group in
                var start = 0
                while start < data.count {
                    let end = min(start + Self.writePiece, data.count)
                    var buf = ByteBufferAllocator().buffer(capacity: end - start)
                    buf.writeBytes(data[data.startIndex + start ..< data.startIndex + end])
                    let slice = buf, at = base + UInt64(start)
                    group.addTask { try await file.write(slice, at: at) }
                    start = end
                }
                try await group.waitForAll()
            }
            pos += UInt64(data.count)
            if !(await step(UInt64(data.count))) { return false }
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
    let transfers: TransferQueue
    /// The remote home, for resolving `~` paths.
    private var home = "/"

    private init(host: Host, store: HostStore) {
        self.host = host
        self.store = store
        self.transfers = TransferQueue(conn: conn)
        transfers.onItemFinished = { [weak self] item in
            guard let self else { return }
            if item.direction == .upload, (item.remotePath as NSString).deletingLastPathComponent == path {
                refresh()
            }
            onTransferComplete?()
        }
        transfers.onIdle = { [weak self] in
            guard let self, closeWhenIdle else { return }
            disconnect()
        }
    }

    // MARK: Lifetime

    /// One browser per host, kept while it has transfers running — so leaving
    /// the Files page (⌘W) doesn't cut a download off halfway.
    private static var live: [String: FileBrowserModel] = [:]
    private var closeWhenIdle = false

    static func obtain(host: Host, store: HostStore) -> FileBrowserModel {
        if let m = live[host.alias] {
            m.closeWhenIdle = false
            return m
        }
        let m = FileBrowserModel(host: host, store: store)
        live[host.alias] = m
        return m
    }

    /// Write `data` to `remote` on `host`, connecting first if needed — reusing
    /// the Files page's connection when it has one, else a short-lived one.
    static func put(_ data: Data, at remote: String, host: Host, store: HostStore) async throws {
        let borrowed = live[host.alias] != nil
        let m = obtain(host: host, store: store)
        defer { if !borrowed { m.release() } }
        if !m.connected {
            m.connect()
            while m.connecting { try await Task.sleep(for: .milliseconds(100)) }
            guard m.connected else { throw SFTPConnection.Fail(msg: m.status ?? "未连接") }
        }
        try await m.conn.upload(remote, data: data)
    }

    /// The page went away: disconnect now, or once the queue drains.
    func release() {
        if transfers.isActive { closeWhenIdle = true } else { disconnect() }
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
                var credential = credential
                if case .protected(let fp) = credential {
                    status = Localizer.shared.t("等待 Touch ID…", "Waiting for Touch ID…")
                    let (key, material) = try await SSHAgentController.shared.authorizedKey(fp)
                    status = Localizer.shared.t("连接中…", "Connecting…")
                    credential = .vaultKey(key, material: material)
                }
                let (home, items) = try await conn.connectAndList(
                    hostname: hostname, port: port, user: user, credential: credential)
                self.home = home
                path = home
                entries = items
                connected = true
                status = nil
                if let wanted = Self.pendingPath.removeValue(forKey: host.alias) {
                    await reveal(wanted, home: home)
                }
            } catch {
                status = "连接失败：\(friendly(error))"
            }
            connecting = false
        }
    }

    /// Returns the credential to try, or nil when the host needs a password we
    /// don't have yet.
    private func resolveCredential() -> SFTPConnection.Credential? {
        // 1) An explicit IdentityFile in the config wins. A Touch ID–protected
        //    key comes from the vault (its file may be in the Trash by now).
        if let idf = host.identityFile, !idf.isEmpty {
            if let info = SSHAgentController.shared.info(forPrivateKeyPath: idf) {
                return .protected(fingerprint: info.fingerprint)
            }
            if let key = readKey(idf) { return .key(key) }
        }
        // 2) A password saved in the Keychain.
        if let pw = store.password(for: host), !pw.isEmpty {
            return .password(pw)
        }
        // 3) Fall back to the default identity keys (what plain `ssh` tries when
        //    no IdentityFile is set), so agent/default-key hosts still work.
        if host.identityFile == nil || host.identityFile?.isEmpty == true {
            for candidate in ["~/.ssh/id_ed25519", "~/.ssh/id_rsa", "~/.ssh/id_ecdsa"] {
                if let info = SSHAgentController.shared.info(forPrivateKeyPath: candidate) {
                    return .protected(fingerprint: info.fingerprint)
                }
                if let key = readKey(candidate) { return .key(key) }
            }
        }
        return nil
    }

    private func readKey(_ path: String) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        return try? String(contentsOfFile: expanded, encoding: .utf8)
    }

    /// A path to show once the browser for that host connects (⌘-click on a
    /// remote path in an SSH terminal).
    static var pendingPath: [String: String] = [:]

    /// Go to `raw` — a directory, or a file's parent directory.
    private func reveal(_ raw: String, home: String) async {
        var p = raw
        if p == "~" { p = home } else if p.hasPrefix("~/") { p = join(home, String(p.dropFirst(2))) }
        if (try? await conn.list(p)) != nil { await load(p); return }
        let parent = (p as NSString).deletingLastPathComponent
        if !parent.isEmpty { await load(parent) }
    }

    /// Show `raw` (`~`-relative is fine): the directory, or a file's folder.
    func reveal(_ raw: String) {
        guard connected else { Self.pendingPath[host.alias] = raw; return }
        Task { await reveal(raw, home: home) }
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

    /// Queue a remote file or folder to copy into local `dir`.
    func download(_ e: SFTPEntry, toDirectory dir: URL) {
        let remote = join(path, e.name)
        let target = dir.appendingPathComponent(e.name)
        guard e.isDir else {
            transfers.enqueue([.init(direction: .download, name: e.name, remotePath: remote,
                                     localURL: target, total: e.size)])
            return
        }
        status = Localizer.shared.t("正在列出 \(e.name)…", "Listing \(e.name)…")
        Task {
            do {
                let tree = try await conn.walk(remote)
                let fm = FileManager.default
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                var items: [TransferQueue.Item] = []
                for n in tree {
                    let local = target.appendingPathComponent(n.relative)
                    if n.isDir {
                        try fm.createDirectory(at: local, withIntermediateDirectories: true)
                    } else {
                        items.append(.init(direction: .download, name: "\(e.name)/\(n.relative)",
                                           remotePath: "\(remote)/\(n.relative)", localURL: local, total: n.size))
                    }
                }
                status = nil
                transfers.enqueue(items)
                onTransferComplete?()
            } catch { status = "下载失败：\(friendly(error))" }
        }
    }

    /// Queue a local file or folder to copy into the current remote directory.
    func upload(from localURL: URL) {
        let name = localURL.lastPathComponent
        let remote = join(path, name)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: localURL.path, isDirectory: &isDir) else { return }
        guard isDir.boolValue else {
            let size = (try? FileManager.default.attributesOfItem(atPath: localURL.path))?[.size] as? UInt64 ?? 0
            transfers.enqueue([.init(direction: .upload, name: name, remotePath: remote,
                                     localURL: localURL, total: size)])
            return
        }
        Task {
            do {
                try await conn.makeDirectoryIfMissing(remote)
                var items: [TransferQueue.Item] = []
                let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
                let walker = FileManager.default.enumerator(at: localURL, includingPropertiesForKeys: keys)
                let base = localURL.standardizedFileURL.path
                while let url = walker?.nextObject() as? URL {
                    let rel = String(url.standardizedFileURL.path.dropFirst(base.count + 1))
                    let values = try? url.resourceValues(forKeys: Set(keys))
                    if values?.isDirectory == true {
                        try await conn.makeDirectoryIfMissing("\(remote)/\(rel)")
                    } else {
                        items.append(.init(direction: .upload, name: "\(name)/\(rel)", remotePath: "\(remote)/\(rel)",
                                           localURL: url, total: UInt64(values?.fileSize ?? 0)))
                    }
                }
                transfers.enqueue(items)
                await load(path)
            } catch { status = "上传失败：\(friendly(error))" }
        }
    }

    /// Open a remote file in a local editor; saves sync back (see RemoteEditStore).
    func editLocally(_ e: SFTPEntry, with editor: RemoteEditStore.Editor?) {
        guard !e.isDir else { return }
        let remote = join(path, e.name)
        status = Localizer.shared.t("正在打开 \(e.name)…", "Opening \(e.name)…")
        Task {
            do {
                let data = try await conn.download(remote)
                status = nil
                RemoteEditStore.shared.begin(alias: host.alias, remotePath: remote, data: data, editor: editor)
            } catch { status = "打开失败：\(friendly(error))" }
        }
    }

    /// Read a remote text file into a string (for AI editing).
    func readRemoteText(_ e: SFTPEntry) async -> String? {
        guard !e.isDir else { return nil }
        do { return String(data: try await conn.download(join(path, e.name)), encoding: .utf8) }
        catch { status = "读取失败：\(friendly(error))"; return nil }
    }

    /// Overwrite a remote file with new text (AI edit apply), then refresh.
    @discardableResult
    func writeRemoteText(_ e: SFTPEntry, _ text: String) async -> Bool {
        do {
            try await conn.upload(join(path, e.name), data: Data(text.utf8))
            await load(path)
            status = "已写回：\(e.name)"
            return true
        } catch { status = "写回失败：\(friendly(error))"; return false }
    }

    /// Hang up, dropping anything still queued.
    func disconnect() {
        transfers.cancelAll()
        connected = false
        closeWhenIdle = false
        if Self.live[host.alias] === self { Self.live[host.alias] = nil }
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
