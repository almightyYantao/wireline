import AppKit
import Observation
import WirelineCore

/// An answer from the island's buttons to a pending AI confirmation.
enum IslandDecision: Equatable {
    case allow, allowAlways, deny
}

/// The island's two settings (Settings → General, and the config file's
/// `notch-island` / `notch-island-always`).
@Observable
@MainActor
final class IslandSettings {
    static let shared = IslandSettings()

    /// Show the island at all.
    var enabled: Bool {
        didSet { d.set(enabled, forKey: "notchIsland"); IslandController.shared.refresh() }
    }
    /// Keep the collapsed island up even with nothing going on.
    var alwaysShow: Bool {
        didSet { d.set(alwaysShow, forKey: "notchIslandAlways"); IslandController.shared.refresh() }
    }

    @ObservationIgnored private let d = UserDefaults.standard

    private init() {
        enabled = d.object(forKey: "notchIsland") as? Bool ?? true
        alwaysShow = d.object(forKey: "notchIslandAlways") as? Bool ?? false
    }
}

/// Everything the notch island shows: AI turns and their confirmations, fleet
/// runs, the inline assistant, coding agents in panes, long commands. Sources
/// report here; `IslandBoard` (WirelineCore) decides what's shown when, and
/// `IslandController` draws it.
@Observable
@MainActor
final class IslandCenter {
    static let shared = IslandCenter()

    private(set) var board = IslandBoard()
    /// The pointer is over the island.
    var hovering = false {
        didSet { if hovering != oldValue { now = Date() } }
    }
    /// Advanced on every change and at every deadline, so `mode` re-evaluates.
    private(set) var now = Date()

    var mode: IslandMode {
        board.mode(at: now, hovering: hovering, alwaysShow: IslandSettings.shared.alwaysShow)
    }

    /// For jumping to a pane.
    @ObservationIgnored weak var sessions: SessionStore?
    /// What the Allow / Deny buttons of a row do.
    @ObservationIgnored private var decisions: [String: (IslandDecision) -> Void] = [:]
    @ObservationIgnored private var agents: [UUID: AgentWatch] = [:]
    @ObservationIgnored private var timer: DispatchWorkItem?

    private struct AgentWatch {
        var agent: CodingAgent
        var tracker: CodingAgentTracker
        /// Recognised from its title over SSH (no foreground process to poll).
        var remote: Bool
    }

    private init() {}

    private var loc: Localizer { Localizer.shared }

    // MARK: - Board edits

    func upsert(_ item: IslandItem) {
        now = Date()
        board.upsert(item, at: now)
        reschedule()
    }

    func finish(_ id: String, success: Bool, detail: String, pulse: String?) {
        now = Date()
        board.finish(id, success: success, detail: detail, pulse: pulse, at: now)
        decisions[id] = nil
        reschedule()
    }

    func remove(_ id: String) {
        now = Date()
        board.remove(id)
        decisions[id] = nil
        reschedule()
    }

    /// The fold-away button: stop forcing the card open.
    func dismissAttention() {
        now = Date()
        board.dismissAttention()
        reschedule()
    }

    func setDecision(_ id: String, _ handler: ((IslandDecision) -> Void)?) {
        decisions[id] = handler
    }

    /// An Allow / Deny tap. The handler resolves the same pending state the
    /// panel's dialog shows, so whichever answers first wins and the other
    /// goes away with it.
    func decide(_ id: String, _ decision: IslandDecision) {
        guard let handler = decisions[id] else { return }
        decisions[id] = nil
        handler(decision)
    }

    /// Bring Wireline forward on the row's pane.
    func jump(_ item: IslandItem) {
        NSApp.activate(ignoringOtherApps: true)
        if let sid = item.sessionID, let sessions, sessions.session(sid) != nil {
            sessions.focusSession(sid)
            DispatchQueue.main.async { sessions.focusActiveTerminal() }
        } else {
            NSApp.windows.first { $0.canBecomeMain && $0.level == .normal && $0.title == "Wireline" }?
                .makeKeyAndOrderFront(nil)
        }
        if !item.persistent, item.tone == .success || item.tone == .failure { remove(item.id) }
    }

    // MARK: - Timer

    /// Wake at the board's next deadline (pulse end, linger, attention peek)
    /// or an agent's quiet check, whichever comes first.
    private func reschedule() {
        timer?.cancel()
        var next = board.nextDeadline(after: now)
        for w in agents.values { if let t = w.tracker.nextTick { next = min(next ?? t, t) } }
        guard let next else { return }
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.fire() }
        }
        timer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.05, next.timeIntervalSinceNow), execute: item)
    }

    private func fire() {
        now = Date()
        for (id, var w) in agents {
            if let change = w.tracker.tick(at: now) {
                agents[id] = w
                publishAgent(id, change: change)
            } else {
                agents[id] = w
            }
        }
        board.prune(at: now)
        reschedule()
    }

    /// The user is looking at this pane right now.
    private func isViewing(_ sessionID: UUID?) -> Bool {
        guard NSApp.isActive, let sessionID, let sessions else { return false }
        return sessions.activeID == sessionID && sessions.activeTab?.leafID(for: sessionID) != nil
    }

    // MARK: - Wireline AI (panel chat / agent)

    func aiChanged(_ c: AIConvoState) {
        let id = "ai:" + c.key
        let title = c.islandTitle.isEmpty ? loc.t("AI 助手", "AI Assistant") : c.islandTitle
        if let question = Self.confirmation(of: c, loc) {
            upsert(IslandItem(id: id, source: .ai, title: title,
                              detail: loc.t("等你确认", "Needs your OK"), tone: .attention,
                              confirmation: question, sessionID: c.islandSessionID, at: Date()))
            setDecision(id) { [weak c] d in c?.decide(d) }
            return
        }
        setDecision(id, nil)
        if c.isStreaming {
            upsert(IslandItem(id: id, source: .ai, title: title,
                              detail: c.currentStep ?? loc.t("思考中…", "Thinking…"), tone: .working,
                              sessionID: c.islandSessionID, at: Date()))
        } else if let row = board.item(id), row.tone == .working || row.needsUser {
            let ran = Date().timeIntervalSince(row.startedAt)
            if row.needsUser {
                // Declined: the turn stops there.
                finish(id, success: true, detail: loc.t("已取消", "Cancelled"), pulse: nil)
            } else if let err = c.errorText, !err.isEmpty {
                finish(id, success: false, detail: err, pulse: "✕ " + loc.t("AI 出错", "AI error"))
            } else {
                finish(id, success: true, detail: loc.t("完成", "Done"),
                       pulse: ran >= 3 ? "✓ " + loc.t("完成", "Done") + " · " + islandDuration(ran) : nil)
            }
        }
    }

    private static func confirmation(of c: AIConvoState, _ loc: Localizer) -> IslandConfirmation? {
        if let cmd = c.pendingDanger {
            let review = c.dangerReview.trimmingCharacters(in: .whitespacesAndNewlines)
            return IslandConfirmation(kind: .dangerousCommand, subject: cmd, note: review.isEmpty ? nil : review)
        }
        if let p = c.pendingMCP {
            return IslandConfirmation(kind: .toolCall, subject: "\(p.server).\(p.tool)", canAlwaysAllow: true,
                                      note: p.argsJSON == "{}" ? nil : p.argsJSON)
        }
        if let t = c.pendingTransfer {
            return IslandConfirmation(kind: .fileTransfer, subject: t.summary(loc))
        }
        return nil
    }

    // MARK: - Fleet

    func fleetStarted(_ id: String, command: String, total: Int) {
        upsert(IslandItem(id: id, source: .fleet, title: loc.t("批量执行", "Fleet run"),
                          detail: command, tone: .working,
                          progress: IslandProgress(done: 0, total: total), at: Date()))
    }

    func fleetProgress(_ id: String, done: Int, failed: Int) {
        guard var row = board.item(id), row.tone == .working else { return }
        row.progress = IslandProgress(done: done, total: row.progress?.total ?? done, failed: failed)
        upsert(row)
    }

    func fleetFinished(_ id: String, total: Int, failed: Int) {
        guard let row = board.item(id) else { return }
        let ran = Date().timeIntervalSince(row.startedAt)
        if var r = board.item(id) { r.progress = IslandProgress(done: total, total: total, failed: failed); upsert(r) }
        let detail = failed == 0 ? loc.t("\(total) 台全部成功", "All \(total) hosts OK")
                                 : loc.t("\(failed)/\(total) 台失败", "\(failed)/\(total) hosts failed")
        finish(id, success: failed == 0, detail: detail,
               pulse: (failed == 0 ? "✓ " : "✕ ") + detail + " · " + islandDuration(ran))
    }

    // MARK: - Inline AI (⌘;)

    func inlineAIChanged(_ c: InlineAIController) {
        guard let s = c.session else { return }
        let id = "inline:\(s.id)"
        if c.thinking {
            upsert(IslandItem(id: id, source: .inlineAI, title: s.title,
                              detail: loc.t("生成命令…", "Writing a command…"), tone: .working,
                              sessionID: s.id, at: Date()))
        } else if let row = board.item(id), row.tone == .working {
            if let err = c.errorText {
                finish(id, success: false, detail: err, pulse: nil)
            } else if !c.active || isViewing(s.id) {
                remove(id)            // you're looking at the card (or it was cancelled)
            } else {
                finish(id, success: true, detail: loc.t("命令已就绪", "Command ready"),
                       pulse: "✓ " + loc.t("命令已就绪", "Command ready"))
            }
        }
    }

    // MARK: - Panes: coding agents and long commands

    /// A local pane's foreground program changed.
    func foregroundChanged(_ s: TerminalSession) {
        let agent = s.foregroundName.flatMap(CodingAgent.init(processName:))
        if let agent {
            guard agents[s.id]?.agent != agent || agents[s.id]?.remote == true else { return }
            agents[s.id] = AgentWatch(agent: agent, tracker: CodingAgentTracker(now: Date()), remote: false)
            publishAgent(s.id, change: nil)
        } else if let w = agents[s.id], !w.remote {
            agents[s.id] = nil
            remove("agent:\(s.id)")
        }
    }

    func sessionOutput(_ s: TerminalSession) {
        guard var w = agents[s.id] else { return }
        let change = w.tracker.output(at: Date())
        agents[s.id] = w
        if let change { publishAgent(s.id, change: change) }
    }

    func sessionInput(_ s: TerminalSession) {
        guard var w = agents[s.id] else { return }
        let before = w.tracker.state
        w.tracker.input(at: Date())
        agents[s.id] = w
        if w.tracker.state != before { publishAgent(s.id, change: nil) }
    }

    /// A bell (`message` nil) or a desktop notification from the pane.
    func sessionAttention(_ s: TerminalSession, message: String?) {
        if var w = agents[s.id] {
            let change = w.tracker.attention(message, at: Date())
            agents[s.id] = w
            if let change { publishAgent(s.id, change: change) }
            return
        }
        // Any other program's explicit notification (OSC 9 / 777 / 99) from a
        // pane you're not looking at; a plain bell isn't worth a row.
        guard let message, !isViewing(s.id) else { return }
        upsert(IslandItem(id: "note:\(s.id)", source: .command, title: s.title, detail: message,
                          tone: .attention, sessionID: s.id, at: Date()))
        // It's information, not a question: flash it, then let it go like a
        // finished row.
        finish("note:\(s.id)", success: true, detail: message,
               pulse: message.count > 48 ? String(message.prefix(47)) + "…" : message)
    }

    func sessionTitle(_ s: TerminalSession, _ title: String) {
        if var w = agents[s.id] {
            let change = w.tracker.title(title, at: Date())
            agents[s.id] = w
            if let change { publishAgent(s.id, change: change) }
            if w.remote, CodingAgentTracker.titleHint(title) == nil, title.contains("@") {
                agents[s.id] = nil                      // back to a shell's user@host title
                remove("agent:\(s.id)")
            }
            return
        }
        // Over SSH there's no foreground process to look at; Claude Code's
        // spinner / ✳ title gives it away.
        guard case .ssh = s.kind, let hint = CodingAgentTracker.titleHint(title) else { return }
        var tracker = CodingAgentTracker(now: Date())
        tracker.title(title, at: Date())
        agents[s.id] = AgentWatch(agent: .claude, tracker: tracker, remote: true)
        publishAgent(s.id, change: hint == .working ? .startedWorking : nil)
    }

    /// A shell command finished (OSC 133;D, or the prompt heuristic).
    func commandFinished(_ s: TerminalSession, exitCode: Int?, duration: TimeInterval) {
        if agents[s.id]?.remote == true {
            agents[s.id] = nil                          // the prompt is back: the agent exited
            remove("agent:\(s.id)")
        }
        guard agents[s.id] == nil, !isViewing(s.id) else { return }
        let threshold = UserDefaults.standard.object(forKey: "notifyCommandAfter") as? Double ?? 10
        guard duration >= threshold else { return }
        let id = "cmd:\(s.id)"
        let failed = (exitCode ?? 0) != 0
        let detail = failed ? loc.t("退出码 \(exitCode ?? 0) · ", "exit \(exitCode ?? 0) · ") + islandDuration(duration)
                            : loc.t("完成 · ", "done · ") + islandDuration(duration)
        upsert(IslandItem(id: id, source: .command, title: s.title, detail: detail, tone: .working,
                          sessionID: s.id, at: Date()))
        finish(id, success: !failed, detail: detail,
               pulse: (failed ? "✕ " : "✓ ") + s.title + " · " + islandDuration(duration))
    }

    /// The pane closed or its process went away.
    func sessionGone(_ id: UUID) {
        agents[id] = nil
        for prefix in ["agent:", "inline:", "note:"] { remove(prefix + id.uuidString) }
    }

    private func publishAgent(_ sid: UUID, change: CodingAgentTracker.Change?) {
        guard let w = agents[sid], let s = sessions?.session(sid) else { return }
        let id = "agent:\(sid)"
        let title = "\(w.agent.displayName) · \(Self.place(of: s))"
        let source = IslandSource.codingAgent(w.agent.rawValue)
        let tone: IslandTone, detail: String
        switch w.tracker.state {
        case .idle: tone = .idle; detail = loc.t("等你输入", "Waiting for a prompt")
        case .working: tone = .working; detail = loc.t("工作中…", "Working…")
        case .needsYou(let m): tone = .attention; detail = m ?? loc.t("等你回复", "Waiting for you")
        case .done: tone = .success; detail = loc.t("完成，等你下一步", "Done — your turn")
        }
        upsert(IslandItem(id: id, source: source, title: title, detail: detail, tone: tone,
                          sessionID: sid, persistent: true, at: Date()))
        let viewing = isViewing(sid)
        if viewing { board.dismiss(id) }
        if case .finished(let ran)? = change, !viewing, ran >= 3 {
            now = Date()
            board.finish(id, success: true, detail: detail,
                         pulse: "✓ " + w.agent.displayName + " · " + islandDuration(ran), at: now)
            reschedule()
        }
    }

    /// "~/src/app" for a local pane, "web-1 · /var/log" for SSH.
    private static func place(of s: TerminalSession) -> String {
        switch s.kind {
        case .localShell:
            guard let dir = s.currentDirectory else { return s.title }
            let home = NSHomeDirectory()
            return dir.hasPrefix(home) ? "~" + dir.dropFirst(home.count) : dir
        case .ssh, .sftp:
            return s.remoteDirectory.map { "\(s.alias) · \($0)" } ?? s.alias
        }
    }
}
