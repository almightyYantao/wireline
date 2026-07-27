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
    var messages: [AIMessage] = []       // shown in the transcript
    var modelMessages: [AIMessage] = []  // what the model actually sees
    var input = ""
    var streaming = ""
    var isStreaming = false
    var errorText: String?
    var task: Task<Void, Never>?
    var agentSteps = 0
    var sessionTokens = 0
    var lastPromptTokens = 0
    var useFast = false
    var pendingDanger: String?           // command awaiting confirmation
    var dangerReview = ""                // AI impact assessment for it
    var pendingMCP: PendingMCPCall?      // MCP tool call awaiting confirmation
    var pendingTransfer: PendingTransfer? // file upload/download awaiting confirmation
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
        let state = AIConvoState()
        registry[key] = state
        return state
    }

    private static var registry: [String: AIConvoState] = [:]
}
