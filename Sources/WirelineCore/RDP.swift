import Foundation
import CryptoKit

// Pure parts of RDP panes (no FreeRDP, no AppKit), so they're unit-testable:
// key mapping, desktop sizing, wheel accumulation, error wording, and the
// trust-on-first-use certificate store.

// MARK: - Keyboard

/// macOS virtual key codes (`NSEvent.keyCode`, the `kVK_*` constants) →
/// PC set-1 scancodes, which is what RDP sends. Layout-independent: the remote
/// Windows keyboard layout turns scancodes into characters, exactly like a
/// physical PC keyboard plugged into that machine.
public enum RDPKeyMap {
    public struct Scancode: Hashable, Sendable {
        public let code: UInt8
        public let extended: Bool
        public init(_ code: UInt8, extended: Bool = false) { self.code = code; self.extended = extended }
    }

    /// `iso`: an ISO keyboard (key left of Z). Mac ISO keyboards report the
    /// key left of 1 as `kVK_ISO_Section` and the key left of Z as
    /// `kVK_ANSI_Grave` — the opposite of where a PC has them — so swap.
    public static func scancode(forKeyCode keyCode: UInt16, iso: Bool = false) -> Scancode? {
        if iso {
            if keyCode == 0x0A { return Scancode(0x29) }    // § / ^ : left of 1 → OEM_3 (grave)
            if keyCode == 0x32 { return Scancode(0x56) }    // ` < : left of Z → OEM_102
        }
        return table[keyCode]
    }

    /// The modifier keys, for `flagsChanged`: which keyCode is which modifier.
    public enum Modifier: Sendable { case shift, control, option, command, capsLock, function }

    public static func modifier(forKeyCode keyCode: UInt16) -> Modifier? {
        switch keyCode {
        case 0x38, 0x3C: return .shift
        case 0x3B, 0x3E: return .control
        case 0x3A, 0x3D: return .option
        case 0x37, 0x36: return .command
        case 0x39: return .capsLock
        case 0x3F: return .function
        default: return nil
        }
    }

    public static let leftControl = Scancode(0x1D)
    public static let leftWindows = Scancode(0x5B, extended: true)

    private static let table: [UInt16: Scancode] = [
        // Letters / digits / punctuation (ANSI positions)
        0x00: .init(0x1E), 0x01: .init(0x1F), 0x02: .init(0x20), 0x03: .init(0x21),  // A S D F
        0x04: .init(0x23), 0x05: .init(0x22), 0x06: .init(0x2C), 0x07: .init(0x2D),  // H G Z X
        0x08: .init(0x2E), 0x09: .init(0x2F), 0x0A: .init(0x56), 0x0B: .init(0x30),  // C V § B
        0x0C: .init(0x10), 0x0D: .init(0x11), 0x0E: .init(0x12), 0x0F: .init(0x13),  // Q W E R
        0x10: .init(0x15), 0x11: .init(0x14), 0x12: .init(0x02), 0x13: .init(0x03),  // Y T 1 2
        0x14: .init(0x04), 0x15: .init(0x05), 0x16: .init(0x07), 0x17: .init(0x06),  // 3 4 6 5
        0x18: .init(0x0D), 0x19: .init(0x0A), 0x1A: .init(0x08), 0x1B: .init(0x0C),  // = 9 7 -
        0x1C: .init(0x09), 0x1D: .init(0x0B), 0x1E: .init(0x1B), 0x1F: .init(0x18),  // 8 0 ] O
        0x20: .init(0x16), 0x21: .init(0x1A), 0x22: .init(0x17), 0x23: .init(0x19),  // U [ I P
        0x24: .init(0x1C), 0x25: .init(0x26), 0x26: .init(0x24), 0x27: .init(0x28),  // ⏎ L J '
        0x28: .init(0x25), 0x29: .init(0x27), 0x2A: .init(0x2B), 0x2B: .init(0x33),  // K ; \ ,
        0x2C: .init(0x35), 0x2D: .init(0x31), 0x2E: .init(0x32), 0x2F: .init(0x34),  // / N M .
        0x30: .init(0x0F), 0x31: .init(0x39), 0x32: .init(0x29), 0x33: .init(0x0E),  // ⇥ ␣ ` ⌫
        0x35: .init(0x01),                                                            // ⎋
        // Modifiers (⌘ → Windows key; see RDPCommandKeyMode for the alternative)
        0x37: .init(0x5B, extended: true), 0x36: .init(0x5C, extended: true),
        0x38: .init(0x2A), 0x3C: .init(0x36),                                         // ⇧ L/R
        0x3B: .init(0x1D), 0x3E: .init(0x1D, extended: true),                         // ⌃ L/R
        0x3A: .init(0x38), 0x3D: .init(0x38, extended: true),                         // ⌥ L/R (AltGr)
        0x39: .init(0x3A),                                                            // ⇪
        // Function keys
        0x7A: .init(0x3B), 0x78: .init(0x3C), 0x63: .init(0x3D), 0x76: .init(0x3E),  // F1-F4
        0x60: .init(0x3F), 0x61: .init(0x40), 0x62: .init(0x41), 0x64: .init(0x42),  // F5-F8
        0x65: .init(0x43), 0x6D: .init(0x44), 0x67: .init(0x57), 0x6F: .init(0x58),  // F9-F12
        0x69: .init(0x64), 0x6B: .init(0x65), 0x71: .init(0x66), 0x6A: .init(0x67),  // F13-F16
        0x40: .init(0x68), 0x4F: .init(0x69), 0x50: .init(0x6A), 0x5A: .init(0x6B),  // F17-F20
        // Navigation (E0-prefixed)
        0x72: .init(0x52, extended: true),   // Help → Insert
        0x73: .init(0x47, extended: true),   // Home
        0x74: .init(0x49, extended: true),   // Page Up
        0x75: .init(0x53, extended: true),   // ⌦ Delete
        0x77: .init(0x4F, extended: true),   // End
        0x79: .init(0x51, extended: true),   // Page Down
        0x7B: .init(0x4B, extended: true), 0x7C: .init(0x4D, extended: true),         // ← →
        0x7D: .init(0x50, extended: true), 0x7E: .init(0x48, extended: true),         // ↓ ↑
        0x6E: .init(0x5D, extended: true),   // context menu → Apps
        // Keypad
        0x52: .init(0x52), 0x53: .init(0x4F), 0x54: .init(0x50), 0x55: .init(0x51),  // 0 1 2 3
        0x56: .init(0x4B), 0x57: .init(0x4C), 0x58: .init(0x4D), 0x59: .init(0x47),  // 4 5 6 7
        0x5B: .init(0x48), 0x5C: .init(0x49),                                         // 8 9
        0x41: .init(0x53), 0x43: .init(0x37), 0x45: .init(0x4E), 0x4E: .init(0x4A),  // . * + -
        0x4B: .init(0x35, extended: true), 0x4C: .init(0x1C, extended: true),         // / ⌤
        0x47: .init(0x45),                   // Clear → Num Lock
        0x51: .init(0x59),                   // keypad =
        // Media
        0x48: .init(0x30, extended: true), 0x49: .init(0x2E, extended: true),         // vol + / -
        0x4A: .init(0x20, extended: true),                                            // mute
        // JIS
        0x5D: .init(0x7D), 0x5E: .init(0x73), 0x5F: .init(0x7E),                      // ¥ _ keypad ,
        0x66: .init(0x7B), 0x68: .init(0x70),                                         // 英数 かな
    ]
}

/// What ⌘ does in an RDP pane.
public enum RDPCommandKeyMode: String, CaseIterable, Sendable {
    /// ⌘ is the Windows key (⌘ alone opens Start, ⌘R is Win+R …).
    case windowsKey
    /// ⌘C / ⌘V / ⌘X / ⌘A / ⌘Z … are sent as Ctrl+key, so Mac muscle memory
    /// works; ⌘ alone does nothing remote.
    case controlShortcuts

    /// Letters (by keyCode) that `controlShortcuts` sends as Ctrl+letter rather
    /// than leaving to Wireline's menus.
    public static let controlLetters: Set<UInt16> = [
        0x00, // A select all
        0x08, // C copy
        0x09, // V paste
        0x07, // X cut
        0x06, // Z undo
        0x10, // Y redo
        0x01, // S save
        0x03, // F find
        0x23, // P print
        0x0F, // R reload
        0x0B, // B bold
        0x22, // I italic
        0x20, // U underline
        0x2D, // N new
        0x1F, // O open
    ]
}

// MARK: - Desktop sizing

public enum RDPDisplay {
    /// The remote desktop size for a pane: device pixels, even width (an RDP
    /// display-control requirement), clamped to 200…8192.
    public static func desktopSize(points: CGSize, backingScale: CGFloat) -> (width: UInt32, height: UInt32) {
        let scale = max(1, backingScale)
        var w = Int((points.width * scale).rounded(.down))
        var h = Int((points.height * scale).rounded(.down))
        w = min(max(w, 200), 8192)
        h = min(max(h, 200), 8192)
        w &= ~1
        return (UInt32(w), UInt32(h))
    }

    /// Windows' desktop scale factor (percent) for a backing scale: 200 on
    /// Retina, so text keeps its size while rendering at full resolution.
    public static func desktopScaleFactor(backingScale: CGFloat) -> UInt32 {
        UInt32(min(max((backingScale * 100).rounded(), 100), 500))
    }

    /// RDP's device scale factor takes only 100, 140 or 180.
    public static func deviceScaleFactor(desktopScale: UInt32) -> UInt32 {
        desktopScale >= 180 ? 180 : desktopScale >= 140 ? 140 : 100
    }

    /// A view point → remote pixel coordinate, clamped into the desktop.
    public static func remotePoint(_ p: CGPoint, viewSize: CGSize, desktop: (width: UInt32, height: UInt32)) -> (x: UInt16, y: UInt16) {
        guard viewSize.width > 0, viewSize.height > 0, desktop.width > 0, desktop.height > 0 else { return (0, 0) }
        let x = (p.x / viewSize.width * CGFloat(desktop.width)).rounded(.down)
        let y = (p.y / viewSize.height * CGFloat(desktop.height)).rounded(.down)
        let cx = min(max(x, 0), CGFloat(desktop.width - 1))
        let cy = min(max(y, 0), CGFloat(desktop.height - 1))
        return (UInt16(cx), UInt16(cy))
    }
}

/// Turns macOS scroll deltas into RDP wheel events (120 units per notch,
/// at most 255 per event). Trackpads send many tiny precise deltas: they're
/// accumulated and sent in small steps, so scrolling stays smooth on Windows
/// apps that honour fractional wheel deltas and still adds up for those that don't.
public struct RDPWheelAccumulator: Sendable {
    private var pending: Double = 0
    public init() {}

    /// `delta` in points (precise) or lines (wheel mouse); positive = content
    /// moves down (scroll up), as in `NSEvent.scrollingDeltaY`.
    /// Returns the wheel units to send, each within ±255.
    public mutating func feed(delta: Double, precise: Bool) -> [Int] {
        // A wheel line is one notch; a trackpad point ≈ 1/10 of a notch.
        pending += precise ? delta * 12 : delta * 120
        var out: [Int] = []
        while abs(pending) >= 1 {
            let step = Int(max(-255, min(255, pending.rounded(.towardZero))))
            if step == 0 { break }
            out.append(step)
            pending -= Double(step)
            if out.count >= 16 { pending = 0; break }   // a fling: don't flood
        }
        return out
    }

    public mutating func reset() { pending = 0 }
}

// MARK: - Errors

/// Human wording for why an RDP session ended. FreeRDP reports symbolic names
/// (`ERRCONNECT_*` for connection failures, `ERRINFO_*` for server-side
/// disconnect reasons); the shim passes both through.
public enum RDPErrorText {
    public struct Message: Equatable, Sendable {
        public let zh: String
        public let en: String
        /// The user may want to fix credentials (offer to re-enter the password).
        public let isAuthFailure: Bool
    }

    /// nil when the session ended normally (we closed it, or it was cancelled).
    public static func message(errorName: String, errinfoName: String) -> Message? {
        if let m = errinfo[errinfoName] { return m }
        if let m = connect[errorName] { return m }
        if errorName.isEmpty || errorName == "ERRCONNECT_SUCCESS" || errorName == "ERRCONNECT_CONNECT_CANCELLED"
            || errorName.hasSuffix("SUCCESS") {
            return nil
        }
        return Message(zh: "连接中断（\(errorName)）", en: "Connection ended (\(errorName))", isAuthFailure: false)
    }

    private static func m(_ zh: String, _ en: String, auth: Bool = false) -> Message {
        Message(zh: zh, en: en, isAuthFailure: auth)
    }

    private static let connect: [String: Message] = [
        "ERRCONNECT_DNS_ERROR": m("找不到主机（DNS 解析失败）", "Host not found (DNS lookup failed)"),
        "ERRCONNECT_DNS_NAME_NOT_FOUND": m("找不到主机（DNS 解析失败）", "Host not found (DNS lookup failed)"),
        "ERRCONNECT_CONNECT_FAILED": m("无法连接：端口没有响应或被拒绝", "Couldn't connect: the port refused or didn't answer"),
        "ERRCONNECT_CONNECT_TRANSPORT_FAILED": m("网络连接中断", "The network connection dropped"),
        "ERRCONNECT_TLS_CONNECT_FAILED": m("TLS 握手失败（证书被拒绝或协议不兼容）", "TLS handshake failed (certificate rejected or incompatible)"),
        "ERRCONNECT_SECURITY_NEGO_CONNECT_FAILED": m("安全协商失败：服务器要求的认证方式不受支持", "Security negotiation failed: the server wants an unsupported method"),
        "ERRCONNECT_AUTHENTICATION_FAILED": m("认证失败：用户名或密码错误", "Authentication failed: wrong user name or password", auth: true),
        "ERRCONNECT_LOGON_FAILURE": m("登录失败：用户名或密码错误", "Logon failed: wrong user name or password", auth: true),
        "ERRCONNECT_WRONG_PASSWORD": m("密码错误", "Wrong password", auth: true),
        "ERRCONNECT_NO_OR_MISSING_CREDENTIALS": m("缺少用户名或密码", "User name or password missing", auth: true),
        "ERRCONNECT_ACCESS_DENIED": m("拒绝访问：该账户无权远程登录", "Access denied: this account may not log on remotely"),
        "ERRCONNECT_INSUFFICIENT_PRIVILEGES": m("权限不足：该账户无权远程登录", "Insufficient privileges for remote logon"),
        "ERRCONNECT_ACCOUNT_DISABLED": m("账户已被禁用", "The account is disabled"),
        "ERRCONNECT_ACCOUNT_LOCKED_OUT": m("账户已被锁定", "The account is locked out"),
        "ERRCONNECT_ACCOUNT_EXPIRED": m("账户已过期", "The account has expired"),
        "ERRCONNECT_ACCOUNT_RESTRICTION": m("账户受限，不允许此次登录", "An account restriction prevents this logon"),
        "ERRCONNECT_PASSWORD_EXPIRED": m("密码已过期，请先在 Windows 上修改", "The password has expired — change it on Windows first"),
        "ERRCONNECT_PASSWORD_CERTAINLY_EXPIRED": m("密码已过期，请先在 Windows 上修改", "The password has expired — change it on Windows first"),
        "ERRCONNECT_PASSWORD_MUST_CHANGE": m("必须先修改密码才能登录", "The password must be changed before logging on"),
        "ERRCONNECT_LOGON_TYPE_NOT_GRANTED": m("该账户未被授予远程桌面登录权限", "This account isn't allowed to log on through Remote Desktop"),
        "ERRCONNECT_CONNECT_KDC_UNREACHABLE": m("无法联系域控制器（Kerberos）", "Can't reach the domain controller (Kerberos)"),
        "ERRCONNECT_HYBRID_REQUIRED_BY_SERVER": m("服务器要求网络级身份验证（NLA）", "The server requires Network Level Authentication"),
        "ERRCONNECT_SERVER_DENIED_CONNECTION": m("服务器拒绝了连接", "The server denied the connection"),
        "ERRCONNECT_CONNECT_TARGET_BOOTING": m("目标主机正在启动，请稍后重试", "The target is still booting — try again shortly"),
        "ERRCONNECT_ACTIVATION_TIMEOUT": m("会话激活超时", "Session activation timed out"),
        "ERRCONNECT_MCS_CONNECT_INITIAL_ERROR": m("服务器拒绝了会话（MCS）", "The server rejected the session (MCS)"),
        "ERRCONNECT_PRE_CONNECT_FAILED": m("连接前准备失败", "Connection setup failed"),
        "ERRCONNECT_POST_CONNECT_FAILED": m("连接后初始化失败", "Session setup failed after connecting"),
    ]

    private static let errinfo: [String: Message] = [
        "ERRINFO_RPC_INITIATED_DISCONNECT": m("管理员断开了此会话", "An administrator disconnected the session"),
        "ERRINFO_RPC_INITIATED_LOGOFF": m("管理员注销了此会话", "An administrator logged the session off"),
        "ERRINFO_IDLE_TIMEOUT": m("空闲超时，服务器断开了会话", "Idle timeout: the server ended the session"),
        "ERRINFO_LOGON_TIMEOUT": m("会话时长达到上限", "The session time limit was reached"),
        "ERRINFO_DISCONNECTED_BY_OTHER_CONNECTION": m("另一处登录了同一账户，此会话被接管", "Another connection took over this session"),
        "ERRINFO_OUT_OF_MEMORY": m("服务器内存不足", "The server ran out of memory"),
        "ERRINFO_SERVER_DENIED_CONNECTION": m("服务器拒绝了连接", "The server denied the connection"),
        "ERRINFO_SERVER_INSUFFICIENT_PRIVILEGES": m("该账户无权远程登录", "This account may not log on remotely"),
        "ERRINFO_SERVER_FRESH_CREDENTIALS_REQUIRED": m("服务器要求重新输入凭据", "The server requires fresh credentials", auth: true),
        "ERRINFO_RPC_INITIATED_DISCONNECT_BY_USER": m("会话已在 Windows 上断开", "The session was disconnected from Windows"),
        "ERRINFO_LOGOFF_BY_USER": m("已从 Windows 注销", "Logged off from Windows"),
        "ERRINFO_LICENSE_NO_LICENSE_SERVER": m("远程桌面授权服务器不可用", "No Remote Desktop license server is available"),
        "ERRINFO_LICENSE_NO_LICENSE": m("没有可用的远程桌面授权", "No Remote Desktop license is available"),
        "ERRINFO_LICENSE_NO_REMOTE_CONNECTIONS": m("服务器不接受更多远程连接（授权限制）", "The server accepts no more remote connections (licensing)"),
        "ERRINFO_SERVER_DWM_CRASH": m("服务器的桌面窗口管理器崩溃", "The server's Desktop Window Manager crashed"),
        "ERRINFO_SERVER_WINLOGON_CRASH": m("服务器的登录进程崩溃", "The server's logon process crashed"),
    ]
}

// MARK: - Certificates (trust on first use)

/// A server certificate as shown to the user.
public struct RDPCertificateInfo: Equatable, Sendable {
    /// SHA-256 over the DER, `AA:BB:…`.
    public let fingerprint: String
    public let subject: String
    public let issuer: String

    public init(fingerprint: String, subject: String, issuer: String) {
        self.fingerprint = fingerprint; self.subject = subject; self.issuer = issuer
    }

    /// DER bytes from what FreeRDP hands over (PEM text, or raw DER).
    public static func der(from data: Data) -> Data? {
        guard let text = String(data: data, encoding: .utf8), text.contains("-----BEGIN CERTIFICATE-----") else {
            return data.first == 0x30 ? data : nil
        }
        // The first certificate in the chain is the server's.
        guard let begin = text.range(of: "-----BEGIN CERTIFICATE-----"),
              let end = text.range(of: "-----END CERTIFICATE-----", range: begin.upperBound..<text.endIndex) else { return nil }
        let b64 = text[begin.upperBound..<end.lowerBound].filter { !$0.isWhitespace }
        return Data(base64Encoded: String(b64))
    }

    public static func fingerprint(der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}

/// Wireline's own known-hosts for RDP, keyed by the *real* target `host:port`
/// (never the 127.0.0.1 end of an SSH tunnel), like `~/.ssh/known_hosts`.
public final class RDPKnownHosts: @unchecked Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var fingerprint: String
        public var subject: String
        public var trustedAt: Date
    }

    public enum Verdict: Equatable, Sendable {
        case trusted                 // matches the stored fingerprint
        case unknown                 // first contact: ask
        case changed(old: Entry)     // differs from what we trusted: warn loudly
    }

    public let url: URL
    private let lock = NSLock()
    private var entries: [String: Entry]

    public init(url: URL) {
        self.url = url
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let data = try? Data(contentsOf: url)
        entries = data.flatMap { try? dec.decode([String: Entry].self, from: $0) } ?? [:]
    }

    public static func key(host: String, port: Int) -> String { "\(host.lowercased()):\(port)" }

    public func verdict(host: String, port: Int, fingerprint: String) -> Verdict {
        lock.lock(); defer { lock.unlock() }
        guard let e = entries[Self.key(host: host, port: port)] else { return .unknown }
        return e.fingerprint == fingerprint ? .trusted : .changed(old: e)
    }

    public func trust(host: String, port: Int, info: RDPCertificateInfo, at date: Date = Date()) {
        lock.lock()
        entries[Self.key(host: host, port: port)] = Entry(fingerprint: info.fingerprint, subject: info.subject, trustedAt: date)
        let snapshot = entries
        lock.unlock()
        save(snapshot)
    }

    public func forget(host: String, port: Int) {
        lock.lock()
        entries[Self.key(host: host, port: port)] = nil
        let snapshot = entries
        lock.unlock()
        save(snapshot)
    }

    private func save(_ snapshot: [String: Entry]) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
