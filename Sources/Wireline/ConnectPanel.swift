import SwiftUI
import Observation
import WirelineCore

// MARK: - Progress model

/// Follows one ssh connection attempt for the connect panel. ssh runs with
/// `-v -E <file>`, so its debug log goes to a file instead of the terminal;
/// this tails that file, feeds `SSHConnectParser`, and decides what the panel
/// shows: nothing (local shells, an instant reuse of a ControlMaster), the
/// progress card, a compact capsule while the terminal needs the user (a
/// passphrase / OTP / host key prompt), or the failure card.
@Observable
@MainActor
final class ConnectProgress {
    enum Phase: Equatable {
        /// No panel.
        case idle
        /// Dialing, but not yet long enough to show anything (a split riding
        /// an existing connection is up well within this).
        case pending
        case active
        case failed
    }

    struct Row: Identifiable, Equatable {
        let id: Int
        let elapsed: TimeInterval
        let entry: SSHConnectParser.Entry
    }

    private(set) var phase: Phase = .idle
    private(set) var parser = SSHConnectParser()
    private(set) var rows: [Row] = []
    private(set) var startedAt = Date()
    /// When the attempt ended in failure (freezes the timer).
    private(set) var endedAt: Date?
    /// The terminal is asking the user something: shrink to a capsule.
    private(set) var needsInput = false
    var logsExpanded = false

    var isPanelVisible: Bool { phase == .active || phase == .failed }
    var isShowingFailure: Bool { phase == .failed }

    /// Lines ssh would have printed to the terminal without `-E` (warnings,
    /// errors): the session echoes them so the scrollback still has them.
    @ObservationIgnored var onUserFacingLine: ((String) -> Void)?

    /// How long a connection may take before the panel appears.
    private static let showDelay: TimeInterval = 0.15
    /// How long the finished track stays up before the panel fades.
    private static let successHold: TimeInterval = 0.35

    @ObservationIgnored private var logPath: String?
    @ObservationIgnored private var fd: Int32 = -1
    @ObservationIgnored private var source: DispatchSourceFileSystemObject?
    @ObservationIgnored private var offset: off_t = 0
    @ObservationIgnored private var partial = Data()
    @ObservationIgnored private var generation = 0

    /// Start following a new attempt. Returns the path to pass as `ssh -E`, or
    /// nil if the log file couldn't be set up (ssh then runs as before).
    /// A panel already up (重试 on a failure) stays up for the new attempt.
    func begin() -> String? {
        let keepShowing = isPanelVisible
        generation += 1
        closeLog()
        let path = NSTemporaryDirectory() + "wl-ssh-\(UUID().uuidString.prefix(8)).log"
        guard FileManager.default.createFile(atPath: path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else { phase = .idle; return nil }
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else {
            try? FileManager.default.removeItem(atPath: path)
            phase = .idle
            return nil
        }
        logPath = path
        self.fd = fd
        offset = 0
        partial = Data()
        parser = SSHConnectParser()
        rows = []
        startedAt = Date()
        endedAt = nil
        wlAnimate(Motion.state) {
            needsInput = false
            logsExpanded = false
            phase = keepShowing ? .active : .pending
        }

        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend],
                                                            queue: .main)
        src.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.drain() } }
        src.resume()
        source = src

        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.showDelay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == gen, self.phase == .pending else { return }
                self.drain()
                guard self.phase == .pending, self.parser.isRunning else { return }
                wlAnimate(Motion.popIn) { self.phase = .active }
            }
        }
        return path
    }

    /// Terminal output arrived. Before the session is up that's ssh (or a
    /// ProxyJump hop) asking for something — make room for the prompt.
    func noteOutput() {
        guard source != nil else { return }
        drain()
        guard parser.isRunning else { return }
        if let entry = parser.sessionOutputSeen() {
            append([entry])
            succeeded()
        } else if parser.lineCount == 0 {
            // No log at all (an option in the user's args silenced it): we
            // can't follow this connection, so get out of the way.
            stop()
        } else if !needsInput {
            wlAnimate(Motion.disclose) { needsInput = true }
        }
    }

    /// ssh exited. Before a session that's a failure at the current step.
    func processExited() {
        guard logPath != nil else { return }
        let wasRunning = parser.isRunning
        drain(mirrorAfterSession: true)
        if wasRunning, parser.isRunning, let entry = parser.processExited() {
            append([entry])
            failed()
        }
        closeLog()
        if phase == .pending { phase = .idle }
    }

    /// Hide the panel (the failure card's 关闭); the disconnected banner takes over.
    func dismiss() {
        wlAnimate(Motion.popOut) { phase = .idle }
    }

    /// Stop following and remove the log (terminate, reconnect, cancel).
    func stop() {
        generation += 1
        closeLog()
        if phase != .idle { wlAnimate(Motion.popOut) { phase = .idle } }
        needsInput = false
    }

    // MARK: Tail

    private func drain(mirrorAfterSession: Bool = false) {
        guard fd >= 0 else { return }
        var buf = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let n = pread(fd, &buf, buf.count, offset)
            guard n > 0 else { break }
            offset += off_t(n)
            partial.append(contentsOf: buf[0..<n])
        }
        while let nl = partial.firstIndex(of: 0x0A) {
            // Fatal messages end in "\r\n".
            let line = String(decoding: partial[partial.startIndex..<nl], as: UTF8.self)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            partial.removeSubrange(partial.startIndex...nl)
            handle(line, mirrorAfterSession: mirrorAfterSession)
        }
    }

    private func handle(_ line: String, mirrorAfterSession: Bool) {
        let running = parser.isRunning
        if (running || mirrorAfterSession), SSHConnectParser.isUserFacing(line) {
            onUserFacingLine?(line)
        }
        guard running else { return }
        append(parser.feed(line))
        switch parser.status {
        case .established: succeeded()
        case .failed: failed()
        case .running: break
        }
    }

    private func append(_ entries: [SSHConnectParser.Entry]) {
        guard !entries.isEmpty else { return }
        let t = Date().timeIntervalSince(startedAt)
        for e in entries { rows.append(Row(id: rows.count, elapsed: t, entry: e)) }
    }

    /// The session is up: stop watching the log (the ControlMaster keeps
    /// writing to it) and fade the panel once the last step has filled.
    private func succeeded() {
        source?.cancel(); source = nil
        needsInput = false
        guard phase == .active else { phase = .idle; return }
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.successHold) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == gen, self.phase == .active else { return }
                wlAnimate(Motion.popOut) { self.phase = .idle }
            }
        }
    }

    private func failed() {
        source?.cancel(); source = nil
        endedAt = Date()
        wlAnimate(Motion.popIn) {
            needsInput = false
            logsExpanded = true
            phase = .failed
        }
    }

    private func closeLog() {
        source?.cancel(); source = nil
        if fd >= 0 { close(fd); fd = -1 }
        if let logPath { try? FileManager.default.removeItem(atPath: logPath) }
        logPath = nil
    }
}

// MARK: - Overlay

/// The connect panel over a dialing terminal pane: a centred card, or a
/// capsule at the top while the terminal needs the user's input.
struct ConnectPanelOverlay: View {
    let session: TerminalSession

    var body: some View {
        let progress = session.connect
        ZStack {
            if progress.isPanelVisible {
                if progress.needsInput {
                    ConnectCapsule(session: session)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .transition(.wlSlide(.top))
                } else {
                    ConnectCard(session: session)
                        .padding(16)
                        .transition(.wlPop(anchor: .center))
                }
            }
        }
        .animation(Motion.resolved(Motion.disclose), value: progress.needsInput)
    }
}

// MARK: - Card

private struct ConnectCard: View {
    @Environment(HostStore.self) private var store
    @Environment(Localizer.self) private var loc
    let session: TerminalSession

    private var progress: ConnectProgress { session.connect }
    private var failure: (SSHConnectStage, SSHConnectFailure)? {
        if case let .failed(s, f) = progress.parser.status { return (s, f) }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            ConnectStepTrack(status: progress.parser.status)
            statusLine
            logs
            buttons
        }
        .padding(16)
        .frame(maxWidth: 400)
        .wlFloating(RoundedRectangle(cornerRadius: WL.radius(14), style: .continuous),
                    fill: WL.bg.opacity(0.97), shadow: 0.28, radius: 18, y: 6)
        .wlOccludesTerminal()
        .animation(Motion.resolved(Motion.state), value: progress.parser.status)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(failure == nil ? WL.green : WL.red)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: WL.radius(9), style: .continuous)
                    .fill((failure == nil ? WL.green : WL.red).opacity(0.12)))
            VStack(alignment: .leading, spacing: 3) {
                Text(failure == nil ? session.alias : loc("连接失败", "Connection failed"))
                    .font(WL.mono(14, .semibold))
                    .foregroundStyle(failure == nil ? WL.textPrimary : WL.red)
                    .lineLimit(1).truncationMode(.middle)
                Text(subtitle).font(WL.caption).foregroundStyle(WL.textDim)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
    }

    private var subtitle: String {
        let host = store.hosts.first { $0.alias == session.alias }
        let target = host.map { "\($0.user ?? "root")@\($0.connectHostname)" } ?? session.alias
        return failure == nil ? "SSH · \(target)" : "\(session.alias) · SSH · \(target)"
    }

    private var statusLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let (stage, f) = failure {
                Text(ConnectText.reason(f, stage: stage, loc: loc))
                    .font(WL.small).foregroundStyle(WL.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(ConnectText.status(progress.parser, loc: loc))
                    .font(WL.small).foregroundStyle(WL.textPrimary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            ConnectElapsed(progress: progress).font(WL.small).foregroundStyle(WL.textDim)
        }
    }

    private var logs: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                wlAnimate(Motion.disclose) { progress.logsExpanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Text(loc("日志", "Logs")).font(WL.caption)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(progress.logsExpanded ? 0 : -90))
                }
                .foregroundStyle(WL.textDim)
            }
            .buttonStyle(.wlPlain)
            if progress.logsExpanded {
                ConnectLogList(rows: progress.rows)
                    .transition(.wlDisclose)
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            Spacer()
            if failure != nil {
                Button(loc("关闭", "Close")) { progress.dismiss() }
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

// MARK: - Capsule (terminal needs input)

private struct ConnectCapsule: View {
    @Environment(Localizer.self) private var loc
    let session: TerminalSession

    var body: some View {
        let progress = session.connect
        HStack(spacing: 10) {
            Circle().fill(WL.amber).frame(width: 6, height: 6).wlPulse(period: 0.7)
            Text("\(session.alias) · \(ConnectText.status(progress.parser, loc: loc))")
                .font(WL.small).foregroundStyle(WL.textPrimary).lineLimit(1)
            ConnectElapsed(progress: progress).font(WL.small).foregroundStyle(WL.textDim)
            Button(action: session.cancelConnect) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.wlIcon(size: 20))
            .help(loc("取消连接", "Cancel connecting"))
        }
        .padding(.leading, 14).padding(.trailing, 6).padding(.vertical, 5)
        .wlFloating(Capsule(style: .continuous), fill: WL.bg.opacity(0.96), shadow: 0.25, radius: 12, y: 4)
        .wlOccludesTerminal()
        .padding(.top, 10)
    }
}

// MARK: - Pieces

/// Live seconds since the attempt began; frozen once it failed.
private struct ConnectElapsed: View {
    let progress: ConnectProgress

    var body: some View {
        if let end = progress.endedAt {
            label(end.timeIntervalSince(progress.startedAt))
        } else {
            TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
                label(ctx.date.timeIntervalSince(progress.startedAt))
            }
        }
    }

    private func label(_ t: TimeInterval) -> some View {
        Text(String(format: "%.1fs", max(0, t))).monospacedDigit()
    }
}

/// 解析 → 连接 → 认证 → 会话: done steps filled, the current one glowing with
/// a dotted segment marching toward the next, pending ones hollow; on failure
/// the track up to the failed step turns red.
private struct ConnectStepTrack: View {
    @Environment(Localizer.self) private var loc
    let status: SSHConnectParser.Status

    private enum StepState { case done, current, pending, failedDone, failed }

    private func state(_ s: SSHConnectStage) -> StepState {
        switch status {
        case .established: return .done
        case .running(let cur): return s < cur ? .done : s == cur ? .current : .pending
        case .failed(let at, _): return s < at ? .failedDone : s == at ? .failed : .pending
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(SSHConnectStage.allCases, id: \.self) { s in
                VStack(spacing: 6) {
                    dot(state(s))
                    Text(ConnectText.step(s, loc: loc))
                        .font(WL.caption)
                        .foregroundStyle(labelColor(state(s)))
                }
                .frame(width: 44)
                if s != .session {
                    connector(after: s)
                        .frame(height: 2)
                        .padding(.top, 8)       // centre on the 18pt dots
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
            let tint = st == .done ? WL.green : WL.red
            Circle().fill(tint).frame(width: size, height: size)
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

    /// The segment between `s` and the next step.
    @ViewBuilder private func connector(after s: SSHConnectStage) -> some View {
        let next = SSHConnectStage(rawValue: s.rawValue + 1)!
        switch (state(s), state(next)) {
        case (.done, _): Capsule().fill(WL.green)
        case (.failedDone, _): Capsule().fill(WL.red)
        case (.current, _): MarchingDots(color: WL.green)
        default: Capsule().fill(WL.track)
        }
    }
}

/// A dotted segment whose dots march along it — "in progress, heading there".
/// Static under Reduce Motion.
struct MarchingDots: View {
    let color: Color
    private let period: Double = 1.2

    var body: some View {
        if Motion.reduce {
            line(phase: 0)
        } else {
            TimelineView(.animation) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
                line(phase: -CGFloat(t) * 6)
            }
        }
    }

    private func line(phase: CGFloat) -> some View {
        GeometryReader { g in
            Path { p in
                p.move(to: CGPoint(x: 0, y: g.size.height / 2))
                p.addLine(to: CGPoint(x: g.size.width, y: g.size.height / 2))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [0.1, 6], dashPhase: phase))
        }
    }
}

private struct ConnectLogList: View {
    let rows: [ConnectProgress.Row]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(rows) { row in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(String(format: "%.2fs", row.elapsed))
                                .foregroundStyle(WL.textDim)
                                .frame(width: 46, alignment: .trailing)
                            Text(row.entry.stage.tag)
                                .foregroundStyle(row.entry.isError ? WL.red : WL.textDim)
                                .frame(width: 52, alignment: .leading)
                            Text(row.entry.text)
                                .foregroundStyle(row.entry.isError ? WL.red : WL.textPrimary.opacity(0.85))
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                            Spacer(minLength: 0)
                        }
                        .font(WL.mono(10))
                        .id(row.id)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
            }
            .frame(maxHeight: 150)
            .fixedSize(horizontal: false, vertical: true)
            .background(WL.fieldFill, in: RoundedRectangle(cornerRadius: WL.radius(10), style: .continuous))
            .onChange(of: rows.count) { _, _ in
                if let last = rows.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }
}

// MARK: - Wording

@MainActor
private enum ConnectText {
    static func step(_ s: SSHConnectStage, loc: Localizer) -> String {
        switch s {
        case .resolve: loc("解析", "Resolve")
        case .connect: loc("连接", "Connect")
        case .auth: loc("认证", "Auth")
        case .session: loc("会话", "Session")
        }
    }

    static func status(_ p: SSHConnectParser, loc: Localizer) -> String {
        switch p.currentStage ?? .session {
        case .resolve: return loc("正在解析地址…", "Resolving…")
        case .connect: return loc("正在连接…", "Connecting…")
        case .auth:
            let base = loc("正在认证…", "Authenticating…")
            return p.authMethod.map { "\(base) \($0)" } ?? base
        case .session: return loc("正在打开会话…", "Opening session…")
        }
    }

    static func reason(_ f: SSHConnectFailure, stage: SSHConnectStage, loc: Localizer) -> String {
        switch f {
        case .unresolvable:
            return loc("无法解析主机名，请检查地址或 DNS。", "Couldn't resolve the host name. Check the address or DNS.")
        case .refused:
            return loc("服务器拒绝了连接，该端口上可能没有运行 SSH。",
                       "The server refused the connection. SSH may not be running on that port.")
        case .timedOut:
            return loc("连接超时：主机没有响应，可能已离线或被防火墙拦截。",
                       "Timed out: the host didn't answer. It may be offline or behind a firewall.")
        case .unreachable:
            return loc("网络不可达，无法路由到该主机。", "Network unreachable: there's no route to the host.")
        case .hostKeyChanged:
            return loc("服务器的主机密钥变了，为安全起见已中止。确认是正常更换后，从 known_hosts 删除旧记录再重试。",
                       "The server's host key has changed, so the connection was stopped. If that's expected, remove the old entry from known_hosts and retry.")
        case .hostKeyFailed:
            return loc("无法验证服务器的主机密钥。", "Couldn't verify the server's host key.")
        case .negotiation:
            return loc("与服务器没有共同支持的加密算法。", "No encryption algorithm in common with the server.")
        case .closed:
            return stage == .auth
                ? loc("服务器在认证过程中断开了连接。", "The server closed the connection during authentication.")
                : loc("服务器在握手阶段断开了连接。", "The server closed the connection during the handshake.")
        case .permissionDenied(let methods):
            return loc("认证失败：服务器拒绝了所有登录方式（\(methods)）。",
                       "Authentication failed: the server rejected every method (\(methods)).")
        case .tooManyAuthFailures:
            return loc("尝试的密钥过多，服务器已断开。可在主机设置里指定要用的密钥。",
                       "Too many keys were tried and the server hung up. Pick a specific key for this host.")
        case .exited(let message):
            return message ?? loc("ssh 在建立会话前退出了。", "ssh exited before the session started.")
        }
    }
}
