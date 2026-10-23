import Foundation
import CFreeRDPShim

/// One FreeRDP session (see Sources/CFreeRDPShim/include/wlrdp.h).
///
/// Thread-safe: FreeRDP runs on the shim's own thread; every callback is
/// copied out there and delivered on the main thread through `events`. The
/// two questions FreeRDP asks synchronously — trust this certificate? which
/// credentials? — park the RDP thread on a semaphore until the main thread
/// answers (or the connection is stopped, which answers "no").
final class RDPConnection: @unchecked Sendable {
    struct Config: Sendable {
        var host: String
        var port: Int
        var username: String?
        var password: String?
        var domain: String?
        var width: UInt32
        var height: UInt32
        var desktopScale: UInt32
        var deviceScale: UInt32
        var clipboard = true
        var audio = true
        var gfx = true
    }

    enum Stage: Int, Comparable, Sendable {
        case connecting = 1, security, session, running
        static func < (a: Stage, b: Stage) -> Bool { a.rawValue < b.rawValue }
    }

    enum Pointer: Sendable {
        case image(rgba: Data, width: Int, height: Int, hotX: Int, hotY: Int)
        case hidden
        case system
    }

    struct Disconnect: Sendable {
        var error: UInt32
        var errorName: String
        var errinfo: UInt32
        var errinfoName: String
    }

    struct Credentials: Sendable {
        var username: String
        var password: String
        var domain: String?
    }

    enum AuthReason: Sendable { case nla, tls, rdp, other }

    /// Main-thread receivers. Set them before `start()`.
    @MainActor final class Events {
        var stage: (Stage) -> Void = { _ in }
        var frame: () -> Void = {}
        var desktopSize: (UInt32, UInt32) -> Void = { _, _ in }
        var pointer: (Pointer) -> Void = { _ in }
        var remoteClipboard: (String) -> Void = { _ in }
        var clipboardReady: () -> Void = {}
        var resizeReady: () -> Void = {}
        var disconnected: (Disconnect) -> Void = { _ in }
        /// (host, port, certificate bytes, flags, reply). Reply exactly once.
        var verifyCertificate: (String, Int, Data, UInt32, @escaping @MainActor (Bool) -> Void) -> Void = { _, _, _, _, r in r(false) }
        /// Reply with credentials, or nil to cancel.
        var authenticate: (AuthReason, @escaping @MainActor (Credentials?) -> Void) -> Void = { _, r in r(nil) }
    }

    @MainActor let events = Events()

    private let lock = NSLock()
    private var session: OpaquePointer?
    private var stopped = false
    /// A pending synchronous question, answered "no" on stop.
    private var pendingAnswer: (() -> Void)?

    @MainActor init?(config: Config) {
        let made: OpaquePointer? = config.host.withCString { host in
            withOptionalCString(config.username) { user in
            withOptionalCString(config.password) { pass in
            withOptionalCString(config.domain) { domain in
            "Wireline".withCString { name in
                var c = wlrdp_config()
                c.host = host
                c.port = UInt16(clamping: config.port)
                c.username = user
                c.password = pass
                c.domain = domain
                c.client_name = name
                c.width = config.width
                c.height = config.height
                c.desktop_scale = config.desktopScale
                c.device_scale = config.deviceScale
                c.clipboard = config.clipboard ? 1 : 0
                c.audio = config.audio ? 1 : 0
                c.gfx = config.gfx ? 1 : 0
                return withUnsafePointer(to: c) { cp in
                    withUnsafePointer(to: Self.makeCallbacks()) { wlrdp_create(cp, $0) }
                }
            }}}}
        }
        guard let made else { return nil }
        session = made
        // Unretained: `close()` keeps `self` alive until the RDP thread is joined.
        wlrdp_set_user(made, Unmanaged.passUnretained(self).toOpaque())
    }

    deinit {
        // `close()` normally ran already; this is the safety net.
        if let s = session { wlrdp_destroy(s) }
    }

    func start() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let s = session, !stopped else { return false }
        return wlrdp_start(s) == 0
    }

    /// End the session. Returns at once; the RDP thread is joined and freed
    /// on a background queue. `disconnected` still fires.
    func close() {
        lock.lock()
        guard !stopped, let s = session else { lock.unlock(); return }
        stopped = true
        session = nil
        let answer = pendingAnswer
        pendingAnswer = nil
        lock.unlock()
        answer?()
        wlrdp_stop(s)
        // Keep `self` alive until the thread is gone: callbacks still use it.
        let doomed = SessionHandle(s, owner: self)
        DispatchQueue.global(qos: .utility).async { doomed.destroy() }
    }

    // MARK: Main-thread calls (all no-ops once closed)

    private func with(_ body: (OpaquePointer) -> Void) {
        lock.lock(); defer { lock.unlock() }
        if let s = session { body(s) }
    }

    var desktopSize: (width: UInt32, height: UInt32) {
        var w: UInt32 = 0, h: UInt32 = 0
        with { wlrdp_desktop_size($0, &w, &h) }
        return (w, h)
    }

    /// See `wlrdp_copy_dirty`. Returns the copied rect, nil if nothing to do,
    /// and `.mismatch` if the buffer is the wrong size.
    enum CopyResult { case copied(CGRect), unchanged, mismatch }

    func copyDirty(into base: UnsafeMutableRawPointer, stride: Int, width: Int, height: Int, full: Bool) -> CopyResult {
        var result = CopyResult.unchanged
        with { s in
            var r = wlrdp_rect()
            let rc = wlrdp_copy_dirty(s, base.assumingMemoryBound(to: UInt8.self), stride,
                                      UInt32(width), UInt32(height), full ? 1 : 0, &r)
            if rc == 1 { result = .copied(CGRect(x: Int(r.x), y: Int(r.y), width: Int(r.w), height: Int(r.h))) }
            else if rc < 0 { result = .mismatch }
        }
        return result
    }

    func sendKey(_ code: UInt8, extended: Bool, down: Bool) {
        with { wlrdp_send_key($0, code, extended ? 1 : 0, down ? 1 : 0) }
    }

    func sendUnicode(_ text: String) {
        with { s in
            for unit in text.utf16 {
                wlrdp_send_unicode(s, unit, 1)
                wlrdp_send_unicode(s, unit, 0)
            }
        }
    }

    func sendMouseMove(x: UInt16, y: UInt16) { with { wlrdp_send_mouse_move($0, x, y) } }

    func sendMouseButton(_ button: Int, down: Bool, x: UInt16, y: UInt16) {
        with { wlrdp_send_mouse_button($0, Int32(button), down ? 1 : 0, x, y) }
    }

    func sendWheel(vertical: Bool, delta: Int, x: UInt16, y: UInt16) {
        with { wlrdp_send_wheel($0, vertical ? 1 : 0, Int32(delta), x, y) }
    }

    func sendFocusIn(capsLock: Bool) { with { wlrdp_send_focus_in($0, capsLock ? 1 : 0) } }

    @discardableResult
    func resize(width: UInt32, height: UInt32, desktopScale: UInt32, deviceScale: UInt32) -> Bool {
        var ok = false
        with { ok = wlrdp_resize($0, width, height, desktopScale, deviceScale) == 1 }
        return ok
    }

    @discardableResult
    func setLocalClipboard(_ text: String?) -> Bool {
        var ok = false
        let units = Array((text ?? "").utf16)
        with { s in
            ok = units.withUnsafeBufferPointer { wlrdp_set_local_clipboard(s, $0.baseAddress, $0.count) } == 1
        }
        return ok
    }

    // MARK: RDP-thread side

    private func post(_ body: @escaping @MainActor (Events) -> Void) {
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated { body(self.events) }
        }
    }

    /// Ask the main thread something and wait for the answer. `defaultValue`
    /// if the connection is (or gets) stopped.
    private func ask<T: Sendable>(_ defaultValue: T, _ question: @escaping @MainActor (Events, @escaping @MainActor (T) -> Void) -> Void) -> T {
        let sem = DispatchSemaphore(value: 0)
        let box = AnswerBox(defaultValue)
        lock.lock()
        if stopped { lock.unlock(); return defaultValue }
        pendingAnswer = { box.set(defaultValue); sem.signal() }
        lock.unlock()
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated {
                question(self.events) { value in
                    self.lock.lock()
                    let pending = self.pendingAnswer
                    self.pendingAnswer = nil
                    self.lock.unlock()
                    guard pending != nil else { return }   // already answered by close()
                    box.set(value)
                    sem.signal()
                }
            }
        }
        sem.wait()
        return box.get()
    }

    private static func me(_ user: UnsafeMutableRawPointer?) -> RDPConnection? {
        user.map { Unmanaged<RDPConnection>.fromOpaque($0).takeUnretainedValue() }
    }

    private static func makeCallbacks() -> wlrdp_callbacks {
        var cb = wlrdp_callbacks()
        cb.on_stage = { user, stage in
            guard let c = RDPConnection.me(user), let s = Stage(rawValue: Int(stage.rawValue)) else { return }
            c.post { $0.stage(s) }
        }
        cb.on_frame = { user in
            RDPConnection.me(user)?.post { $0.frame() }
        }
        cb.on_desktop_size = { user, w, h in
            RDPConnection.me(user)?.post { $0.desktopSize(w, h) }
        }
        cb.on_verify_certificate = { user, host, port, data, length, flags in
            guard let c = RDPConnection.me(user), let data else { return 0 }
            let bytes = Data(bytes: data, count: length)
            let h = host.map { String(cString: $0) } ?? ""
            let p = Int(port)
            let ok = c.ask(false) { ev, reply in ev.verifyCertificate(h, p, bytes, flags, reply) }
            return ok ? 1 : 0
        }
        cb.on_authenticate = { user, reason in
            guard let c = RDPConnection.me(user) else { return 0 }
            let r: AuthReason = switch reason {
            case WLRDP_AUTH_NLA: .nla
            case WLRDP_AUTH_TLS: .tls
            case WLRDP_AUTH_RDP: .rdp
            default: .other
            }
            let creds: Credentials? = c.ask(nil) { ev, reply in ev.authenticate(r, reply) }
            guard let creds else { return 0 }
            c.lock.lock()
            let s = c.session
            c.lock.unlock()
            guard let s else { return 0 }
            creds.username.withCString { u in
                creds.password.withCString { p in
                    withOptionalCString(creds.domain) { d in wlrdp_set_credentials(s, u, p, d) }
                }
            }
            return 1
        }
        cb.on_pointer = { user, kind, rgba, w, h, hx, hy in
            guard let c = RDPConnection.me(user) else { return }
            let pointer: Pointer
            switch kind {
            case WLRDP_POINTER_IMAGE:
                guard let rgba, w > 0, h > 0 else { return }
                pointer = .image(rgba: Data(bytes: rgba, count: Int(w) * Int(h) * 4),
                                 width: Int(w), height: Int(h), hotX: Int(hx), hotY: Int(hy))
            case WLRDP_POINTER_HIDDEN: pointer = .hidden
            default: pointer = .system
            }
            c.post { $0.pointer(pointer) }
        }
        cb.on_remote_clipboard = { user, utf16, units in
            guard let c = RDPConnection.me(user) else { return }
            let text = utf16.map { String(utf16CodeUnits: $0, count: units) } ?? ""
            c.post { $0.remoteClipboard(text) }
        }
        cb.on_clipboard_ready = { user in RDPConnection.me(user)?.post { $0.clipboardReady() } }
        cb.on_resize_ready = { user in RDPConnection.me(user)?.post { $0.resizeReady() } }
        cb.on_disconnected = { user, error, ename, errinfo, iname in
            guard let c = RDPConnection.me(user) else { return }
            let d = Disconnect(error: error, errorName: ename.map { String(cString: $0) } ?? "",
                               errinfo: errinfo, errinfoName: iname.map { String(cString: $0) } ?? "")
            c.post { $0.disconnected(d) }
        }
        return cb
    }
}

/// Carries the C session (and its owner, whose callbacks it still calls) to
/// the background queue that joins and frees it.
private final class SessionHandle: @unchecked Sendable {
    private let session: OpaquePointer
    private let owner: RDPConnection
    init(_ s: OpaquePointer, owner: RDPConnection) { session = s; self.owner = owner }
    func destroy() { wlrdp_destroy(session); _ = owner }
}

private final class AnswerBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
}

private func withOptionalCString<R>(_ s: String?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
    guard let s, !s.isEmpty else { return body(nil) }
    return s.withCString { body($0) }
}
