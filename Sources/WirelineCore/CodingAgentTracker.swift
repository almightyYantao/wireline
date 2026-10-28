import Foundation

/// The coding agents (CLI programs that work on their own and then wait for
/// you) Wireline recognises in a pane, by foreground program name.
public enum CodingAgent: String, CaseIterable, Sendable {
    case claude, codex, gemini, aider, opencode, cursor = "cursor-agent", amp, goose, crush, qwen

    /// The agent a foreground program name (as `ForegroundProcess` reports
    /// it: `claude`, `codex`, `cursor-agent` …) stands for, else nil.
    public init?(processName: String) {
        let n = processName.lowercased()
        if let a = CodingAgent(rawValue: n) { self = a; return }
        switch n {
        case "claude-code": self = .claude
        case "gemini-cli": self = .gemini
        case "qwen-code": self = .qwen
        default: return nil
        }
    }

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .gemini: "Gemini"
        case .aider: "Aider"
        case .opencode: "opencode"
        case .cursor: "Cursor Agent"
        case .amp: "Amp"
        case .goose: "Goose"
        case .crush: "Crush"
        case .qwen: "Qwen Code"
        }
    }

    /// Two letters for a tab badge.
    public var abbreviation: String {
        switch self {
        case .claude: "CC"
        case .codex: "CX"
        case .gemini: "GM"
        case .aider: "AI"
        case .opencode: "OC"
        case .cursor: "CU"
        case .amp: "AM"
        case .goose: "GS"
        case .crush: "CR"
        case .qwen: "QW"
        }
    }
}

/// Guesses what a coding agent in a terminal pane is doing from the outside —
/// its output rhythm, the keys you type, its bells / desktop notifications and
/// the window title it sets — since none of them report state directly.
///
/// - **working**: a sustained burst of output you didn't cause by typing
///   (agents redraw a spinner many times a second while they think), or a
///   title with a spinner glyph (Claude Code prefixes a braille spinner).
/// - **needs you**: a bell or desktop notification (Claude Code sends one
///   when it wants a permission or has been idle), until you type.
/// - **done**: it was working and the output has gone quiet (or the title
///   switched to Claude Code's idle `✳`) — its turn is over.
///
/// Pure and clock-injected, so the rules are testable.
public struct CodingAgentTracker: Sendable, Equatable {
    public enum State: Equatable, Sendable {
        /// Launched, nothing observed yet / you're typing to it.
        case idle
        case working
        /// It asked for you (bell / notification); the message, if any.
        case needsYou(String?)
        /// Its turn finished; waiting for the next prompt.
        case done
    }

    /// A transition worth telling the user about.
    public enum Change: Equatable, Sendable {
        case startedWorking
        /// A turn ended after running this long.
        case finished(TimeInterval)
        case needsYou(String?)
    }

    /// Output quiet this long ends a working turn.
    public static let quietAfter: TimeInterval = 3.5
    /// Output this soon after a keystroke is (probably) its echo.
    public static let echoWindow: TimeInterval = 1.0
    /// A burst lasting this long, with no typing, means it's working.
    public static let burstToWork: TimeInterval = 1.0
    /// A gap this long between chunks starts a new burst.
    public static let burstGap: TimeInterval = 0.6

    public private(set) var state: State = .idle
    public private(set) var stateSince: Date
    /// When the current working turn began.
    public private(set) var workStartedAt: Date?
    private var lastOutput: Date?
    private var lastInput: Date?
    private var burstStart: Date?
    /// The agent reports its own state through hooks: stop guessing.
    public private(set) var hookDriven = false
    /// Its hooks report tool calls too (newer installs).
    public private(set) var toolHooks = false

    // What the hooks say beyond the state, for the island's card.
    /// The prompt that started the current / last turn.
    public private(set) var lastPrompt: String?
    /// The tool running right now.
    public private(set) var currentTool: String?
    /// The tool it's asking permission to run.
    public private(set) var permissionTool: String?
    /// Tool calls in the current turn.
    public private(set) var toolCount = 0
    /// Subagents running, and since when the first of them.
    public private(set) var subagents = 0
    public private(set) var subagentsSince: Date?
    /// Why the last turn stopped on an error.
    public private(set) var lastError: String?

    public init(now: Date) { stateSince = now }

    /// An exact state report from the agent's hooks. From then on it wins
    /// over every heuristic, unless the agent's hooks don't cover a whole
    /// turn (`exclusive` false).
    @discardableResult
    public mutating func hook(_ event: AgentHooks.Event, at t: Date, exclusive: Bool = true) -> Change? {
        if exclusive { hookDriven = true }
        switch event {
        case .prompted(let p):
            lastPrompt = p
            fallthrough
        case .promptSubmitted:
            toolCount = 0; lastError = nil; currentTool = nil; permissionTool = nil
        case .toolStarted(let tool):
            toolHooks = true
            // A permission prompt answered "allow": the tool runs now.
            permissionTool = nil
            currentTool = tool.isEmpty ? nil : tool
            toolCount += 1
        case .toolFinished:
            toolHooks = true
            currentTool = nil; permissionTool = nil
        case .permission(let tool):
            toolHooks = true
            permissionTool = tool
        case .notification(let m):
            // Its permission request already said so.
            if permissionTool != nil, case .needsYou = state { return nil }
            if case .needsYou(let old) = state, old == m { return nil }
        case .subagentStarted:
            if subagents == 0 { subagentsSince = t }
            subagents += 1
            return nil
        case .subagentStopped:
            subagents = max(0, subagents - 1)
            if subagents == 0 { subagentsSince = nil }
            return nil
        case .stop:
            currentTool = nil; permissionTool = nil
            // The main agent waits on its subagents; it isn't done yet.
            if subagents > 0 { return nil }
        case .stopFailed(let m):
            currentTool = nil; permissionTool = nil; subagents = 0; subagentsSince = nil
            lastError = m ?? ""
        case .sessionStarted, .sessionEnded:
            currentTool = nil; permissionTool = nil; subagents = 0; subagentsSince = nil
        }
        guard let new = event.state else { return nil }
        return set(new, at: t)
    }

    /// A chunk of output from the agent.
    @discardableResult
    public mutating func output(at t: Date) -> Change? {
        if let last = lastOutput, t.timeIntervalSince(last) <= Self.burstGap, burstStart != nil {
            // Same burst.
        } else {
            burstStart = t
        }
        lastOutput = t
        guard !hookDriven, state != .working, let burstStart else { return nil }
        if case .needsYou = state { return nil }      // only typing clears a request
        let typing = lastInput.map { t.timeIntervalSince($0) < Self.echoWindow } ?? false
        guard !typing, t.timeIntervalSince(burstStart) >= Self.burstToWork else { return nil }
        return set(.working, at: t)
    }

    /// The user typed into the pane.
    public mutating func input(at t: Date) {
        lastInput = t
        if hookDriven {
            // Answering a permission prompt resumes the turn; a finished turn
            // stays done until the next prompt is submitted. (Esc on a
            // permission prompt sends no hook at all, so typing is the signal.)
            if case .needsYou = state { permissionTool = nil; _ = set(.working, at: t) }
            return
        }
        if case .needsYou = state { _ = set(.idle, at: t) }
        if state == .done { _ = set(.idle, at: t) }
    }

    /// A bell or a desktop notification.
    @discardableResult
    public mutating func attention(_ message: String?, at t: Date) -> Change? {
        guard !hookDriven else { return nil }     // the Notification hook says it exactly
        if case .needsYou(let m) = state, m == message { return nil }
        return set(.needsYou(message), at: t)
    }

    /// A window title the agent set (OSC 0 / 2).
    @discardableResult
    public mutating func title(_ title: String, at t: Date) -> Change? {
        guard !hookDriven else { return nil }
        switch Self.titleHint(title) {
        case .working?:
            if case .needsYou = state { return nil }
            return state == .working ? nil : set(.working, at: t)
        case .idle?:
            return state == .working ? set(.done, at: t) : nil
        case nil:
            return nil
        }
    }

    /// Time passing: ends a working turn whose output went quiet.
    @discardableResult
    public mutating func tick(at t: Date) -> Change? {
        guard !hookDriven, state == .working, let last = lastOutput ?? workStartedAt,
              t.timeIntervalSince(last) >= Self.quietAfter else { return nil }
        // The turn ran until its last output, not until we noticed the quiet.
        return set(.done, at: t, workEnded: last)
    }

    /// When `tick` could next change something, for scheduling.
    public var nextTick: Date? {
        guard !hookDriven, state == .working, let last = lastOutput ?? workStartedAt else { return nil }
        return last.addingTimeInterval(Self.quietAfter)
    }

    private mutating func set(_ new: State, at t: Date, workEnded: Date? = nil) -> Change? {
        let old = state
        guard new != old else { return nil }
        state = new
        stateSince = t
        switch new {
        case .working:
            workStartedAt = t
            return .startedWorking
        case .done:
            let ran = workStartedAt.map { max(0, (workEnded ?? t).timeIntervalSince($0)) } ?? 0
            workStartedAt = nil
            return .finished(ran)
        case .needsYou(let m):
            workStartedAt = nil
            return .needsYou(m)
        case .idle:
            workStartedAt = nil
            return nil
        }
    }

    public enum TitleHint: Equatable, Sendable { case working, idle }

    /// What an agent's window title says about it. Claude Code titles its
    /// window `<spinner> <task>` while it works — a braille spinner frame — and
    /// `✳ <task>` when it's waiting for you.
    public static func titleHint(_ title: String) -> TitleHint? {
        guard let first = title.trimmingCharacters(in: .whitespaces).unicodeScalars.first else { return nil }
        if (0x2801...0x28FF).contains(first.value) { return .working }   // ⠁…⣿ (not the blank ⠀)
        if first == "✳" { return .idle }
        return nil
    }
}
