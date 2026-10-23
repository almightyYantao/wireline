import AppKit
import Observation
import Security
import WirelineCore

/// Everything needed to dial one RDP host, resolved from `HostStore` when the
/// pane opens (the session doesn't hold the store).
struct RDPTarget: Sendable {
    var alias: String
    var hostname: String
    var port: Int
    var username: String?
    var domain: String?
    var password: String?
    /// SSH jump host for `ssh -N -L`, and its password (nil for key auth).
    var via: String?
    var viaPassword: String?
    /// The jump host's launch arguments.
    var viaArgs: [String] = []
    /// A fixed desktop size (nil: follow the pane).
    var fixedSize: RDPResolution?

    init(host: Host, password: String?, viaPassword: String?, viaArgs: [String] = []) {
        alias = host.alias
        hostname = host.connectHostname
        port = host.effectivePort
        username = host.user
        domain = host.rdpDomain
        self.password = password
        via = host.rdpVia
        self.viaPassword = viaPassword
        self.viaArgs = viaArgs
        fixedSize = host.rdpResolution.flatMap(RDPResolution.init)
    }
}

/// RDP preferences (Settings → 远程桌面 / config file), read where they persist.
enum RDPPreferences {
    static var commandKeyMode: RDPCommandKeyMode {
        UserDefaults.standard.string(forKey: "rdpCommandKeyMode").flatMap(RDPCommandKeyMode.init) ?? .controlShortcuts
    }
    /// Render at the Mac's full Retina resolution (Windows scaled to 200%).
    static var hiDPI: Bool { UserDefaults.standard.object(forKey: "rdpHiDPI") as? Bool ?? true }
    static var audio: Bool { UserDefaults.standard.object(forKey: "rdpAudio") as? Bool ?? true }
    static var clipboard: Bool { UserDefaults.standard.object(forKey: "rdpClipboard") as? Bool ?? true }
}

/// One RDP pane's connection lifecycle: optional SSH tunnel → FreeRDP →
/// running desktop, with the progress card, certificate / password questions,
/// clipboard sync, debounced dynamic resolution and reconnect.
@Observable
@MainActor
final class RDPSession {
    enum Stage: Int, Comparable, CaseIterable {
        case tunnel, connect, security, session
        static func < (a: Stage, b: Stage) -> Bool { a.rawValue < b.rawValue }
    }

    enum Status: Equatable {
        case idle
        case running(Stage)
        case established
        case failed(Stage, String)
        case closed
    }

    struct CertificatePrompt: Equatable {
        var info: RDPCertificateInfo
        var host: String
        var port: Int
        /// Set when we trusted a different certificate for this host before.
        var previous: RDPKnownHosts.Entry?
        var hostnameMismatch: Bool
    }

    struct PasswordPrompt: Equatable {
        var username: String
        var domain: String
        var retry: Bool
    }

    private(set) var target: RDPTarget
    private(set) var status: Status = .idle
    private(set) var startedAt = Date()
    private(set) var endedAt: Date?
    /// The progress card is up (appears after a short delay, like SSH's).
    private(set) var showsPanel = false
    /// Why the last running session ended (nil: closed normally / by us).
    private(set) var disconnectReason: String?
    var certificatePrompt: CertificatePrompt?
    var passwordPrompt: PasswordPrompt?
    var logsExpanded = false
    /// The remote desktop's size, "2560×1440" (nil before the first frame).
    private(set) var desktopSize: String?
    private(set) var log: [(t: TimeInterval, text: String)] = []

    let view = RDPView(frame: CGRect(x: 0, y: 0, width: 800, height: 500))

    /// Session-level reactions (TerminalSession's connection state / island).
    @ObservationIgnored var onStateChange: (ConnectionState) -> Void = { _ in }
    /// "Remember password" from the password card.
    @ObservationIgnored var onSavePassword: (String, String) -> Void = { _, _ in }
    @ObservationIgnored var onFocusRequest: () -> Void = {}

    @ObservationIgnored private var connection: RDPConnection?
    @ObservationIgnored private var tunnel: SSHTunnel?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var userClosed = false
    /// The user turned the certificate down this attempt (true: it had changed).
    @ObservationIgnored private var rejectedCertificate: Bool?
    @ObservationIgnored private var certReply: (@MainActor (Bool) -> Void)?
    @ObservationIgnored private var authReply: (@MainActor (RDPConnection.Credentials?) -> Void)?
    @ObservationIgnored private var resizeWork: DispatchWorkItem?
    @ObservationIgnored private var resizeReady = false
    @ObservationIgnored private var lastRequested: (UInt32, UInt32)?
    @ObservationIgnored private var clipboardTimer: Timer?
    @ObservationIgnored private var clipboardReady = false
    /// The Mac side of the shared clipboard (a private one in tests).
    @ObservationIgnored var pasteboard = NSPasteboard.general
    @ObservationIgnored private var lastPasteboardCount = NSPasteboard.general.changeCount
    @ObservationIgnored private var tunnelTask: Task<Void, Never>?

    /// Trusted certificates (a var so tests can point it at a scratch file).
    static var knownHosts = RDPKnownHosts(url: FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Wireline/rdp-known-hosts.json"))

    init(target: RDPTarget) {
        self.target = target
        view.onGeometryChange = { [weak self] in self?.scheduleResize() }
        view.onWillPaste = { [weak self] in self?.pushClipboard(force: true) }
        view.onClickFocus = { [weak self] in self?.onFocusRequest() }
    }

    var isConnected: Bool { status == .established }
    var isShowingFailure: Bool { if case .failed = status { return showsPanel } else { return false } }

    // MARK: Lifecycle

    func start() {
        generation += 1
        let gen = generation
        teardown()
        userClosed = false
        rejectedCertificate = nil
        disconnectReason = nil
        startedAt = Date()
        endedAt = nil
        log = []
        logsExpanded = false
        status = .running(target.via != nil ? .tunnel : .connect)
        onStateChange(.connecting)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.generation == gen, case .running = self.status else { return }
            wlAnimate(Motion.popIn) { self.showsPanel = true }
        }
        if let via = target.via {
            note(Localizer.shared.t("SSH 隧道经 \(via) → \(target.hostname):\(target.port)",
                                    "SSH tunnel via \(via) → \(target.hostname):\(target.port)"))
            let t = SSHTunnel()
            tunnel = t
            tunnelTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let port = try await t.start(via: via, password: self.target.viaPassword,
                                                 options: self.target.viaArgs,
                                                 host: self.target.hostname, port: self.target.port)
                    guard self.generation == gen else { return }
                    self.note(Localizer.shared.t("隧道就绪：127.0.0.1:\(port)", "Tunnel up: 127.0.0.1:\(port)"))
                    self.dial(host: "127.0.0.1", port: port, gen: gen)
                } catch {
                    guard self.generation == gen else { return }
                    let loc = Localizer.shared
                    let msg: String = switch error as? SSHTunnel.Failure {
                    case .exited(let line)?: loc.t("SSH 隧道失败：\(line)", "SSH tunnel failed: \(line)")
                    case .timedOut?: loc.t("SSH 隧道超时（\(via) 没有就绪）", "SSH tunnel timed out (\(via) never came up)")
                    case .spawn(let m)?: loc.t("无法启动 ssh：\(m)", "Couldn't start ssh: \(m)")
                    case nil: error.localizedDescription
                    }
                    self.fail(.tunnel, msg)
                }
            }
        } else {
            dial(host: target.hostname, port: target.port, gen: gen)
        }
    }

    private func dial(host: String, port: Int, gen: Int) {
        let scale = view.backingScale
        // A fixed resolution is taken literally: those pixels, Windows at 100%.
        let hiDPI = RDPPreferences.hiDPI && target.fixedSize == nil
        let size = if let fixed = target.fixedSize {
            (width: fixed.width, height: fixed.height)
        } else if view.pointSize.width > 80 && view.pointSize.height > 48 {
            RDPDisplay.desktopSize(points: view.pointSize, backingScale: hiDPI ? scale : 1)
        } else {
            (width: UInt32(1280), height: UInt32(800))
        }
        let desktopScale = hiDPI ? RDPDisplay.desktopScaleFactor(backingScale: scale) : 100
        let config = RDPConnection.Config(
            host: host, port: port, username: target.username, password: target.password,
            domain: target.domain, width: size.width, height: size.height,
            desktopScale: desktopScale, deviceScale: RDPDisplay.deviceScaleFactor(desktopScale: desktopScale),
            clipboard: RDPPreferences.clipboard, audio: RDPPreferences.audio, gfx: true)
        guard let c = RDPConnection(config: config) else {
            fail(.connect, Localizer.shared.t("无法初始化 FreeRDP", "Couldn't set up FreeRDP"))
            return
        }
        connection = c
        lastRequested = (size.width, size.height)
        note(Localizer.shared.t("连接 \(host):\(port) · \(size.width)×\(size.height) @\(desktopScale)%",
                                "Connecting \(host):\(port) · \(size.width)×\(size.height) @\(desktopScale)%"))
        wire(c, gen: gen)
        view.commandKeyMode = RDPPreferences.commandKeyMode
        if !c.start() {
            fail(.connect, Localizer.shared.t("无法启动 RDP 线程", "Couldn't start the RDP thread"))
        }
    }

    private func wire(_ c: RDPConnection, gen: Int) {
        let ev = c.events
        ev.stage = { [weak self] stage in
            guard let self, self.generation == gen else { return }
            switch stage {
            case .connecting: self.advance(.connect)
            case .security:
                self.advance(.security)
            case .session:
                self.advance(.session)
                self.note(Localizer.shared.t("已登录，正在打开桌面…", "Logged on, opening the desktop…"))
            case .running:
                self.established()
            }
        }
        ev.frame = { [weak self] in
            guard let self, self.generation == gen else { return }
            self.view.refresh()
        }
        ev.desktopSize = { [weak self] w, h in
            guard let self, self.generation == gen else { return }
            self.note("desktop \(w)×\(h)")
            if self.desktopSize != "\(w)×\(h)" { self.desktopSize = "\(w)×\(h)" }
            self.view.refresh()
        }
        ev.pointer = { [weak self] p in
            guard let self, self.generation == gen else { return }
            self.view.setRemotePointer(p)
        }
        ev.remoteClipboard = { [weak self] text in
            guard let self, self.generation == gen else { return }
            let pb = self.pasteboard
            pb.clearContents()
            pb.setString(text, forType: .string)
            self.lastPasteboardCount = pb.changeCount
        }
        ev.clipboardReady = { [weak self] in
            guard let self, self.generation == gen else { return }
            self.clipboardReady = true
            self.pushClipboard(force: true)
        }
        ev.resizeReady = { [weak self] in
            guard let self, self.generation == gen else { return }
            self.resizeReady = true
            self.scheduleResize()
        }
        ev.verifyCertificate = { [weak self] host, port, data, flags, reply in
            guard let self, self.generation == gen else { reply(false); return }
            self.verify(data: data, reply: reply)
        }
        ev.authenticate = { [weak self] reason, reply in
            guard let self, self.generation == gen else { reply(nil); return }
            self.authReply = reply
            wlAnimate(Motion.popIn) {
                self.passwordPrompt = PasswordPrompt(username: self.target.username ?? "",
                                                     domain: self.target.domain ?? "", retry: false)
            }
        }
        ev.disconnected = { [weak self] d in
            guard let self, self.generation == gen else { return }
            self.ended(d)
        }
    }

    /// Close for good (pane closed / 取消).
    func close() {
        userClosed = true
        generation += 1
        teardown()
        if case .running = status { status = .closed }
        if status == .established { status = .closed }
        showsPanel = false
        onStateChange(.disconnected)
    }

    func reconnect() {
        start()
    }

    /// The failure card's 关闭: the disconnected banner takes over.
    func dismissFailure() {
        wlAnimate(Motion.popOut) { showsPanel = false }
    }

    private func teardown() {
        tunnelTask?.cancel(); tunnelTask = nil
        certReply?(false); certReply = nil
        authReply?(nil); authReply = nil
        certificatePrompt = nil
        passwordPrompt = nil
        view.releaseAll()
        view.connection = nil
        connection?.close()
        connection = nil
        tunnel?.stop()
        tunnel = nil
        resizeWork?.cancel(); resizeWork = nil
        resizeReady = false
        clipboardReady = false
        clipboardTimer?.invalidate(); clipboardTimer = nil
    }

    // MARK: Progress

    private func note(_ text: String) {
        log.append((Date().timeIntervalSince(startedAt), text))
    }

    private func advance(_ stage: Stage) {
        guard case .running(let cur) = status, stage > cur else { return }
        wlAnimate(Motion.state) { status = .running(stage) }
    }

    private func established() {
        guard case .running = status else { return }
        view.connection = connection
        view.refresh()
        wlAnimate(Motion.state) { status = .established }
        onStateChange(.connected)
        note(Localizer.shared.t("桌面已就绪", "Desktop ready"))
        startClipboardSync()
        if view.window?.firstResponder === view { connection?.sendFocusIn(capsLock: NSEvent.modifierFlags.contains(.capsLock)) }
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.generation == gen, self.status == .established else { return }
            wlAnimate(Motion.popOut) { self.showsPanel = false }
        }
        scheduleResize()
    }

    private func fail(_ stage: Stage, _ message: String) {
        note(message)
        let wasUp = status == .established
        teardown()
        endedAt = Date()
        if wasUp {
            disconnectReason = message
            status = .closed
            showsPanel = false
        } else {
            wlAnimate(Motion.popIn) {
                status = .failed(stage, message)
                logsExpanded = true
                showsPanel = true
            }
        }
        onStateChange(.disconnected)
    }

    private func ended(_ d: RDPConnection.Disconnect) {
        if userClosed { return }
        let text = RDPErrorText.message(errorName: d.errorName, errinfoName: d.errinfoName)
        let loc = Localizer.shared
        note("\(d.errorName) \(d.errinfoName)".trimmingCharacters(in: .whitespaces))
        switch status {
        case .established:
            fail(.session, text.map { loc.t($0.zh, $0.en) } ?? loc.t("连接已断开", "Connection closed"))
        case .running(let stage):
            if text?.isAuthFailure == true { target.password = nil }
            if let changed = rejectedCertificate {
                // The TLS error that follows says nothing useful: say why.
                fail(stage, changed
                     ? loc.t("服务器证书与上次信任的不一致，已拒绝连接。确认是正常更换后可重试并信任新证书。",
                             "The server's certificate differs from the one trusted before, so the connection was refused. If the change is expected, retry and trust the new one.")
                     : loc.t("已拒绝服务器证书。", "The server's certificate was rejected."))
                return
            }
            fail(stage, text.map { loc.t($0.zh, $0.en) } ?? loc.t("连接被关闭", "The connection was closed"))
        default:
            break
        }
    }

    /// The failure was about credentials: ask for the password on retry.
    var failedOnCredentials: Bool {
        guard case .failed = status else { return false }
        return target.password == nil
    }

    // MARK: Certificates

    private func verify(data: Data, reply: @escaping @MainActor (Bool) -> Void) {
        guard let der = RDPCertificateInfo.der(from: data), let cert = SecCertificateCreateWithData(nil, der as CFData) else {
            note(Localizer.shared.t("无法解析服务器证书", "Couldn't parse the server certificate"))
            reply(false)
            return
        }
        let info = RDPCertificateInfo(fingerprint: RDPCertificateInfo.fingerprint(der: der),
                                      subject: (SecCertificateCopySubjectSummary(cert) as String?) ?? "?",
                                      issuer: Self.issuer(of: cert))
        // A CA-signed certificate for the real host name passes as is.
        let policy = SecPolicyCreateSSL(true, target.hostname as CFString)
        var trust: SecTrust?
        var hostnameOK = false
        if SecTrustCreateWithCertificates(cert, policy, &trust) == errSecSuccess, let trust {
            hostnameOK = SecTrustEvaluateWithError(trust, nil)
        }
        if hostnameOK {
            note(Localizer.shared.t("证书受系统信任：\(info.subject)", "Certificate trusted by the system: \(info.subject)"))
            reply(true)
            return
        }
        // Self-signed (the Windows default): trust on first use, per real host:port.
        switch Self.knownHosts.verdict(host: target.hostname, port: target.port, fingerprint: info.fingerprint) {
        case .trusted:
            note(Localizer.shared.t("证书与上次一致", "Certificate matches the trusted one"))
            reply(true)
        case .unknown:
            certReply = reply
            wlAnimate(Motion.popIn) {
                certificatePrompt = CertificatePrompt(info: info, host: target.hostname, port: target.port,
                                                      previous: nil, hostnameMismatch: false)
            }
        case .changed(let old):
            certReply = reply
            wlAnimate(Motion.popIn) {
                certificatePrompt = CertificatePrompt(info: info, host: target.hostname, port: target.port,
                                                      previous: old, hostnameMismatch: false)
            }
        }
    }

    private static func issuer(of cert: SecCertificate) -> String {
        guard let values = SecCertificateCopyValues(cert, [kSecOIDX509V1IssuerName] as CFArray, nil) as? [CFString: Any],
              let issuer = values[kSecOIDX509V1IssuerName] as? [CFString: Any],
              let items = issuer[kSecPropertyKeyValue] as? [[CFString: Any]] else { return "" }
        return items.compactMap { $0[kSecPropertyKeyValue] as? String }.joined(separator: ", ")
    }

    func answerCertificate(trust: Bool) {
        guard let prompt = certificatePrompt else { return }
        if trust { Self.knownHosts.trust(host: prompt.host, port: prompt.port, info: prompt.info) }
        note(trust ? Localizer.shared.t("已信任证书 \(prompt.info.fingerprint.prefix(23))…", "Trusted certificate \(prompt.info.fingerprint.prefix(23))…")
                   : Localizer.shared.t("已拒绝证书", "Certificate rejected"))
        wlAnimate(Motion.popOut) { certificatePrompt = nil }
        let reply = certReply
        certReply = nil
        reply?(trust)
        if !trust { rejectedCertificate = prompt.previous != nil }
    }

    // MARK: Credentials

    func answerPassword(username: String, password: String, domain: String, remember: Bool) {
        let reply = authReply
        authReply = nil
        wlAnimate(Motion.popOut) { passwordPrompt = nil }
        target.username = username.isEmpty ? target.username : username
        target.domain = domain.isEmpty ? nil : domain
        target.password = password
        if remember, !password.isEmpty { onSavePassword(target.alias, password) }
        if let reply {
            reply(RDPConnection.Credentials(username: username, password: password, domain: target.domain))
        } else {
            start()   // asked before dialling (retry after a credential failure)
        }
    }

    func cancelPassword() {
        let reply = authReply
        authReply = nil
        wlAnimate(Motion.popOut) { passwordPrompt = nil }
        reply?(nil)
    }

    /// 重试 after a credential failure: ask first, then dial.
    func retryAskingPassword() {
        wlAnimate(Motion.popIn) {
            passwordPrompt = PasswordPrompt(username: target.username ?? "", domain: target.domain ?? "", retry: true)
        }
    }

    // MARK: Dynamic resolution

    /// Ask the server to match the pane, once its size has settled: never
    /// during a layout animation (the frame stretches meanwhile) or a live
    /// window drag, and not for a pane squeezed away behind a zoomed one.
    func scheduleResize() {
        resizeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.applyResize() }
        }
        resizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func applyResize() {
        guard resizeReady, status == .established, target.fixedSize == nil, let connection else { return }
        guard TerminalResizeGate.shared.isIdle, !view.inLiveResize else { scheduleResize(); return }
        let pts = view.pointSize
        guard pts.width >= 80, pts.height >= 48 else { return }
        let hiDPI = RDPPreferences.hiDPI
        let scale = view.backingScale
        let size = RDPDisplay.desktopSize(points: pts, backingScale: hiDPI ? scale : 1)
        guard lastRequested.map({ $0 != (size.width, size.height) }) ?? true else { return }
        if view.desktop.width == size.width, view.desktop.height == size.height { lastRequested = (size.width, size.height); return }
        let ds = hiDPI ? RDPDisplay.desktopScaleFactor(backingScale: scale) : 100
        if connection.resize(width: size.width, height: size.height, desktopScale: ds,
                             deviceScale: RDPDisplay.deviceScaleFactor(desktopScale: ds)) {
            lastRequested = (size.width, size.height)
            note("resize → \(size.width)×\(size.height)")
        }
    }

    // MARK: Clipboard

    private func startClipboardSync() {
        clipboardTimer?.invalidate()
        guard RDPPreferences.clipboard else { return }
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pushClipboard(force: false) }
        }
        RunLoop.main.add(t, forMode: .common)
        clipboardTimer = t
    }

    /// Offer the Mac clipboard's text to the server when it changed (or now).
    func pushClipboard(force: Bool) {
        guard clipboardReady, let connection else { return }
        let pb = pasteboard
        guard force || pb.changeCount != lastPasteboardCount else { return }
        lastPasteboardCount = pb.changeCount
        connection.setLocalClipboard(pb.string(forType: .string))
    }
}
