import Foundation

/// How an island row is doing.
public enum IslandTone: Equatable, Sendable {
    case working
    /// Wants the user: a confirmation, or an agent waiting for an answer.
    case attention
    case success
    case failure
    /// Present but quiet (an agent at its prompt).
    case idle
}

/// Where an activity comes from — picks its icon.
public enum IslandSource: Equatable, Sendable {
    /// The AI panel's chat / agent run.
    case ai
    /// A fleet run across a host group.
    case fleet
    /// The ⌘; inline command assistant.
    case inlineAI
    /// A coding agent CLI in a pane (`CodingAgent.rawValue`).
    case codingAgent(String)
    /// A long shell command.
    case command
}

/// Progress for runs over many targets (fleet).
public struct IslandProgress: Equatable, Sendable {
    public var done: Int
    public var total: Int
    public var failed: Int
    public init(done: Int, total: Int, failed: Int = 0) {
        self.done = done; self.total = total; self.failed = failed
    }
    public var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
}

/// A question the island can answer on the user's behalf (Allow / Deny).
public struct IslandConfirmation: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case dangerousCommand, toolCall, fileTransfer }
    public var kind: Kind
    /// The command / tool / transfer being asked about.
    public var subject: String
    /// Whether "always allow" is offered (MCP tools).
    public var canAlwaysAllow: Bool
    /// Extra context that can arrive later (the AI's impact assessment).
    public var note: String?
    public init(kind: Kind, subject: String, canAlwaysAllow: Bool = false, note: String? = nil) {
        self.kind = kind; self.subject = subject; self.canAlwaysAllow = canAlwaysAllow; self.note = note
    }

    /// The same question (a late `note` doesn't make it a new one).
    public func asks(_ other: IslandConfirmation?) -> Bool {
        guard let other else { return false }
        return kind == other.kind && subject == other.subject
    }
}

/// What a coding agent's hooks told us, for its card.
public struct IslandAgentInfo: Equatable, Sendable {
    /// The prompt that started this turn.
    public var prompt: String?
    /// Tool calls this turn.
    public var toolCount: Int
    /// Subagents running, and since when.
    public var subagents: Int
    public var subagentsSince: Date?
    public init(prompt: String? = nil, toolCount: Int = 0, subagents: Int = 0, subagentsSince: Date? = nil) {
        self.prompt = prompt; self.toolCount = toolCount; self.subagents = subagents; self.subagentsSince = subagentsSince
    }
}

/// One row on the island.
public struct IslandItem: Identifiable, Equatable, Sendable {
    public var id: String
    public var source: IslandSource
    /// Host / pane / run name.
    public var title: String
    /// What's happening: "思考中…", "执行 df -h", "等你确认".
    public var detail: String
    public var tone: IslandTone
    public var progress: IslandProgress?
    public var confirmation: IslandConfirmation?
    /// The pane a click jumps to.
    public var sessionID: UUID?
    /// Kept after it finishes (a coding agent whose process is still running);
    /// otherwise a finished row lingers briefly, then goes.
    public var persistent: Bool
    public var startedAt: Date
    public var updatedAt: Date
    public var finishedAt: Date?
    /// When it last started wanting the user.
    public var attentionAt: Date?
    /// A coding agent's prompt, tool count and subagents.
    public var agent: IslandAgentInfo?

    public init(id: String, source: IslandSource, title: String, detail: String, tone: IslandTone,
                progress: IslandProgress? = nil, confirmation: IslandConfirmation? = nil,
                sessionID: UUID? = nil, persistent: Bool = false, at now: Date) {
        self.id = id; self.source = source; self.title = title; self.detail = detail; self.tone = tone
        self.progress = progress; self.confirmation = confirmation; self.sessionID = sessionID
        self.persistent = persistent; self.startedAt = now; self.updatedAt = now
        self.finishedAt = tone == .success || tone == .failure ? now : nil
        self.attentionAt = tone == .attention || confirmation != nil ? now : nil
    }

    /// Wants an answer right now.
    public var needsUser: Bool { confirmation != nil || tone == .attention }
}

/// A brief "✓ 完成 · 12s" flash after something finishes.
public struct IslandPulse: Equatable, Sendable {
    public var itemID: String
    public var source: IslandSource
    public var text: String
    public var tone: IslandTone
    public var until: Date
}

/// What the island looks like right now.
public enum IslandMode: Equatable, Sendable {
    /// Not shown at all.
    case hidden
    /// Only the hardware notch's own shape (no ears): invisible on a notched
    /// screen, but hovering it peeks and a click opens the list. Off-notch: hidden.
    case dormant
    /// Notch plus small ears: something is running, or the pointer is on it.
    case collapsed
    /// A wider collapsed capsule carrying one line ("✓ 完成 · 12s").
    case pulse(IslandPulse)
    /// The card with the activity list.
    case expanded
}

/// The right ear.
public enum IslandStatus: Equatable, Sendable {
    case none
    /// Something running — `count` of them.
    case working(Int)
    /// Something needs you — `count` of them.
    case attention(Int)
    case success
    case failure
}

/// The island's activity list and the rules for when it shows, grows and
/// shrinks. Pure and clock-injected: `IslandCenter` feeds it and renders it.
public struct IslandBoard: Equatable, Sendable {
    public private(set) var items: [IslandItem] = []
    public private(set) var pulse: IslandPulse?
    /// Attention rows the user folded away (they stay in the list).
    public private(set) var dismissed: Set<String> = []

    /// How long a finished row stays listed.
    public var linger: TimeInterval = 45
    /// How long a completion pulse shows.
    public var pulseLength: TimeInterval = 2.6
    /// A row pulses at most once per this long — an agent that pauses
    /// mid-task reads as "done" several times, and each pulse drops a black
    /// strip from the top of the screen.
    public var pulseCooldown: TimeInterval = 30
    /// …and nothing pulses more often than this.
    public var pulseSpacing: TimeInterval = 8
    private var lastPulse: [String: Date] = [:]
    private var lastAnyPulse: Date?

    public init() {}

    public func item(_ id: String) -> IslandItem? { items.first { $0.id == id } }

    /// Add a row or update it in place (it keeps its start time and position).
    public mutating func upsert(_ new: IslandItem, at now: Date) {
        guard let i = items.firstIndex(where: { $0.id == new.id }) else {
            items.append(new)
            if new.needsUser, new.confirmation == nil { flashAttention(new, at: now) }
            return
        }
        let old = items[i]
        var merged = new
        let finishedNow = new.tone == .success || new.tone == .failure
        // A finished row that starts again is a new run: it keeps its place,
        // not its old start time.
        merged.startedAt = old.finishedAt != nil && !finishedNow ? now : old.startedAt
        merged.updatedAt = now
        merged.finishedAt = finishedNow ? (old.tone == new.tone ? old.finishedAt ?? now : now) : nil
        if new.needsUser {
            // A new request (or a different question) re-opens the card.
            let same = old.needsUser && (old.confirmation == nil && new.confirmation == nil
                ? old.detail == new.detail : old.confirmation?.asks(new.confirmation) == true)
            merged.attentionAt = same ? old.attentionAt : now
            if !same { dismissed.remove(new.id) }
            if !same, new.confirmation == nil { flashAttention(merged, at: now) }
        } else {
            merged.attentionAt = nil
            dismissed.remove(new.id)
        }
        items[i] = merged
    }

    /// Mark a row finished, optionally flashing a pulse.
    public mutating func finish(_ id: String, success: Bool, detail: String,
                                pulse text: String?, at now: Date) {
        guard var item = item(id) else { return }
        item.tone = success ? .success : .failure
        item.detail = detail
        item.confirmation = nil
        upsert(item, at: now)
        if let text, pulseAllowed(id, at: now) {
            lastPulse[id] = now
            lastAnyPulse = now
            pulse = IslandPulse(itemID: id, source: item.source, text: text,
                                tone: item.tone, until: now.addingTimeInterval(pulseLength))
        }
    }

    /// A "waiting for you" without a question to answer (an agent at its
    /// prompt) only flashes: it doesn't keep the island up.
    private mutating func flashAttention(_ item: IslandItem, at now: Date) {
        guard pulseAllowed(item.id, at: now) else { return }
        lastPulse[item.id] = now
        lastAnyPulse = now
        let text = item.detail.isEmpty ? item.title : item.title + " · " + item.detail
        pulse = IslandPulse(itemID: item.id, source: item.source, text: text,
                            tone: .attention, until: now.addingTimeInterval(pulseLength))
    }

    /// Failures always get through; successes respect the cooldowns.
    private func pulseAllowed(_ id: String, at now: Date) -> Bool {
        if item(id)?.tone == .failure { return true }
        if let t = lastPulse[id], now.timeIntervalSince(t) < pulseCooldown { return false }
        if let t = lastAnyPulse, now.timeIntervalSince(t) < pulseSpacing { return false }
        return true
    }

    public mutating func remove(_ id: String) {
        items.removeAll { $0.id == id }
        dismissed.remove(id)
        if pulse?.itemID == id { pulse = nil }
    }

    /// The user folded the card while something wanted them: stop forcing it open.
    public mutating func dismissAttention() {
        for item in items where item.needsUser { dismissed.insert(item.id) }
        pulse = nil
    }

    /// Don't force the card open for this row's current request (the user is
    /// already looking at it). It's forgotten once the row stops asking.
    public mutating func dismiss(_ id: String) {
        if item(id)?.needsUser == true { dismissed.insert(id) }
    }

    /// Drop expired pulses and finished rows past their linger.
    public mutating func prune(at now: Date) {
        if let p = pulse, p.until <= now { pulse = nil }
        items.removeAll { item in
            guard !item.persistent, let done = item.finishedAt else { return false }
            return now.timeIntervalSince(done) >= linger
        }
    }

    /// Is this row a reason to show the island at all? Only work in progress
    /// and a question to answer: an idle or finished agent, a done command,
    /// keep it tucked behind the notch (their moment was the pulse).
    private func isLive(_ item: IslandItem) -> Bool {
        item.tone == .working || item.confirmation != nil
    }

    /// Whether something should hold the card open without a click: a
    /// confirmation (an AI waiting on Allow / Deny), until it's folded away.
    private func forcesOpen(_ item: IslandItem) -> Bool {
        item.confirmation != nil && !dismissed.contains(item.id)
    }

    /// `hovering` only peeks (the ears come out, saying "click me"); `pinned`
    /// is the user's click, which opens the card even with nothing in it.
    public func mode(at now: Date, hovering: Bool, pinned: Bool = false, alwaysShow: Bool) -> IslandMode {
        if pinned || items.contains(where: forcesOpen) { return .expanded }
        if let pulse, pulse.until > now { return .pulse(pulse) }
        if hovering || alwaysShow || items.contains(where: isLive) { return .collapsed }
        return .dormant
    }

    /// Rows in display order: needs-you first, then running, then the rest
    /// (newest first within each group).
    public var ordered: [IslandItem] {
        func rank(_ i: IslandItem) -> Int {
            if i.confirmation != nil { return 0 }
            switch i.tone {
            case .attention: return 1
            case .working: return 2
            case .failure: return 3
            case .success: return 4
            case .idle: return 5
            }
        }
        return items.enumerated().sorted { a, b in
            let ra = rank(a.element), rb = rank(b.element)
            return ra != rb ? ra < rb : a.offset > b.offset
        }.map(\.element)
    }

    /// The right ear: what needs you beats what's running beats how the last
    /// thing ended.
    public func status(at now: Date) -> IslandStatus {
        let asking = items.filter(\.needsUser).count
        if asking > 0 { return .attention(asking) }
        let running = items.filter { $0.tone == .working }.count
        if running > 0 { return .working(running) }
        let recent = items.filter { ($0.finishedAt.map { now.timeIntervalSince($0) < linger }) ?? false }
            .max { ($0.finishedAt ?? .distantPast) < ($1.finishedAt ?? .distantPast) }
        switch recent?.tone {
        case .failure?: return .failure
        case .success?: return .success
        default: return .none
        }
    }

    /// The left ear: the source of the row that matters most, nil = the
    /// Wireline mark.
    public var leadSource: IslandSource? {
        ordered.first { $0.tone != .idle }?.source
    }

    /// The next moment `mode` / `prune` can change by itself, for a timer.
    public func nextDeadline(after now: Date) -> Date? {
        var dates: [Date] = []
        if let p = pulse, p.until > now { dates.append(p.until) }
        for item in items {
            if let done = item.finishedAt, !item.persistent || now.timeIntervalSince(done) < linger {
                let end = done.addingTimeInterval(linger)
                if end > now { dates.append(end) }
            }
        }
        return dates.min()
    }
}

/// "12s", "3m 05s", "1h 02m".
public func islandDuration(_ seconds: TimeInterval) -> String {
    let s = max(0, Int(seconds.rounded()))
    if s < 60 { return "\(s)s" }
    if s < 3600 { return String(format: "%dm %02ds", s / 60, s % 60) }
    return String(format: "%dh %02dm", s / 3600, (s % 3600) / 60)
}
