import SwiftUI
import AppKit
import WirelineCore

// MARK: - Hosting

/// Embeds an RDP session's `RDPView` (owned by its `RDPSession`, so the
/// connection survives SwiftUI re-embedding it) in a pane.
struct RDPHostView: NSViewRepresentable {
    let rdp: RDPSession
    /// As `TerminalHostView`: only the focused pane takes first responder.
    var autoFocus = true

    final class Coordinator { var didFocus = false }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> RDPContainerView {
        let container = RDPContainerView()
        container.host(rdp.view)
        if autoFocus {
            context.coordinator.didFocus = true
            DispatchQueue.main.async { [view = rdp.view] in view.window?.makeFirstResponder(view) }
        }
        return container
    }

    func updateNSView(_ container: RDPContainerView, context: Context) {
        // The newest host of a re-embedded view takes it over.
        if rdp.view.superview !== container { container.host(rdp.view) }
        if autoFocus, !context.coordinator.didFocus {
            context.coordinator.didFocus = true
            DispatchQueue.main.async { [view = rdp.view] in view.window?.makeFirstResponder(view) }
        } else if !autoFocus {
            context.coordinator.didFocus = false
        }
    }
}

/// Keeps the desktop view filling the pane. Unlike a terminal there's no
/// grid to freeze during a layout animation: the last frame stretches (the
/// compositor scales the surface) and the remote resize waits until the
/// layout settles (`RDPSession.scheduleResize`).
final class RDPContainerView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        clipsToBounds = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func host(_ view: NSView) {
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = true
        view.autoresizingMask = [.width, .height]
        view.frame = bounds
        addSubview(view)
    }

    override func layout() {
        super.layout()
        for v in subviews where v.frame != bounds { v.frame = bounds }
    }
}

// MARK: - Pane content

/// A remote desktop in a pane or a single-session tab: the desktop, the
/// connect card / certificate / password questions over it, and the
/// disconnected banner once it's gone.
struct RDPPaneContent: View {
    let session: TerminalSession
    let rdp: RDPSession
    var autoFocus = true

    var body: some View {
        RDPHostView(rdp: rdp, autoFocus: autoFocus)
            .overlay(alignment: .top) {
                if session.connectionState == .disconnected, !rdp.isShowingFailure,
                   rdp.passwordPrompt == nil, rdp.certificatePrompt == nil {
                    DisconnectedBanner(session: session, detail: rdp.disconnectReason)
                }
            }
            .overlay { RDPConnectOverlay(session: session, rdp: rdp) }
            .animation(Motion.banner, value: session.connectionState)
    }
}

/// Whichever card the connection needs right now.
private struct RDPConnectOverlay: View {
    let session: TerminalSession
    let rdp: RDPSession

    var body: some View {
        ZStack {
            if let prompt = rdp.certificatePrompt {
                RDPCertificateCard(rdp: rdp, prompt: prompt)
                    .padding(16)
                    .transition(.wlPop(anchor: .center))
            } else if let prompt = rdp.passwordPrompt {
                RDPPasswordCard(rdp: rdp, prompt: prompt)
                    .padding(16)
                    .transition(.wlPop(anchor: .center))
            } else if rdp.showsPanel {
                RDPConnectCard(session: session, rdp: rdp)
                    .padding(16)
                    .transition(.wlPop(anchor: .center))
            }
        }
        .animation(Motion.resolved(Motion.disclose), value: rdp.certificatePrompt != nil)
        .animation(Motion.resolved(Motion.disclose), value: rdp.passwordPrompt != nil)
    }
}

// MARK: - Progress card

/// The SSH connect card's sibling: (隧道 →) 连接 → 安全 → 登录, the log, and
/// 取消 / 关闭 · 重试.
private struct RDPConnectCard: View {
    @Environment(Localizer.self) private var loc
    let session: TerminalSession
    let rdp: RDPSession

    private var failure: (RDPSession.Stage, String)? {
        if case let .failed(stage, message) = rdp.status { return (stage, message) }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            RDPCardHeader(rdp: rdp, title: failure == nil ? rdp.target.alias : loc("连接失败", "Connection failed"),
                          tint: failure == nil ? WL.green : WL.red)
            RDPStepTrack(rdp: rdp)
            statusLine
            logs
            buttons
        }
        .padding(16)
        .frame(maxWidth: 400)
        .wlFloating(RoundedRectangle(cornerRadius: WL.radius(14), style: .continuous),
                    fill: WL.bg.opacity(0.97), shadow: 0.28, radius: 18, y: 6)
        .animation(Motion.resolved(Motion.state), value: rdp.status)
    }

    private var statusLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let (_, message) = failure {
                Text(message).font(WL.small).foregroundStyle(WL.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(status).font(WL.small).foregroundStyle(WL.textPrimary).lineLimit(1)
            }
            Spacer(minLength: 8)
            RDPElapsed(rdp: rdp).font(WL.small).foregroundStyle(WL.textDim)
        }
    }

    private var status: String {
        guard case .running(let stage) = rdp.status else { return loc("桌面已就绪", "Desktop ready") }
        switch stage {
        case .tunnel: return loc("正在建立 SSH 隧道…", "Opening the SSH tunnel…")
        case .connect: return loc("正在连接…", "Connecting…")
        case .security: return loc("正在验证证书与身份…", "Checking certificate and identity…")
        case .session: return loc("正在打开桌面…", "Opening the desktop…")
        }
    }

    private var logs: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                wlAnimate(Motion.disclose) { rdp.logsExpanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Text(loc("日志", "Logs")).font(WL.caption)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(rdp.logsExpanded ? 0 : -90))
                }
                .foregroundStyle(WL.textDim)
            }
            .buttonStyle(.wlPlain)
            if rdp.logsExpanded {
                RDPLogList(rdp: rdp).transition(.wlDisclose)
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            Spacer()
            if failure != nil {
                Button(loc("关闭", "Close")) { rdp.dismissFailure() }
                    .buttonStyle(.wlSecondary)
                Button(loc("重试", "Retry")) { session.reconnect() }
                    .buttonStyle(.wlPrimary)
            } else {
                Button(loc("取消", "Cancel")) { session.cancelConnect() }
                    .buttonStyle(.wlSecondary)
            }
        }
    }
}

/// Icon tile, title, and "RDP · user@host:port (via jump)".
private struct RDPCardHeader: View {
    @Environment(Localizer.self) private var loc
    let rdp: RDPSession
    let title: String
    let tint: Color
    var symbol = "squareshape.split.2x2"

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: WL.radius(9), style: .continuous).fill(tint.opacity(0.12)))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(WL.mono(14, .semibold))
                    .foregroundStyle(tint == WL.red ? WL.red : WL.textPrimary)
                    .lineLimit(1).truncationMode(.middle)
                Text(subtitle).font(WL.caption).foregroundStyle(WL.textDim)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
    }

    private var subtitle: String {
        let t = rdp.target
        var s = "RDP · \(t.username.map { "\($0)@" } ?? "")\(t.hostname)"
        if t.port != 3389 { s += ":\(t.port)" }
        if let via = t.via { s += loc(" · 经 \(via)", " · via \(via)") }
        return s
    }
}

/// Live seconds since the attempt began; frozen once it ended.
private struct RDPElapsed: View {
    let rdp: RDPSession

    var body: some View {
        if let end = rdp.endedAt {
            label(end.timeIntervalSince(rdp.startedAt))
        } else {
            TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
                label(ctx.date.timeIntervalSince(rdp.startedAt))
            }
        }
    }

    private func label(_ t: TimeInterval) -> some View {
        Text(String(format: "%.1fs", max(0, t))).monospacedDigit()
    }
}

/// The steps as dots, like `ConnectStepTrack`: done filled, the current one
/// glowing with marching dots toward the next, the failed one red.
private struct RDPStepTrack: View {
    @Environment(Localizer.self) private var loc
    let rdp: RDPSession

    private enum StepState { case done, current, pending, failedDone, failed }

    private var steps: [RDPSession.Stage] {
        rdp.target.via != nil ? RDPSession.Stage.allCases : RDPSession.Stage.allCases.filter { $0 != .tunnel }
    }

    private func state(_ s: RDPSession.Stage) -> StepState {
        switch rdp.status {
        case .established, .closed: return .done
        case .idle: return .pending
        case .running(let cur): return s < cur ? .done : s == cur ? .current : .pending
        case .failed(let at, _): return s < at ? .failedDone : s == at ? .failed : .pending
        }
    }

    private func label(_ s: RDPSession.Stage) -> String {
        switch s {
        case .tunnel: loc("隧道", "Tunnel")
        case .connect: loc("连接", "Connect")
        case .security: loc("安全", "Security")
        case .session: loc("登录", "Logon")
        }
    }

    var body: some View {
        let steps = steps
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.element) { i, s in
                VStack(spacing: 6) {
                    dot(state(s))
                    Text(label(s)).font(WL.caption).foregroundStyle(labelColor(state(s)))
                }
                .frame(width: 44)
                if i < steps.count - 1 {
                    connector(state(s))
                        .frame(height: 2)
                        .padding(.top, 8)
                        .padding(.horizontal, -8)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func labelColor(_ st: StepState) -> Color {
        switch st {
        case .done, .current: WL.textPrimary
        case .pending: WL.textDim
        case .failed, .failedDone: WL.red
        }
    }

    @ViewBuilder private func dot(_ st: StepState) -> some View {
        let size: CGFloat = 18
        switch st {
        case .done, .failedDone:
            Circle().fill(st == .done ? WL.green : WL.red).frame(width: size, height: size)
                .overlay(Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(WL.bg))
        case .current:
            Circle().fill(WL.green.opacity(0.16)).frame(width: size, height: size)
                .overlay(Circle().strokeBorder(WL.green, lineWidth: 2))
                .overlay(Circle().fill(WL.green).frame(width: 6, height: 6))
                .shadow(color: WL.green.opacity(0.55), radius: 5)
                .wlPulse(period: 0.9, low: 0.55)
        case .failed:
            Circle().fill(WL.red).frame(width: size, height: size)
                .overlay(Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(WL.bg))
                .shadow(color: WL.red.opacity(0.45), radius: 5)
        case .pending:
            Circle().strokeBorder(WL.textDim.opacity(0.45), lineWidth: 1.5).frame(width: size, height: size)
        }
    }

    @ViewBuilder private func connector(_ st: StepState) -> some View {
        switch st {
        case .done: Capsule().fill(WL.green)
        case .failedDone: Capsule().fill(WL.red)
        case .current: MarchingDots(color: WL.green)
        default: Capsule().fill(WL.track)
        }
    }
}

private struct RDPLogList: View {
    let rdp: RDPSession

    var body: some View {
        let rows = Array(rdp.log.enumerated())
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(rows, id: \.offset) { i, row in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(String(format: "%.2fs", row.t))
                                .foregroundStyle(WL.textDim)
                                .frame(width: 46, alignment: .trailing)
                            Text(row.text)
                                .foregroundStyle(WL.textPrimary.opacity(0.85))
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                            Spacer(minLength: 0)
                        }
                        .font(WL.mono(10))
                        .id(i)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
            }
            .frame(maxHeight: 150)
            .fixedSize(horizontal: false, vertical: true)
            .background(WL.fieldFill, in: RoundedRectangle(cornerRadius: WL.radius(10), style: .continuous))
            .onChange(of: rows.count) { _, n in proxy.scrollTo(n - 1, anchor: .bottom) }
        }
    }
}

// MARK: - Certificate

/// Trust on first use, like ssh's "authenticity of host … can't be
/// established" — and a loud warning when a trusted certificate changed.
private struct RDPCertificateCard: View {
    @Environment(Localizer.self) private var loc
    let rdp: RDPSession
    let prompt: RDPSession.CertificatePrompt

    private var changed: Bool { prompt.previous != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            RDPCardHeader(rdp: rdp,
                          title: changed ? loc("服务器证书已变更", "Server certificate changed")
                                         : loc("验证服务器证书", "Verify the server certificate"),
                          tint: changed ? WL.red : WL.amber,
                          symbol: changed ? "exclamationmark.shield" : "checkmark.shield")
            Text(changed
                 ? loc("\(prompt.host):\(prompt.port) 的证书与上次信任的不一致。可能是证书正常更新，也可能有人在冒充该主机。不确定时请拒绝并联系管理员。",
                       "The certificate of \(prompt.host):\(prompt.port) differs from the one you trusted. It may have been renewed — or someone may be impersonating the host. If unsure, reject it and ask the administrator.")
                 : loc("首次连接 \(prompt.host):\(prompt.port)。该证书不受系统信任（Windows 默认使用自签名证书）。核对指纹无误后再信任，之后只在证书变化时询问。",
                       "First connection to \(prompt.host):\(prompt.port). The certificate isn't trusted by the system (Windows uses a self-signed one by default). Check the fingerprint, then trust it; you'll only be asked again if it changes."))
                .font(WL.small).foregroundStyle(WL.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                field(loc("主题", "Subject"), prompt.info.subject)
                if !prompt.info.issuer.isEmpty { field(loc("颁发者", "Issuer"), prompt.info.issuer) }
                field("SHA-256", prompt.info.fingerprint, mono: true)
                if let old = prompt.previous {
                    field(loc("原指纹", "Was"), old.fingerprint, mono: true, dim: true)
                    field(loc("信任于", "Trusted"), old.trustedAt.formatted(date: .abbreviated, time: .shortened), dim: true)
                }
            }
            .padding(10)
            .background(WL.fieldFill, in: RoundedRectangle(cornerRadius: WL.radius(10), style: .continuous))
            HStack(spacing: 8) {
                Spacer()
                Button(loc("拒绝", "Reject")) { rdp.answerCertificate(trust: false) }
                    .buttonStyle(.wlSecondary)
                    .keyboardShortcut(.cancelAction)
                if changed {
                    Button(loc("信任新证书", "Trust the new one")) { rdp.answerCertificate(trust: true) }
                        .buttonStyle(.wlDestructive)
                } else {
                    Button(loc("信任并连接", "Trust and connect")) { rdp.answerCertificate(trust: true) }
                        .buttonStyle(.wlPrimary)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: 440)
        .wlFloating(RoundedRectangle(cornerRadius: WL.radius(14), style: .continuous),
                    fill: WL.bg.opacity(0.97), shadow: 0.28, radius: 18, y: 6)
    }

    private func field(_ key: String, _ value: String, mono: Bool = false, dim: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(key).font(WL.caption).foregroundStyle(WL.textDim).frame(width: 56, alignment: .leading)
            Text(value).font(mono ? WL.mono(10) : WL.small)
                .foregroundStyle(dim ? WL.textDim : WL.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}

// MARK: - Password

/// No (or a rejected) password: ask, optionally remember it in the Keychain.
private struct RDPPasswordCard: View {
    @Environment(Localizer.self) private var loc
    let rdp: RDPSession
    let prompt: RDPSession.PasswordPrompt
    @State private var username = ""
    @State private var domain = ""
    @State private var password = ""
    @State private var remember = true
    @FocusState private var passwordFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            RDPCardHeader(rdp: rdp,
                          title: prompt.retry ? loc("重新输入密码", "Enter the password again")
                                              : loc("需要登录", "Log on"),
                          tint: WL.amber, symbol: "key")
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    TextField(loc("用户名", "User name"), text: $username).wlField()
                    TextField(loc("域（可选）", "Domain (optional)"), text: $domain).wlField()
                        .frame(width: 130)
                }
                SecureField(loc("密码", "Password"), text: $password).wlField(focus: $passwordFocused)
                    .onSubmit(submit)
                Toggle(loc("在钥匙串中记住密码", "Remember in Keychain"), isOn: $remember)
                    .toggleStyle(.wlCheckbox)
                    .font(WL.small)
            }
            HStack(spacing: 8) {
                Spacer()
                Button(loc("取消", "Cancel")) { rdp.cancelPassword() }
                    .buttonStyle(.wlSecondary)
                    .keyboardShortcut(.cancelAction)
                Button(loc("连接", "Connect"), action: submit)
                    .buttonStyle(.wlPrimary)
                    .disabled(username.isEmpty || password.isEmpty)
            }
        }
        .padding(16)
        .frame(maxWidth: 400)
        .wlFloating(RoundedRectangle(cornerRadius: WL.radius(14), style: .continuous),
                    fill: WL.bg.opacity(0.97), shadow: 0.28, radius: 18, y: 6)
        .onAppear {
            username = prompt.username
            domain = prompt.domain
            DispatchQueue.main.async { passwordFocused = true }
        }
    }

    private func submit() {
        guard !username.isEmpty, !password.isEmpty else { return }
        rdp.answerPassword(username: username, password: password, domain: domain, remember: remember)
    }
}
