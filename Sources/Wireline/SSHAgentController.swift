import AppKit
import LocalAuthentication
import Observation
import WirelineCore

/// Asks for Touch ID (or the login password when there is no biometry) before a
/// protected key is used.
///
/// - Grace: after a successful prompt, further uses within the user's chosen
///   window (每次 / 1 / 5 / 15 min, default 5) pass silently. The grace is global
///   across protected keys and is dropped on screen lock and system sleep.
/// - Coalescing: requests arriving while a prompt is on screen await that same
///   prompt instead of stacking new ones — a fleet run opening 8 connections at
///   once shows exactly one Touch ID dialog.
actor TouchIDGate {
    static let shared = TouchIDGate()

    static let graceKey = "agentGraceSeconds"
    static let graceChoices = [0, 60, 300, 900]
    nonisolated static var graceSeconds: Int {
        UserDefaults.standard.object(forKey: graceKey) as? Int ?? 300
    }

    private var graceUntil: Date?
    private var inFlight: Task<Bool, Never>?
    /// Bumped by `clearGrace`, so a prompt that finishes after a screen lock
    /// can't re-arm the grace it was started under.
    private var generation = 0

    /// Authorize one signature with `comment`'s key.
    func authorizeUse(comment: String) async -> Bool {
        if let until = graceUntil, Date() < until { return true }
        if let inFlight { return await inFlight.value }
        let reason = await MainActor.run {
            Localizer.shared.t("使用密钥「\(comment)」登录", "use the key “\(comment)” to sign in")
        }
        let started = generation
        let task = Task { await Self.evaluate(reason) }
        inFlight = task
        let ok = await task.value
        inFlight = nil
        let grace = Self.graceSeconds
        if ok, grace > 0, started == generation {
            graceUntil = Date().addingTimeInterval(TimeInterval(grace))
        }
        return ok
    }

    /// Always prompt — for import / unprotect, which grace never covers.
    func confirm(reason: String) async -> Bool {
        await Self.evaluate(reason)
    }

    func clearGrace() {
        graceUntil = nil
        generation += 1
    }

    /// `.deviceOwnerAuthentication` = Touch ID / Apple Watch, falling back to the
    /// login password. If the Mac can do neither, the use is denied.
    private static func evaluate(_ reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }
}

/// Runs Wireline's built-in ssh-agent and owns the protect / unprotect flows.
///
/// The agent listens while at least one key is protected. Every ssh/scp/sftp
/// Wireline spawns gets `SSH_AUTH_SOCK` pointed at it (`SSHAgentEnvironment`);
/// it signs with protected keys after `TouchIDGate`, and transparently forwards
/// everything else to the user's original agent, captured at launch.
@Observable
@MainActor
final class SSHAgentController {
    static let shared = SSHAgentController()

    private(set) var keys: [ProtectedKeyInfo] = []
    private(set) var socketPath: String?
    private(set) var lastError: String?

    @ObservationIgnored let vault = KeyVault()
    @ObservationIgnored private var server: SSHAgentServer?
    /// The user's own agent (launchd / 1Password / …) from our launch environment.
    @ObservationIgnored private let upstream = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"]

    var isRunning: Bool { socketPath != nil }

    private init() {
        // Drop the grace window whenever the Mac locks or sleeps.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { _ in Task { await TouchIDGate.shared.clearGrace() } }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { _ in Task { await TouchIDGate.shared.clearGrace() } }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { SSHAgentController.shared.stop() } }
    }

    /// Called at launch: start the agent if any key is protected.
    func startIfNeeded() { reload() }

    /// Re-read the vault and start / update / stop the agent to match.
    func reload() {
        keys = vault.list()
        guard !keys.isEmpty else { stop(); return }
        if server == nil { start() }
        let vault = self.vault
        server?.setIdentities(keys.map { info in
            let fp = info.fingerprint
            return SSHAgentIdentity(publicKeyBlob: info.publicBlob, comment: info.comment) {
                try vault.privateKey(fp)
            }
        })
    }

    private func start() {
        let path = Self.socketPath()
        let s = SSHAgentServer(socketPath: path, upstreamPath: upstream) { comment, fingerprint in
            await TouchIDGate.shared.authorizeUse(comment: comment.isEmpty ? fingerprint : comment)
        }
        do {
            try s.start()
            server = s
            socketPath = path
            lastError = nil
            SSHAgentEnvironment.socketPath = path
        } catch {
            lastError = "\(error)"
        }
    }

    private func stop() {
        server?.stop()
        server = nil
        socketPath = nil
        SSHAgentEnvironment.socketPath = nil
    }

    /// `~/Library/Application Support/Wireline/agent.sock`, unless that exceeds
    /// the 104-byte `sun_path` limit (very long home paths) — then `~/.wireline`.
    static func socketPath() -> String {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wireline/agent.sock").path
        if support.utf8.count <= SSHAgentServer.maxSocketPathLength { return support }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".wireline/agent.sock").path
    }

    /// What the user pastes into `~/.ssh/config` so their own terminal uses us too.
    var configSnippet: String? {
        socketPath.map { "Host *\n    IdentityAgent \"\($0)\"" }
    }

    func info(forFingerprint fp: String) -> ProtectedKeyInfo? {
        keys.first { $0.fingerprint == fp }
    }

    /// The protected key whose private file lived at `path` (for SFTP's
    /// IdentityFile lookups, which must keep working after a move to the Trash).
    func info(forPrivateKeyPath path: String) -> ProtectedKeyInfo? {
        let expanded = (path as NSString).expandingTildeInPath
        return keys.first { $0.originalPath == expanded }
    }

    /// An unencrypted original still in place means ssh can read it directly,
    /// bypassing Touch ID.
    func originalExposed(_ info: ProtectedKeyInfo) -> Bool {
        !info.originalWasEncrypted && FileManager.default.fileExists(atPath: info.originalPath)
    }

    /// Touch ID, then the key — for SFTP (Citadel signs in-process, not via the agent).
    func authorizedKey(_ fingerprint: String) async throws -> (key: SSHPrivateKey, material: String) {
        guard let info = info(forFingerprint: fingerprint) else { throw ProtectError.notProtected }
        guard await TouchIDGate.shared.authorizeUse(comment: info.comment.isEmpty ? fingerprint : info.comment) else {
            throw ProtectError.cancelled
        }
        let material = try vault.material(fingerprint)
        return (try SSHPrivateKey(openSSH: material), material)
    }

    // MARK: - Protect / unprotect

    enum ProtectError: LocalizedError {
        case noPrivateKey
        case needsPassphrase
        case decryptFailed
        case unsupported(String)
        case alreadyProtected
        case notProtected
        case cancelled

        var errorDescription: String? {
            let loc = Self.pick
            switch self {
            case .noPrivateKey: return loc("找不到私钥文件", "Private key file not found")
            case .needsPassphrase: return loc("该私钥有口令，请输入口令", "This key has a passphrase — enter it")
            case .decryptFailed: return loc("口令不正确，或私钥无法读取", "Wrong passphrase, or the key can't be read")
            case .unsupported(let t): return loc("不支持的密钥类型：\(t)", "Unsupported key type: \(t)")
            case .alreadyProtected: return loc("该密钥已受保护", "This key is already protected")
            case .notProtected: return loc("该密钥未受保护", "This key isn't protected")
            case .cancelled: return loc("未通过验证，已取消", "Authentication cancelled")
            }
        }

        /// `Localizer` is main-actor bound; errors may be described anywhere, so
        /// mirror its language choice from the same defaults key.
        private static func pick(_ zh: String, _ en: String) -> String {
            let lang = UserDefaults.standard.string(forKey: "appLanguage") ?? "system"
            let zhPreferred = lang == "zh" || (lang == "system" && (Locale.preferredLanguages.first ?? "en").hasPrefix("zh"))
            return zhPreferred ? zh : en
        }
    }

    /// Import the private key at `privatePath` into the vault (Touch ID required).
    /// Encrypted files need `passphrase`; they're decrypted from a temp copy.
    @discardableResult
    func protect(privatePath: String, passphrase: String?) async throws -> ProtectedKeyInfo {
        guard let text = try? String(contentsOfFile: privatePath, encoding: .utf8) else {
            throw ProtectError.noPrivateKey
        }
        let encrypted = SSHPrivateKey.isEncrypted(text)
        if encrypted, (passphrase ?? "").isEmpty { throw ProtectError.needsPassphrase }

        let material: String
        if !encrypted, (try? SSHPrivateKey(openSSH: text)) != nil {
            material = text
        } else {
            // Encrypted, or a legacy PEM/PKCS#8 file: let ssh-keygen rewrite a
            // temp copy as unencrypted openssh-key-v1.
            material = try await Self.normalize(privatePath, passphrase: encrypted ? passphrase : nil)
        }
        let key: SSHPrivateKey
        do { key = try SSHPrivateKey(openSSH: material) }
        catch SSHPrivateKey.ParseError.unsupportedKeyType(let t) { throw ProtectError.unsupported(t) }
        catch { throw ProtectError.decryptFailed }
        guard info(forFingerprint: key.fingerprint) == nil else { throw ProtectError.alreadyProtected }

        // Legacy PEM files carry no comment — borrow the .pub's, else the filename.
        let pubPath = privatePath + ".pub"
        var comment = key.comment
        if comment.isEmpty {
            let pubFields = ((try? String(contentsOfFile: pubPath, encoding: .utf8)) ?? "")
                .split(separator: " ", maxSplits: 2).map(String.init)
            comment = pubFields.count > 2 ? pubFields[2].trimmingCharacters(in: .whitespacesAndNewlines)
                                          : (privatePath as NSString).lastPathComponent
        }

        let name = comment
        guard await TouchIDGate.shared.confirm(reason: Localizer.shared.t(
            "用 Touch ID 保护密钥「\(name)」", "protect the key “\(name)” with Touch ID")) else {
            throw ProtectError.cancelled
        }

        let info = ProtectedKeyInfo(
            fingerprint: key.fingerprint, keyType: key.keyType, comment: comment,
            publicBlob: key.publicKeyBlob, originalPath: privatePath,
            originalWasEncrypted: encrypted, trashedPath: nil, protectedAt: Date())
        Self.ensurePublicKey(info)
        try vault.save(info, material: material)
        reload()
        return info
    }

    /// Move an unencrypted original to the Trash (reversible), keeping its `.pub`
    /// so `IdentityFile` / `IdentitiesOnly` configs still find the key via the agent.
    func moveOriginalToTrash(_ info: ProtectedKeyInfo) async throws {
        Self.ensurePublicKey(info)
        let url = URL(fileURLWithPath: info.originalPath)
        let moved = try await NSWorkspace.shared.recycle([url])
        var updated = info
        updated.trashedPath = moved[url]?.path ?? ""
        try vault.update(updated)
        reload()
    }

    /// Remove protection (Touch ID required). If we moved the original to the
    /// Trash, put it back (or rewrite it from the vault if the Trash was emptied).
    func unprotect(_ info: ProtectedKeyInfo) async throws {
        let name = info.comment.isEmpty ? info.fingerprint : info.comment
        guard await TouchIDGate.shared.confirm(reason: Localizer.shared.t(
            "取消密钥「\(name)」的 Touch ID 保护", "remove Touch ID protection from “\(name)”")) else {
            throw ProtectError.cancelled
        }
        let fm = FileManager.default
        if let trashed = info.trashedPath, !fm.fileExists(atPath: info.originalPath) {
            if !trashed.isEmpty, fm.fileExists(atPath: trashed) {
                try fm.moveItem(atPath: trashed, toPath: info.originalPath)
            } else {
                let material = try vault.material(info.fingerprint)
                guard fm.createFile(atPath: info.originalPath, contents: Data(material.utf8),
                                    attributes: [.posixPermissions: 0o600]) else {
                    throw ProtectError.noPrivateKey
                }
            }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: info.originalPath)
        }
        try vault.delete(info.fingerprint)
        reload()
    }

    private static func ensurePublicKey(_ info: ProtectedKeyInfo) {
        let pub = info.originalPath + ".pub"
        guard !FileManager.default.fileExists(atPath: pub) else { return }
        FileManager.default.createFile(atPath: pub, contents: Data((info.publicKeyLine + "\n").utf8),
                                       attributes: [.posixPermissions: 0o644])
    }

    /// Decrypt / convert a COPY of the key in a private 0700 temp dir with
    /// `ssh-keygen -p -N ""`. The passphrase reaches ssh-keygen through an askpass
    /// helper + env var (never argv, never disk). The dir is removed on every path.
    nonisolated private static func normalize(_ path: String, passphrase: String?) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(with: Result { try normalizeSync(path, passphrase: passphrase) })
            }
        }
    }

    nonisolated private static func normalizeSync(_ path: String, passphrase: String?) throws -> String {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("wireline-key-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: dir) }

        let copy = dir.appendingPathComponent("key")
        guard let original = fm.contents(atPath: path),
              fm.createFile(atPath: copy.path, contents: original, attributes: [.posixPermissions: 0o600]) else {
            throw ProtectError.noPrivateKey
        }
        let askpass = dir.appendingPathComponent("askpass.sh")
        guard fm.createFile(atPath: askpass.path,
                            contents: Data("#!/bin/sh\nprintf '%s\\n' \"$WIRELINE_ASKPASS_PW\"\n".utf8),
                            attributes: [.posixPermissions: 0o700]) else {
            throw ProtectError.decryptFailed
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        p.arguments = ["-q", "-p", "-N", "", "-f", copy.path]
        var env = ProcessInfo.processInfo.environment
        env["SSH_ASKPASS"] = askpass.path
        env["SSH_ASKPASS_REQUIRE"] = "force"
        env["WIRELINE_ASKPASS_PW"] = passphrase ?? ""
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let data = fm.contents(atPath: copy.path),
              let text = String(data: data, encoding: .utf8) else {
            throw ProtectError.decryptFailed
        }
        return text
    }
}
