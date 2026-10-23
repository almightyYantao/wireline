import Foundation
import Observation

/// Live state of one AI conversation (one per host; all local shells share
/// `__local__`), owned *outside* the panel view.
///
/// `AIPanelView` is rebuilt — and torn down entirely when the AI panel closes or
/// the active tab moves to another host — so keeping the transcript and the
/// in-flight stream in `@State` meant switching tabs mid-answer threw the whole
/// turn away: the question, the partial reply, and the request itself. The state
/// lives here instead, and the streaming task writes into its own object no
/// matter what's on screen; switching back re-renders it, still streaming.
@Observable
@MainActor
final class AIConvoState {
    /// The conversation key (host alias, or `__local__`).
    let key: String
    var messages: [AIMessage] = []       // shown in the transcript
    var modelMessages: [AIMessage] = []  // what the model actually sees
    var input = ""
    var streaming = ""
    var isStreaming = false { didSet { if isStreaming != oldValue { reportToIsland() } } }
    var errorText: String? { didSet { if errorText != oldValue { reportToIsland() } } }
    var task: Task<Void, Never>?
    var agentSteps = 0
    var sessionTokens = 0
    var lastPromptTokens = 0
    var useFast = false
    // Pending confirmations. Shown by the panel's dialog *and* the notch
    // island; both answer through `decide`, so the first answer wins and the
    // other one goes away when the value is cleared.
    var pendingDanger: String? { didSet { if pendingDanger != oldValue { reportToIsland() } } }       // command awaiting confirmation
    var dangerReview = "" { didSet { if pendingDanger != nil, dangerReview != oldValue { reportToIsland() } } } // AI impact assessment for it
    var pendingMCP: PendingMCPCall? { didSet { if pendingMCP != oldValue { reportToIsland() } } }      // MCP tool call awaiting confirmation
    var pendingTransfer: PendingTransfer? { didSet { if pendingTransfer != oldValue { reportToIsland() } } } // file upload/download awaiting confirmation
    /// Resolves whichever confirmation is pending — installed by the panel
    /// that raised it (the same code its dialog buttons run).
    @ObservationIgnored var onDecision: ((IslandDecision) -> Void)?

    // For the notch island.
    /// Where this conversation runs ("prod-web-01", "本地").
    var islandTitle = ""
    /// The pane it drives, for jumping back.
    var islandSessionID: UUID?
    /// What the agent is doing right now ("执行 df -h @ prod-web-01"), nil = thinking.
    var currentStep: String? { didSet { if currentStep != oldValue { reportToIsland() } } }

    /// Answer the pending confirmation (from the island or the dialog).
    func decide(_ decision: IslandDecision) { onDecision?(decision) }

    private func reportToIsland() { IslandCenter.shared.aiChanged(self) }
    // Circuit breaker: stop the agent loop when it stalls or spins.
    var timeoutStreak = 0                // consecutive capture timeouts
    var lastAgentCmd: String?            // to detect an identical-command loop
    var repeatStreak = 0
    /// Output of the last command the agent ran this turn — used to catch the
    /// model handing a line of that output back as if it were a new command.
    var lastOutput = ""
    /// Whether the persisted transcript has been merged in — once per app run,
    /// after which this object (not the file) is the live source of truth.
    var loadedFromDisk = false

    /// The live state for a conversation key, created on first use and kept for
    /// the rest of the app's run.
    static func shared(_ key: String) -> AIConvoState {
        if let existing = registry[key] { return existing }
        let state = AIConvoState(key: key)
        registry[key] = state
        return state
    }

    private init(key: String) { self.key = key }

    private static var registry: [String: AIConvoState] = [:]
}
