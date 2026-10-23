import SwiftUI
import AppKit
import WirelineCore

/// The AI assistant panel: a context-aware chat with quick actions for the four
/// MVP capabilities (NL→command, diagnose error, explain, summarize). Runnable
/// commands come back in fenced code blocks, each with an "insert into terminal"
/// button — nothing ever auto-runs.
struct AIPanelView: View {
    @Environment(Localizer.self) private var loc
    @Environment(HostStore.self) private var store
    @Environment(SnippetStore.self) private var snippets
    @Environment(ForwardStore.self) private var forwards
    @Environment(SessionStore.self) private var sessions
    @State private var ai = AIConfig.shared
    let session: TerminalSession?
    let host: Host?
    var onClose: () -> Void

    @State private var chats = AIChatStore.shared
    @State private var showFleet = false
    // Owned by RightPanel so ⌘I / tab switches can query and re-assert focus.
    @FocusState.Binding var inputFocused: Bool
    /// Docked as a column beside the terminal (true) or floating over it.
    var docked: Bool = true
    /// Pin / unpin the panel; nil hides the pin button.
    var onTogglePin: (() -> Void)? = nil

    private let maxAgentSteps = 8
    private let mcpResultCap = 4000                      // chars of tool output fed back
    private let maxTimeoutStreak = 2
    private let maxRepeatStreak = 2

    // MARK: conversation state
    //
    // The transcript and the in-flight turn live in `AIConvoState`, keyed by
    // conversation — NOT in `@State` — so tearing this view down (tab switched to
    // another host, panel closed) can't discard an answer that's still streaming.
    // These proxies keep the call sites reading like plain properties.

    private var convo: AIConvoState { AIConvoState.shared(conversationKey) }

    private var messages: [AIMessage] {
        get { convo.messages } nonmutating set { convo.messages = newValue }
    }
    private var modelMessages: [AIMessage] {
        get { convo.modelMessages } nonmutating set { convo.modelMessages = newValue }
    }
    private var input: String {
        get { convo.input } nonmutating set { convo.input = newValue }
    }
    private var streaming: String {
        get { convo.streaming } nonmutating set { convo.streaming = newValue }
    }
    private var isStreaming: Bool {
        get { convo.isStreaming } nonmutating set { convo.isStreaming = newValue }
    }
    private var errorText: String? {
        get { convo.errorText } nonmutating set { convo.errorText = newValue }
    }
    private var task: Task<Void, Never>? {
        get { convo.task } nonmutating set { convo.task = newValue }
    }
    private var agentSteps: Int {
        get { convo.agentSteps } nonmutating set { convo.agentSteps = newValue }
    }
    private var sessionTokens: Int {
        get { convo.sessionTokens } nonmutating set { convo.sessionTokens = newValue }
    }
    private var lastPromptTokens: Int {
        get { convo.lastPromptTokens } nonmutating set { convo.lastPromptTokens = newValue }
    }
    private var useFast: Bool {
        get { convo.useFast } nonmutating set { convo.useFast = newValue }
    }
    private var pendingDanger: String? {
        get { convo.pendingDanger } nonmutating set { convo.pendingDanger = newValue }
    }
    private var dangerReview: String {
        get { convo.dangerReview } nonmutating set { convo.dangerReview = newValue }
    }
    private var pendingMCP: PendingMCPCall? {
        get { convo.pendingMCP } nonmutating set { convo.pendingMCP = newValue }
    }
    private var pendingTransfer: PendingTransfer? {
        get { convo.pendingTransfer } nonmutating set { convo.pendingTransfer = newValue }
    }
    private var timeoutStreak: Int {
        get { convo.timeoutStreak } nonmutating set { convo.timeoutStreak = newValue }
    }
    private var lastAgentCmd: String? {
        get { convo.lastAgentCmd } nonmutating set { convo.lastAgentCmd = newValue }
    }
    private var repeatStreak: Int {
        get { convo.repeatStreak } nonmutating set { convo.repeatStreak = newValue }
    }

    // Scroll following: whether the transcript is pinned to the bottom (so new
    // output follows) vs. the user has scrolled up to read history (so we leave
    // them be). Derived from measured geometry — see `distanceFromBottom`.
    @State private var atBottom = true
    @State private var viewportH: CGFloat = 0
    @State private var contentH: CGFloat = 0
    @State private var contentTopY: CGFloat = 0
    /// Bumped when the user sends a turn, to force the view back to the bottom
    /// even if they'd scrolled up.
    @State private var forceStickToken = 0
    /// How close (pt) to the bottom still counts as "following".
    private static let stickThreshold: CGFloat = 40
    /// Distance in points from the current viewport bottom to the content bottom
    /// (0 when pinned to the bottom, grows as you scroll up).
    private var distanceFromBottom: CGFloat { contentH + contentTopY - viewportH }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: WL.radius(14), style: .continuous)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            WLFormDivider()
            quickActions
            conversation
            inputBar
        }
        .frame(width: 380)
        .frame(maxHeight: .infinity)
        // A card like the panes and the host drawer, docked or floating. The
        // content is clipped to it; the shadow sits on the shape only. Floating
        // it's opaque (no terminal text showing through) and lifts higher.
        .clipShape(cardShape)
        .wlFloating(cardShape,
                    fill: WL.bg.opacity(docked ? store.terminalOpacity * WL.chromeOpacity : 1),
                    shadow: docked ? 0.16 : 0.32, radius: docked ? 6 : 22, y: docked ? 2 : 6)
        .wlModal(isPresented: $showFleet) {
            FleetView(onClose: { wlAnimate(Motion.flipOut) { showFleet = false } })
        }
        .onAppear { inputFocused = true; loadConvo(); bindIsland() }
        .onChange(of: conversationKey) { _, _ in loadConvo(); bindIsland() }
        .onChange(of: convo.messages) { persistConvo() }
        // No `task?.cancel()` here: the panel disappears on a host switch and on
        // close, and an answer in flight must survive both (see `AIConvoState`).
        .onDisappear { persistConvo() }
        .alert(loc("确认执行高危命令？", "Run this risky command?"),
               isPresented: Binding(get: { pendingDanger != nil },
                                    set: { if !$0 { pendingDanger = nil } })) {
            Button(loc("取消", "Cancel"), role: .cancel) { resolvePending(.deny) }
            Button(loc("仍然执行", "Run anyway"), role: .destructive) { resolvePending(.allow) }
        } message: {
            Text((pendingDanger ?? "") + (dangerReview.isEmpty ? "" : "\n\n" + dangerReview))
        }
        .alert(loc("调用外部工具？", "Call this external tool?"),
               isPresented: Binding(get: { pendingMCP != nil },
                                    set: { if !$0 { pendingMCP = nil } })) {
            Button(loc("取消", "Cancel"), role: .cancel) { resolvePending(.deny) }
            Button(loc("调用", "Call")) { resolvePending(.allow) }
            Button(loc("始终允许并调用", "Always allow & call")) { resolvePending(.allowAlways) }
        } message: {
            if let p = pendingMCP {
                Text("\(p.server).\(p.tool)" + (p.argsJSON == "{}" ? "" : "\n\n" + p.argsJSON))
            }
        }
        .alert(pendingTransfer?.isUpload == true ? loc("确认上传？", "Confirm upload?")
                                                 : loc("确认下载？", "Confirm download?"),
               isPresented: Binding(get: { pendingTransfer != nil },
                                    set: { if !$0 { pendingTransfer = nil } })) {
            Button(loc("取消", "Cancel"), role: .cancel) { resolvePending(.deny) }
            Button(loc("传输", "Transfer")) { resolvePending(.allow) }
        } message: {
            if let t = pendingTransfer { Text(t.summary(loc)) }
        }
    }

    /// Answer whichever confirmation is pending. The dialog's buttons and the
    /// notch island's (through `AIConvoState.decide`) both land here, so the
    /// first answer wins: it clears the pending value, which dismisses the
    /// dialog and folds the island's row, and a second answer finds nothing.
    /// On allow, the turn is marked running *before* the request is cleared,
    /// so the island sees one continuous run rather than an end and a restart.
    private func resolvePending(_ decision: IslandDecision) {
        if let c = pendingDanger {
            if decision == .deny { declineDanger(); return }
            isStreaming = true
            pendingDanger = nil
            executeAndContinue(c)
        } else if let p = pendingMCP {
            if decision == .deny { declineMCP(); return }
            if decision == .allowAlways { MCPStore.shared.approve("\(p.server).\(p.tool)") }
            isStreaming = true
            pendingMCP = nil
            executeMCPAndContinue(p)
        } else if let t = pendingTransfer {
            if decision == .deny { declineTransfer(); return }
            isStreaming = true
            pendingTransfer = nil
            executeTransfer(t)
        }
    }

    /// Tell the notch island where this conversation runs and how to answer
    /// its confirmations.
    private func bindIsland() {
        let c = convo
        c.islandTitle = host?.alias ?? loc("本地", "Local")
        c.islandSessionID = session?.id
        c.onDecision = { decision in resolvePending(decision) }
    }

    private func declineTransfer() {
        guard let t = pendingTransfer else { return }
        pendingTransfer = nil
        messages.append(AIMessage(role: .system, content: loc("已取消传输。", "Transfer cancelled.")))
        if t.continueAgent {
            modelMessages.append(AIMessage(role: .user, content: "用户取消了这次文件传输，请不要重试，改用自然语言说明或询问用户。"))
        }
        isStreaming = false; agentSteps = 0
    }

    private func declineMCP() {
        guard let p = pendingMCP else { return }
        pendingMCP = nil
        messages.append(AIMessage(role: .system, content: loc("已取消工具调用。", "Tool call cancelled.")))
        modelMessages.append(AIMessage(role: .user,
            content: "用户拒绝了工具 \(p.server).\(p.tool) 的调用。请不要重试该工具；如仍需信息，用自然语言告诉用户，或改用其它只读工具。"))
        isStreaming = false
        agentSteps = 0
    }

    /// Quick AI impact assessment shown in the dangerous-command dialog.
    private func fetchDangerReview(_ cmd: String) {
        dangerReview = loc("正在评估影响…", "Assessing impact…")
        let client = AIClient(config: ai)
        let model = ai.hasFastModel ? ai.activeModelFast : nil
        let sys = "你是命令安全评审员。用中文一两句话说明这条命令的影响面和主要风险，非常简短，不要客套、不要重复命令本身。"
        Task {
            var text = ""
            do { for try await d in client.stream(system: sys, messages: [AIMessage(role: .user, content: cmd)], model: model) { text += d } }
            catch { return }
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            await MainActor.run { if pendingDanger == cmd, !t.isEmpty { dangerReview = t } }
        }
    }

    private func declineDanger() {
        pendingDanger = nil
        messages.append(AIMessage(role: .system, content: loc("已取消执行。", "Execution cancelled.")))
        isStreaming = false
        agentSteps = 0
    }

    // MARK: header

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 12, weight: .medium)).foregroundStyle(WL.green)
                Text(loc("AI 助手", "AI Assistant")).font(WL.mono(13, .semibold)).foregroundStyle(WL.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if ai.hasFastModel {
                    chip(loc("快速", "Fast"), on: useFast) { useFast.toggle() }
                        .help(loc("用便宜/快速模型跑这条", "Use the fast/cheap model"))
                }
                chip(loc("自动执行", "Agent"), on: ai.agentMode) { ai.agentMode.toggle() }
                    .help(loc("开启后 AI 会自动执行命令并根据输出继续", "Let AI run commands and continue from their output"))
                HStack(spacing: 0) {
                    if !messages.isEmpty {
                        Button {
                            messages.removeAll(); modelMessages.removeAll(); errorText = nil
                            sessionTokens = 0; chats.clear(conversationKey)
                        } label: { Image(systemName: "trash").font(.system(size: 11, weight: .medium)) }
                            .buttonStyle(.wlIcon).help(loc("清空对话", "Clear conversation"))
                    }
                    if let onTogglePin {
                        Button(action: onTogglePin) {
                            Image(systemName: docked ? "pin.fill" : "pin").font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.wlIcon(tint: docked ? WL.green : nil))
                        .help(docked ? loc("取消固定：改为浮在终端上方", "Unpin: float over the terminal")
                                     : loc("固定为侧栏：终端让出位置", "Pin as a column beside the terminal"))
                    }
                    Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                        .buttonStyle(.wlIcon).help(loc("关闭 (⌘I)", "Close (⌘I)"))
                }
            }
            // Like the host drawer's header: the card is inset by the pane
            // gap, and the title row sits in the title-bar band.
            .frame(height: TitleBand.shared.height - wlPaneGap + 6)
            if sessionTokens > 0 {
                Text(usageText).font(WL.caption).foregroundStyle(WL.textDim)
                    .padding(.leading, 18).padding(.bottom, 8)
            }
        }
        .padding(.leading, 14).padding(.trailing, 8)
        .blocksWindowDrag()   // title-bar band: see WLPageHeader
    }

    /// A small on/off capsule for the header toggles; the dot echoes the state.
    private func chip(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Circle().fill(.foreground).frame(width: 5, height: 5).opacity(on ? 1 : 0.5)
                Text(title)
            }
        }
        .buttonStyle(.wlChip(on: on))
    }

    private var usageText: String {
        let tokStr = sessionTokens >= 1000 ? String(format: "%.1fk", Double(sessionTokens) / 1000) : "\(sessionTokens)"
        var s = "≈ \(tokStr) tokens"
        if ai.pricePer1k > 0 {
            let cost = Double(sessionTokens) / 1000 * ai.pricePer1k
            s += String(format: " · ≈ %.4f", cost)
        }
        return s
    }

    // MARK: quick actions

    private var quickActions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip(loc("生成命令", "Command"), "terminal") { generateCommand() }
                chip(loc("诊断报错", "Diagnose"), "stethoscope") { diagnose() }
                chip(loc("解释", "Explain"), "text.magnifyingglass") { explain() }
                chip(loc("总结", "Summarize"), "list.bullet.rectangle") { summarize() }
                chip(loc("找命令", "History"), "clock.arrow.circlepath") {
                    input = "@历史 "; inputFocused = true
                }
                chip(loc("存脚本", "To script"), "square.and.arrow.down") { saveScript() }
                chip(loc("复盘", "Runbook"), "doc.text.magnifyingglass") { makeRunbook() }
                chip(loc("群跑", "Fleet"), "square.grid.3x3.fill") { showFleet = true }
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
        }
    }

    private func chip(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 9))
                Text(title)
            }
        }
        .buttonStyle(.wlChip())
        .disabled(isStreaming)
    }

    // MARK: conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if messages.isEmpty && streaming.isEmpty {
                        emptyState
                    }
                    ForEach(messages) { msg in
                        MessageBubble(message: msg, session: session, runTargets: runTargets, loc: loc,
                                      fontSize: ai.fontSize, onSave: saveAsSnippet, onAction: executeAction,
                                      onCopy: copyToClipboard, onRetry: retryUserMessage)
                    }
                    if isStreaming || !streaming.isEmpty {
                        MessageBubble(message: AIMessage(role: .assistant, content: streaming.isEmpty ? "…" : streaming),
                                      session: session, runTargets: runTargets, loc: loc, fontSize: ai.fontSize,
                                      onSave: saveAsSnippet, onAction: { _ in })
                            .id("streaming")
                    }
                    if let errorText {
                        Text(errorText).font(WL.caption).foregroundStyle(WL.red)
                            .padding(.horizontal, 12).padding(.vertical, 9)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(WL.red.opacity(0.1), in: RoundedRectangle(cornerRadius: WL.radius(12), style: .continuous))
                    }
                    // Invisible bottom anchor: scrolling to it always sticks the
                    // view to the very bottom as content streams in / grows.
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(12)
                // Measure the content: its total height, and where its top sits in
                // the viewport. Growth changes only the height (top stays put), so
                // we can tell "new output arrived" from "the user scrolled".
                .background(GeometryReader { g in
                    Color.clear
                        .preference(key: ContentHeightKey.self, value: g.size.height)
                        .preference(key: ContentTopKey.self, value: g.frame(in: .named("conv")).minY)
                })
            }
            .coordinateSpace(name: "conv")
            .background(GeometryReader { g in
                Color.clear.preference(key: ViewportHeightKey.self, value: g.size.height)
            })
            // Reliable content-change triggers drive the actual follow — these
            // always fire, unlike a background GeometryReader's height preference.
            // Follow only if the user is still pinned to the bottom.
            .onChange(of: streaming) { followIfPinned(proxy) }
            .onChange(of: messages.count) { followIfPinned(proxy) }
            .onChange(of: errorText) { followIfPinned(proxy) }
            // The user sent a turn, switched conversation, or just appeared: always
            // snap back to the bottom to follow.
            .onChange(of: forceStickToken) { snapToBottom(proxy) }
            .onChange(of: conversationKey) { snapToBottom(proxy) }
            .onAppear { snapToBottom(proxy) }
            // Geometry probes: keep the measured sizes current, and detect a real
            // user scroll-up by the *direction* the content top moves. Content
            // growth moves only the height (top stays), so it never trips this;
            // and we never latch to "scrolled up" off a stale distance.
            .onPreferenceChange(ViewportHeightKey.self) { viewportH = $0 }
            .onPreferenceChange(ContentHeightKey.self) { contentH = $0 }
            .onPreferenceChange(ContentTopKey.self) { y in
                let movedDown = y > contentTopY + 0.5   // content slid down = user scrolled up
                contentTopY = y
                guard viewportH > 0 else { return }
                if distanceFromBottom <= Self.stickThreshold {
                    atBottom = true             // at/near the bottom → keep following
                } else if movedDown {
                    atBottom = false            // pulled up into history → stop following
                }
            }
            // "Jump to bottom" affordance — only while the user is scrolled up.
            .overlay(alignment: .bottomTrailing) {
                if !atBottom { jumpToBottomButton(proxy) }
            }
        }
    }

    /// Follow new output to the bottom, but only while the user is pinned there.
    /// Deferred one runloop tick so SwiftUI finishes laying out the freshly grown
    /// content (a completed code fence, a big command-output message) before we
    /// compute the bottom offset — otherwise we'd land mid-content.
    private func followIfPinned(_ proxy: ScrollViewProxy) {
        guard atBottom else { return }
        DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) }
    }

    /// Force the transcript back to the bottom (user sent a turn / switched / first
    /// appeared) and resume following, regardless of where they'd scrolled.
    private func snapToBottom(_ proxy: ScrollViewProxy) {
        atBottom = true
        DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) }
    }

    private func jumpToBottomButton(_ proxy: ScrollViewProxy) -> some View {
        Button {
            atBottom = true
            withAnimation(Motion.scroll) { proxy.scrollTo("bottom", anchor: .bottom) }
        } label: {
            Image(systemName: isStreaming ? "arrow.down.circle.fill" : "arrow.down")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(WL.bg)
                .frame(width: 28, height: 28)
                .background(WL.green, in: Circle())
                .overlay(Circle().stroke(WL.bg.opacity(0.25), lineWidth: 1))
                .shadow(color: .black.opacity(0.3), radius: 4, y: 1)
        }
        .buttonStyle(.wlPlain)
        .help(loc("回到底部", "Jump to bottom"))
        .padding(.trailing, 14)
        .padding(.bottom, 12)
        .transition(.wlPop(anchor: .bottom))
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !ai.isConfigured {
                Text(loc("尚未配置 AI。请到 设置 → AI 填写服务地址与 API Key。",
                        "AI isn't configured. Open Settings → AI to set the endpoint & API key."))
                    .font(WL.caption).foregroundStyle(WL.amber)
            } else {
                Text(loc("问我任何终端 / 运维问题，或用上面的快捷动作。",
                        "Ask me anything about the terminal, or use the quick actions above."))
                    .font(WL.caption).foregroundStyle(WL.textDim)
                Text(loc("生成的命令会以代码块给出，点「插入 / 运行」由你决定执行。",
                        "Commands come as code blocks — Insert or Run as you decide."))
                    .font(WL.caption).foregroundStyle(WL.textDim)
                Text(loc("可用 @输出 引用终端输出、@主机 引用主机信息、@历史 引用命令历史、@别名 引用其他已连主机的输出。",
                        "Use @output, @host, @history, or @<alias> to inject that context."))
                    .font(WL.caption).foregroundStyle(WL.textDim)
                if runTargets.count > 1 {
                    Text(loc("已连接多台主机——命令代码块的「运行 ▾」可选择在哪台执行。",
                            "Multiple hosts connected — a command's Run ▾ menu lets you pick which one."))
                        .font(WL.caption).foregroundStyle(WL.textDim)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: input

    private var inputBar: some View {
        WLComposer(prompt: loc("输入问题…", "Ask…"),
                   text: Binding(get: { input }, set: { input = $0 }),
                   focus: $inputFocused,
                   busy: isStreaming,
                   canSend: !input.trimmingCharacters(in: .whitespaces).isEmpty,
                   onSend: { sendFreeform() },
                   onStop: { task?.cancel(); isStreaming = false; agentSteps = 0 })
            .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 10)
    }

    // MARK: actions

    // MARK: per-host persistence

    /// Conversation key: each host keeps its own history; local shells share one.
    private var conversationKey: String { host?.alias ?? "__local__" }

    /// Connected sessions the AI can run a proposed command on — the active one
    /// first. Lets one conversation drive multiple hosts, with manual per-command
    /// targeting via the Run menu.
    private var runTargets: [TerminalSession] {
        let connected = sessions.sessions.filter(\.isRunning)
        guard let active = session else { return connected }
        return [active] + connected.filter { $0.id != active.id }
    }

    /// Bring the persisted transcript in the first time a conversation is shown.
    /// After that the in-memory `AIConvoState` is authoritative — re-reading the
    /// file would clobber a turn that's still streaming.
    private func loadConvo() {
        let state = convo
        guard !state.loadedFromDisk else { return }
        let stored = chats.load(conversationKey)
        state.messages = stored.display
        state.modelMessages = stored.model
        state.errorText = nil
        state.loadedFromDisk = true
    }

    private func persistConvo() {
        chats.save(conversationKey, display: messages, model: modelMessages)
    }

    // MARK: @-references

    /// Expand `@输出/@output` and `@主机/@host` mentions into real context so the
    /// user can precisely control what the model sees.
    private func expandReferences(_ text: String) -> String {
        var out = text
        if out.range(of: #"@(输出|output)"#, options: .regularExpression) != nil {
            out = out.replacingOccurrences(of: #"@(输出|output)"#,
                                           with: "\n\n[终端最近输出]\n" + contextOutput(),
                                           options: .regularExpression)
        }
        if out.range(of: #"@(主机|host)"#, options: .regularExpression) != nil {
            var info = "(本地 shell)"
            if let host {
                info = "alias=\(host.alias), host=\(host.connectHostname), user=\(host.user ?? "-"), port=\(host.effectivePort)"
            }
            out = out.replacingOccurrences(of: #"@(主机|host)"#,
                                           with: "\n\n[当前主机] " + info,
                                           options: .regularExpression)
        }
        // @<别名>: pull another connected host's recent output into context, so one
        // conversation can reason across hosts. Longest aliases first so `@web` in a
        // message can't shadow `@web1`.
        for s in sessions.sessions.filter(\.isRunning).sorted(by: { $0.alias.count > $1.alias.count }) {
            let token = "@" + s.alias
            guard !s.alias.isEmpty, out.contains(token) else { continue }
            let clean = String(s.recentOutput.suffix(3000))
            let body = ai.redact ? AIRedactor.redact(clean) : clean
            out = out.replacingOccurrences(of: token, with: "\n\n[主机 \(s.alias) 最近输出]\n" + body)
        }
        return out
    }

    private func sendFreeform() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        input = ""
        beginUserTurn(text)
        isStreaming = true; streaming = ""
        task = Task {
            let prompt = await expandReferencesAsync(text)
            await MainActor.run {
                modelMessages.append(AIMessage(role: .user, content: prompt))
                startTurn()
            }
        }
    }

    /// Async reference expansion — `@历史/@history` fetches the host's shell
    /// history out-of-band so the model can recall past commands semantically.
    private func expandReferencesAsync(_ text: String) async -> String {
        var out = expandReferences(text)
        if out.range(of: #"@(历史|history)"#, options: .regularExpression) != nil {
            let hist = await fetchHistory()
            out = out.replacingOccurrences(of: #"@(历史|history)"#,
                                           with: "\n\n[命令历史]\n" + hist,
                                           options: .regularExpression)
        }
        return out
    }

    private func fetchHistory() async -> String {
        guard let session else { return "(无会话)" }
        let cmd = "tail -n 300 ~/.zsh_history 2>/dev/null || tail -n 300 ~/.bash_history 2>/dev/null || fc -l 1 2>/dev/null | tail -n 300"
        let out = await session.runCapturing(cmd)   // out-of-band: don't spam the terminal
        let trimmed = String(out.suffix(6000))
        return ai.redact ? AIRedactor.redact(trimmed) : trimmed
    }

    private func generateCommand() {
        let req = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !req.isEmpty else { inputFocused = true; return }
        input = ""
        send(userVisible: loc("生成命令：", "Command: ") + req,
             promptForModel: "把下面的需求转成可在当前主机执行的 shell 命令：\n\(req)")
    }

    private func diagnose() {
        let out = contextOutput()
        send(userVisible: loc("诊断最近的报错", "Diagnose the recent error"),
             promptForModel: "下面是终端最近的输出，分析其中的错误原因并给出修复命令：\n\n\(out)")
    }

    private func explain() {
        let target = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = target.isEmpty ? lastCommandLine() : target
        guard !subject.isEmpty else { inputFocused = true; return }
        input = ""
        send(userVisible: loc("解释：", "Explain: ") + subject,
             promptForModel: "解释这段命令的作用；如果包含危险操作，用 ⚠️ 开头明确警告（不要执行它）：\n\(subject)")
    }

    private func summarize() {
        let out = contextOutput()
        send(userVisible: loc("总结输出", "Summarize output"),
             promptForModel: "简明总结下面的终端输出，突出关键结果和异常：\n\n\(out)")
    }

    private func saveScript() {
        let out = contextOutput()
        send(userVisible: loc("把本次操作整理成脚本", "Turn this session into a script"),
             promptForModel: "根据下面的终端历史，把我执行过的关键命令整理成一个可复用的 shell 脚本；把其中可变的部分（路径 / IP / 主机名 / 参数）替换成 «参数名» 占位符（用书名号 «»，不要用 {{}}，那是 Go 模板语法）；只输出一个 ```bash 代码块，脚本第一行写注释 `# name: <简短名称>`。然后点代码块的「存片段」即可保存：\n\n\(out)")
    }

    private func makeRunbook() {
        let out = contextOutput()
        send(userVisible: loc("生成本次操作的 Runbook", "Generate a runbook for this session"),
             promptForModel: "根据下面的终端历史（命令与输出），整理成一份可复用的 Runbook，用 Markdown 输出，结构包含：## 目标 / ## 前置条件 / ## 步骤（每步：一句说明 + 对应命令放进 ```bash 块）/ ## 验证 / ## 回滚与注意。命令中可变部分用 «参数名» 标注（书名号 «»，不要用 {{}}）。\n\n\(out)")
    }

    /// Save an AI-produced code block as a reusable snippet. A leading
    /// `# name: …` comment becomes the snippet name.
    private func saveAsSnippet(_ code: String) {
        var name = loc("AI 脚本", "AI script")
        var body = code
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let first = lines.first,
           let r = first.range(of: #"^#\s*name\s*[:：]\s*"#, options: .regularExpression) {
            let n = String(first[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !n.isEmpty { name = n }
            body = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        snippets.add(Snippet(title: name, command: body))
        messages.append(AIMessage(role: .system, content: loc("已存为片段：\(name)", "Saved snippet: \(name)")))
    }

    /// Execute a confirmed app action (create tunnel / add host).
    private func executeAction(_ action: WLAction) {
        switch action {
        case let .portForward(host, lp, rh, rp):
            let f = PortForward(hostAlias: host, localPort: lp, remoteHost: rh, remotePort: rp,
                                bindAddress: "127.0.0.1", label: "AI")
            forwards.add(f)
            forwards.toggle(f, host: store.hosts.first { $0.alias == host })   // start it
            messages.append(AIMessage(role: .system, content: loc("✓ 已创建并启动转发：本地 \(lp) → \(host):\(rh):\(rp)",
                                                                   "✓ Tunnel started: local \(lp) → \(host):\(rh):\(rp)")))
        case let .addHost(alias, hostname, user, port, group):
            let h = Host(alias: alias, hostname: hostname, user: user, port: port, group: group)
            store.upsert(h, password: nil)
            messages.append(AIMessage(role: .system, content: loc("✓ 已新增主机：\(alias)", "✓ Host added: \(alias)")))
        case let .connect(host):
            NotificationCenter.default.post(name: .aiConnect, object: host)
            messages.append(AIMessage(role: .system, content: loc("✓ 已发起连接：\(host)", "✓ Connecting: \(host)")))
        case let .openFiles(host):
            NotificationCenter.default.post(name: .aiOpenFiles, object: host)
            messages.append(AIMessage(role: .system, content: loc("✓ 已打开文件浏览器：\(host)", "✓ Opened files: \(host)")))
        case let .runSnippet(name):
            if let s = snippets.find(named: name) {
                // Parameters with a default / last value are filled in; any
                // still blank → insert as-is for the user to fill.
                let values = s.initialValues()
                if values.values.allSatisfy({ !$0.isEmpty }) { session?.runInTerminal(s.filled(with: values)) }
                else { session?.insertIntoTerminal(s.command) }
                snippets.recordUse(s.id)
                let title = s.title(chinese: loc.isChinese)
                messages.append(AIMessage(role: .system, content: loc("✓ 已运行片段：\(title)", "✓ Ran snippet: \(title)")))
            } else {
                messages.append(AIMessage(role: .system, content: loc("未找到片段：\(name)", "Snippet not found: \(name)")))
            }
        case let .remember(note):
            HostMemoryStore.shared.add(note, for: conversationKey)
            messages.append(AIMessage(role: .system, content: loc("🧠 已记住：\(note)", "🧠 Remembered: \(note)")))
        case let .useSkill(id):
            loadSkill(id)     // inject the playbook and continue the conversation
        case .upload, .download:
            if let t = PendingTransfer.from(action, continueAgent: false) { requestTransfer(t) }
        case let .mcpCall(server, tool, argsJSON):
            // Card path (non-agent): run the tool once and show the result.
            let cap = mcpResultCap, redact = ai.redact
            messages.append(AIMessage(role: .system,
                content: loc("▶︎ 调用 MCP 工具：\(server).\(tool)", "▶︎ Calling MCP tool: \(server).\(tool)")))
            Task {
                let raw: String
                do { raw = try await MCPStore.shared.callTool(server: server, tool: tool, argsJSON: argsJSON) }
                catch { raw = loc("工具调用失败：", "Tool call failed: ") + ((error as? MCPError)?.description ?? error.localizedDescription) }
                let shown = redact ? AIRedactor.redact(String(raw.prefix(cap))) : String(raw.prefix(cap))
                await MainActor.run { messages.append(AIMessage(role: .system, content: shown)) }
            }
        }
    }

    private func contextOutput() -> String {
        let raw = session?.recentOutput ?? ""
        let trimmed = String(raw.suffix(4000))
        return ai.redact ? AIRedactor.redact(trimmed) : trimmed
    }

    private func lastCommandLine() -> String {
        let lines = (session?.recentOutput ?? "").split(whereSeparator: { $0 == "\n" || $0 == "\r" })
        return lines.reversed().first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map(String.init) ?? ""
    }

    // MARK: conversation loop

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Re-ask a previous user message (runs it again as a fresh turn).
    private func retryUserMessage(_ content: String) {
        guard !isStreaming else { return }
        send(userVisible: content, promptForModel: content)
    }

    private func send(userVisible: String, promptForModel: String) {
        guard !isStreaming else { return }
        beginUserTurn(userVisible)
        modelMessages.append(AIMessage(role: .user, content: promptForModel))
        startTurn()
    }

    private func beginUserTurn(_ userVisible: String) {
        errorText = nil
        agentSteps = 0
        timeoutStreak = 0; repeatStreak = 0; lastAgentCmd = nil
        convo.lastOutput = ""   // a new question: nothing has been run for it yet
        messages.append(AIMessage(role: .user, content: userVisible))
        // Sending a turn always snaps the transcript back to the bottom to follow
        // the reply, even if the user had scrolled up in the previous answer.
        forceStickToken += 1
    }

    private func startTurn() {
        bindIsland()
        convo.currentStep = nil          // the island reads "thinking…"
        isStreaming = true
        streaming = ""
        let client = AIClient(config: ai)
        let system = systemPrompt()
        let history = modelMessages
        let model = (useFast && ai.hasFastModel) ? ai.activeModelFast : nil
        // Estimate the prompt tokens sent this turn (system + full history).
        lastPromptTokens = AITokenEstimator.estimate(system + history.map(\.content).joined(separator: "\n"))
        task = Task {
            var text = ""
            do {
                for try await delta in client.stream(system: system, messages: history, model: model) {
                    text += delta
                    await MainActor.run { streaming = text }
                }
            } catch is CancellationError {
            } catch {
                await MainActor.run { errorText = error.localizedDescription }
            }
            await MainActor.run { finishTurn(text) }
        }
    }

    private func finishTurn(_ text: String) {
        streaming = ""
        // Persist here too: a turn can now land while the panel is hidden, and
        // then the view's `onChange(of:)` isn't around to save it.
        defer { persistConvo() }
        sessionTokens += lastPromptTokens + AITokenEstimator.estimate(text)
        lastPromptTokens = 0
        if !text.isEmpty {
            messages.append(AIMessage(role: .assistant, content: text))
            modelMessages.append(AIMessage(role: .assistant, content: text))
        }
        // Agent mode: if the model proposed a command or an MCP tool call, run it
        // and feed the result back.
        let proposal = (ai.agentMode && agentSteps < maxAgentSteps) ? proposedCommand(in: text) : CommandProposal.none
        if case let .rejected(note) = proposal {
            // The reply fenced something that isn't a command (output, a config,
            // a line echoed back from the last result). Never auto-run it — leave
            // it as a code block the user can run deliberately.
            messages.append(AIMessage(role: .system, content: note))
            isStreaming = false
            agentSteps = 0
        } else if case let .runnable(cmd) = proposal {
            if let ph = AICommandSafety.unfilledPlaceholder(cmd) {
                // B — placeholder guard: never run a command with a literal {{…}}.
                haltAgent(loc("命令里有未填的占位符 \(ph)，已停止。请补一个具体值后重试，或先把命令里的 \(ph) 换成实际值。",
                              "Command still has an unfilled placeholder \(ph) — stopped. Provide a concrete value and retry."))
            } else if isRepeatLoop(cmd) {
                // A — loop guard: same command over and over.
                haltAgent(loc("AI 在反复执行同一条命令，已停止自动执行。", "The AI kept repeating the same command — auto-execution stopped."))
            } else if ai.agentReadOnly && !AICommandSafety.isReadOnly(cmd) {
                refuseSandbox(cmd)           // read-only sandbox: bounce it back
            } else if AICommandSafety.isDangerous(cmd) {
                pendingDanger = cmd          // ask before running
                fetchDangerReview(cmd)       // AI impact assessment for the dialog
                isStreaming = false
            } else {
                executeAndContinue(cmd)
            }
        } else if agentSteps < maxAgentSteps,
                  case let .useSkill(id)? = WLAction.parse(from: text) {
            loadSkill(id)            // inject the playbook; safe regardless of agent mode
        } else if ai.agentMode, agentSteps < maxAgentSteps,
                  case let .mcpCall(server, tool, argsJSON)? = WLAction.parse(from: text) {
            routeMCP(PendingMCPCall(server: server, tool: tool, argsJSON: argsJSON))
        } else if ai.agentMode, agentSteps < maxAgentSteps,
                  let t = PendingTransfer.from(WLAction.parse(from: text), continueAgent: true) {
            requestTransfer(t)
        } else {
            isStreaming = false
            agentSteps = 0
        }
    }

    /// Validate a transfer, then ask the user to confirm (outbound/inbound data).
    private func requestTransfer(_ t: PendingTransfer) {
        if t.isUpload, !FileManager.default.fileExists(atPath: (t.localPath as NSString).expandingTildeInPath) {
            messages.append(AIMessage(role: .system, content: loc("本地路径不存在：\(t.localPath)", "Local path not found: \(t.localPath)")))
            if t.continueAgent {
                agentSteps += 1
                modelMessages.append(AIMessage(role: .user, content: "本地路径 \(t.localPath) 不存在，无法上传。请确认路径或询问用户。"))
                startTurn()
            } else { isStreaming = false }
            return
        }
        pendingTransfer = t
        isStreaming = false
    }

    private func executeTransfer(_ t: PendingTransfer) {
        if t.continueAgent { agentSteps += 1 }
        isStreaming = true
        convo.currentStep = t.summary(loc)
        messages.append(AIMessage(role: .system, content: "▶︎ " + t.summary(loc)))
        let local = (t.localPath as NSString).expandingTildeInPath
        task = Task {
            let r = t.isUpload
                ? await FleetRunner.upload(localPath: local, to: t.host, remotePath: t.remotePath)
                : await FleetRunner.download(from: t.host, remotePath: t.remotePath, localPath: local)
            await MainActor.run {
                messages.append(AIMessage(role: .system, content: r.output))
                if t.continueAgent {
                    modelMessages.append(AIMessage(role: .user, content: "文件传输结果（退出码 \(r.exitCode)）：\n\(r.output)\n请据此继续或给出结论。"))
                    startTurn()
                } else {
                    isStreaming = false
                }
            }
        }
    }

    /// Pull an ops skill's full instructions into the conversation and continue.
    private func loadSkill(_ id: String) {
        agentSteps += 1
        guard let skill = SkillStore.shared.skill(id: id), skill.enabled else {
            messages.append(AIMessage(role: .system, content: loc("技能未找到：\(id)", "Skill not found: \(id)")))
            modelMessages.append(AIMessage(role: .user, content: "技能 \(id) 不存在或未启用。请直接作答，或改用一个已列出的技能，不要重试该 id。"))
            startTurn()
            return
        }
        messages.append(AIMessage(role: .system, content: loc("📋 已载入技能：\(skill.name)", "📋 Loaded skill: \(skill.name)")))
        modelMessages.append(AIMessage(role: .user,
            content: "【技能：\(skill.name)】\n\(skill.body)\n\n现在按上述步骤开始（可用命令的照常用 ```bash 代码块执行）。"))
        startTurn()
    }

    // MARK: MCP tool calls (agent loop)

    /// Apply the safety gate to a proposed tool call, then run it or ask first.
    private func routeMCP(_ call: PendingMCPCall) {
        let store = MCPStore.shared
        guard let ref = store.find(server: call.server, tool: call.tool) else {
            agentSteps += 1
            messages.append(AIMessage(role: .system,
                content: loc("MCP 工具未找到：\(call.server).\(call.tool)", "MCP tool not found: \(call.server).\(call.tool)")))
            modelMessages.append(AIMessage(role: .user,
                content: "工具 \(call.server).\(call.tool) 不存在或未连接。请改用可用工具，或用自然语言告知用户，不要重试该工具。"))
            startTurn()
            return
        }
        if ai.agentReadOnly && !ref.isReadOnly {
            agentSteps += 1
            messages.append(AIMessage(role: .system,
                content: loc("⛔ 只读沙盒拦截工具：\(call.server).\(call.tool)", "⛔ Blocked by read-only sandbox: \(call.server).\(call.tool)")))
            modelMessages.append(AIMessage(role: .user,
                content: "工具 \(call.server).\(call.tool) 可能有副作用，被只读沙盒拒绝。请改用只读工具，或停止并告知用户。"))
            startTurn()
            return
        }
        if store.requiresConfirmation(ref) {
            pendingMCP = call                // mutating & not pre-approved: confirm first
            isStreaming = false
        } else {
            executeMCPAndContinue(call)      // read-only or pre-approved: run directly
        }
    }

    private func executeMCPAndContinue(_ call: PendingMCPCall) {
        agentSteps += 1
        messages.append(AIMessage(role: .system,
            content: loc("▶︎ 调用 MCP 工具：\(call.server).\(call.tool)", "▶︎ Calling MCP tool: \(call.server).\(call.tool)")))
        isStreaming = true
        convo.currentStep = loc("调用 \(call.server).\(call.tool)", "Calling \(call.server).\(call.tool)")
        let cap = mcpResultCap
        let redact = ai.redact
        task = Task {
            let raw: String
            do {
                raw = try await MCPStore.shared.callTool(server: call.server, tool: call.tool, argsJSON: call.argsJSON)
            } catch {
                raw = loc("工具调用失败：", "Tool call failed: ") + ((error as? MCPError)?.description ?? error.localizedDescription)
            }
            let trimmed = String(raw.prefix(cap))
            let shown = redact ? AIRedactor.redact(trimmed) : trimmed
            await MainActor.run {
                messages.append(AIMessage(role: .system, content: shown))
                modelMessages.append(AIMessage(role: .user,
                    content: "工具 \(call.server).\(call.tool) 的结果：\n\(shown)"))
                startTurn()
            }
        }
    }

    /// In read-only sandbox mode, reject a mutating command and let the model try
    /// a read-only alternative (or tell the user to run it manually).
    private func refuseSandbox(_ cmd: String) {
        agentSteps += 1
        messages.append(AIMessage(role: .system, content: loc("⛔ 只读沙盒拦截：\(cmd)", "⛔ Blocked by read-only sandbox: \(cmd)")))
        modelMessages.append(AIMessage(role: .user, content: "命令 `\(cmd)` 被只读沙盒拒绝（当前只允许只读/查询命令）。请改用只读命令获取所需信息；若必须执行写操作，请停止并用自然语言告诉用户需要手动执行什么，不要再尝试。"))
        startTurn()
    }

    private func executeAndContinue(_ cmd: String) {
        guard let session else {
            messages.append(AIMessage(role: .system, content: loc("无可用会话，无法执行。", "No session to run in.")))
            isStreaming = false; return
        }
        agentSteps += 1
        isStreaming = true
        convo.currentStep = loc("执行 \(cmd) @ \(convo.islandTitle)", "Running \(cmd) @ \(convo.islandTitle)")
        messages.append(AIMessage(role: .system, content: "▶︎ \(cmd)"))
        task = Task {
            let output = ai.agentInTerminal
                ? await session.runInTerminalCapturing(cmd)
                : await session.runCapturing(cmd)
            let shown = String(output.suffix(4000))
            await MainActor.run {
                messages.append(AIMessage(role: .system, content: shown))
                convo.lastOutput = shown
                // A — timeout breaker: if capture keeps timing out, the terminal is
                // likely wedged; stop rather than spin on dead commands.
                if output.contains("(执行超时)") {
                    timeoutStreak += 1
                    if timeoutStreak >= maxTimeoutStreak {
                        haltAgent(loc("连续多次执行超时，终端可能已卡住，已停止自动执行。请检查或重连该终端后再试。",
                                      "Repeated capture timeouts — the terminal looks wedged. Auto-execution stopped; check or reconnect the terminal."))
                        return
                    }
                } else {
                    timeoutStreak = 0
                }
                let forModel = ai.redact ? AIRedactor.redact(shown) : shown
                modelMessages.append(AIMessage(role: .user, content: "命令 `\(cmd)` 的输出：\n\(forModel)\n请根据输出继续（执行下一条命令，或给出最终结论）。"))
                startTurn()
            }
        }
    }

    /// Track consecutive identical agent commands; true once it exceeds the cap.
    private func isRepeatLoop(_ cmd: String) -> Bool {
        repeatStreak = (cmd == lastAgentCmd) ? repeatStreak + 1 : 0
        lastAgentCmd = cmd
        return repeatStreak >= maxRepeatStreak
    }

    /// Stop the agent loop cleanly with a user-facing note (no feedback to model).
    private func haltAgent(_ note: String) {
        messages.append(AIMessage(role: .system, content: note))
        isStreaming = false
        agentSteps = 0
        timeoutStreak = 0; repeatStreak = 0; lastAgentCmd = nil
    }


    /// What agent mode should do with the fenced blocks in a reply.
    private enum CommandProposal {
        case runnable(String)
        /// A shell-ish fence we refuse to auto-run, with the reason to show.
        case rejected(String)
        case none
    }

    /// Decide whether a reply actually asked for a command to be executed.
    /// Anything else the model fences — output it quoted back, a config file, a
    /// `text`/`json`/`log` block — must never reach the shell on its own.
    private func proposedCommand(in text: String) -> CommandProposal {
        switch AICodeFence.proposal(in: text) {
        case .none:
            return .none
        case .notACommand:
            return .rejected(loc("⚠️ 代码块看起来是输出 / 文件内容而不是命令，已跳过自动执行。确实要执行请点代码块的「运行」。",
                                 "⚠️ That block reads like output or file content, not a command — not auto-run. Use the block's Run button if you meant it."))
        case let .runnable(cmd):
            // The model pasting a line straight back from the last result is the
            // most common way "output" ends up being run as a command.
            guard !AICodeFence.echoesOutput(cmd, in: convo.lastOutput) else {
                return .rejected(loc("⚠️ 这条与上一条命令的输出完全相同，像是把输出当成了命令，已跳过自动执行。",
                                     "⚠️ That line is verbatim from the last command's output, not a new command — not auto-run."))
            }
            return .runnable(cmd)
        }
    }

    private func systemPrompt() -> String {
        var ctx = "你是 Wireline SSH 客户端里的终端运维助手。回答简洁、可操作，用中文。"
        if ai.agentMode {
            ctx += "【重要】你处于自动执行模式：你**有能力**执行命令——把要执行的**一条**命令放在 ```bash 代码块里，本客户端会真实执行并把输出返回给你。"
            ctx += "严禁回答“我无法执行/我不能直接运行”之类的话；需要信息就直接给出命令让系统执行。"
            ctx += "拿到输出后，继续给下一条命令，或在任务完成时用自然语言给出最终结论（结论里不要再放代码块）。"
            ctx += "优先使用只读/幂等命令；高危操作会由系统弹窗让用户二次确认，你照常给出即可。"
            // The ```bash fence is the execution channel — the single most common
            // agent failure is quoting output back inside it, which then gets run.
            ctx += "【代码块规则，必须遵守】```bash 块是执行通道，只能放你要执行的命令本身。"
            ctx += "命令的输出、日志、报错、文件/配置内容、示例结果——一律不要放进 ```bash，要引用就用 ```text 块或普通文字。"
            ctx += "不要把命令和它的预期输出放进同一个块；不要在命令前加 `$`、`%`、`➜` 等提示符；一个块只放一条命令（多步就分多轮）。"
            ctx += "严禁把上一条命令的输出内容原样当作下一条命令提交——系统会识别并拒绝执行。"
            ctx += "如果某个值必须由用户提供且你无法从输出中确定，不要臆造：写成 «说明» 占位符并停下来问用户（带 «» 的命令不会被执行）。"
            ctx += "注意 Go 模板的 {{…}}（如 docker --format '{{.Names}}'、kubectl -o go-template）是正常命令语法，可照常使用。"
            if ai.agentReadOnly {
                ctx += "【只读沙盒已开启】只能执行只读/查询命令（ls、cat、ps、df、systemctl status、docker ps 等），任何写操作/删除/重启都会被系统拒绝，不要尝试。"
            }
        } else {
            ctx += "所有可直接执行的 shell 命令必须放在 ```bash 代码块里，一行一条；解释放在代码块外。"
            ctx += "```bash 只放命令：输出、日志、文件内容、示例结果请用 ```text 块，否则会被当成可执行命令。"
            ctx += "需要用户填的值写成 «参数名» 占位符（不要用 {{}}，那是 Go 模板语法）。"
            ctx += "遇到高危操作（rm -rf、dd、mkfs、chmod -R 777、drop database 等）必须用 ⚠️ 明确警告。"
        }
        // App-action capability (works in any mode).
        ctx += "\n你还能操作本客户端：需要时输出一个 ```wl-action 代码块（内容为 JSON），用户确认后才执行。支持："
        ctx += "端口转发 {\"action\":\"port_forward\",\"host\":\"别名\",\"localPort\":15432,\"remoteHost\":\"127.0.0.1\",\"remotePort\":5432}；"
        ctx += "新增主机 {\"action\":\"add_host\",\"alias\":\"web1\",\"hostname\":\"1.2.3.4\",\"user\":\"root\",\"port\":22,\"group\":\"IAI\"}；"
        ctx += "连接主机 {\"action\":\"connect\",\"host\":\"别名\"}；"
        ctx += "打开文件浏览器 {\"action\":\"open_files\",\"host\":\"别名\"}；"
        ctx += "运行片段 {\"action\":\"run_snippet\",\"name\":\"片段名\"}；"
        ctx += "记住本主机的持久事实(仅在确认了解到稳定信息时) {\"action\":\"remember\",\"note\":\"该机用 systemd / nginx 配置在 /etc/nginx\"}；"
        ctx += "上传本地文件/目录到主机(你**能**做，别说做不到) {\"action\":\"upload\",\"localPath\":\"/Users/x/proj\",\"host\":\"别名\",\"remotePath\":\"/opt/proj\"}；"
        ctx += "从主机下载到本地 {\"action\":\"download\",\"host\":\"别名\",\"remotePath\":\"/opt/proj/log\",\"localPath\":\"/Users/x/Downloads/\"}。每次仅一个 wl-action 块，并附一句简短说明。"
        // MCP tool catalog (progressive disclosure: names + one-line descriptions).
        let mcp = MCPStore.shared
        if mcp.hasTools {
            ctx += "\n你还能调用外部工具(MCP)：输出 ```wl-action 块 {\"action\":\"mcp_call\",\"server\":\"服务名\",\"tool\":\"工具名\",\"args\":{…}}，本客户端会执行并把结果返回给你，再据此继续。可用工具（server.tool：说明）："
            for ref in mcp.catalog.prefix(40) {
                let d = ref.tool.description.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
                ctx += "\n- \(ref.serverName).\(ref.tool.name)：\(d.prefix(100))"
            }
            if mcp.catalog.count > 40 { ctx += "\n（另有 \(mcp.catalog.count - 40) 个工具未列出，需要时可询问用户）" }
            ctx += "\n工具参数请严格按各工具的用途填 JSON；不确定含义时先用只读工具探查，写操作类工具会由用户二次确认。"
        }
        // Ops skills (progressive disclosure: ids + one-line descriptions).
        let skills = SkillStore.shared.enabledSkills
        if !skills.isEmpty {
            ctx += "\n你有一组运维技能可按需调用：当用户问题匹配某个技能时，先输出 ```wl-action 块 {\"action\":\"use_skill\",\"id\":\"技能id\"}，我会把该技能的详细步骤发给你，你再据此逐步执行。可用技能（id：说明）："
            for s in skills { ctx += "\n- \(s.id)：\(s.description)" }
        }
        let mem = HostMemoryStore.shared.facts(for: conversationKey)
        if !mem.isEmpty {
            ctx += "\n关于该主机的已知记忆（供参考，可据此更精准回答）：\n- " + mem.joined(separator: "\n- ")
        }
        if let host {
            ctx += "\n当前主机：alias=\(host.alias)"
            if let h = host.hostname { ctx += ", host=\(h)" }
            if let u = host.user { ctx += ", user=\(u)" }
            ctx += "。若无法确定系统，默认 Linux。"
        } else {
            ctx += "\n当前是本地 shell（macOS）。"
        }
        // Multi-host: list the other connected sessions so the assistant knows it
        // can reason across them. Command execution is targeted manually by the
        // user (the Run button offers a per-host menu), so proposed commands should
        // note which host they're meant for when it isn't the current one.
        let others = sessions.sessions.filter { $0.isRunning && $0.alias != host?.alias && !$0.alias.isEmpty }
        if !others.isEmpty {
            ctx += "\n另外还连接着这些主机（用户可用 @别名 引用其输出，并在“运行”菜单里选择在哪台执行）："
            ctx += others.map(\.alias).joined(separator: "、")
            ctx += "。跨主机操作时，请在命令说明里点明目标主机。"
        }
        return ctx
    }
}

/// One chat message. Assistant messages are split into prose + fenced code
/// blocks; each code block gets an "insert into terminal" button.
// Geometry probes for scroll-follow tracking in the conversation view.
private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
private struct ContentTopKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
private struct ViewportHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct MessageBubble: View {
    let message: AIMessage
    let session: TerminalSession?
    /// Connected sessions a proposed command can be run on (active first). When
    /// more than one, the Run button becomes a per-host menu.
    var runTargets: [TerminalSession] = []
    let loc: Localizer
    let fontSize: Double
    var onSave: (String) -> Void = { _ in }
    var onAction: (WLAction) -> Void = { _ in }
    var onCopy: (String) -> Void = { _ in }
    var onRetry: (String) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch message.role {
            case .user:
                // Your turn: a tinted bubble on the right.
                HStack(spacing: 0) {
                    Spacer(minLength: 36)
                    Text(message.content)
                        .font(WL.mono(fontSize)).foregroundStyle(WL.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(WL.green.opacity(WL.isLight ? 0.12 : 0.14),
                                    in: RoundedRectangle(cornerRadius: WL.radius(14), style: .continuous))
                }
                HStack(spacing: 6) {
                    Spacer()
                    BracketButton(loc.t("复制", "Copy")) { onCopy(message.content) }
                    BracketButton(loc.t("重试", "Retry")) { onRetry(message.content) }
                }
            case .system:
                // Agent execution trace: the run command (▶︎ …) and its output.
                Text(message.content)
                    .font(WL.mono(fontSize - 1)).foregroundStyle(WL.textDim)
                    .textSelection(.enabled)
                    .padding(.leading, 14).padding(.trailing, 10).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(WL.textPrimary.opacity(WL.isLight ? 0.035 : 0.045),
                                in: RoundedRectangle(cornerRadius: WL.radius(10), style: .continuous))
                    .overlay(alignment: .leading) {
                        Capsule().fill(WL.green.opacity(0.5)).frame(width: 3).padding(.vertical, 8).padding(.leading, 5)
                    }
            case .assistant:
                ForEach(Array(segments(message.content).enumerated()), id: \.offset) { _, seg in
                    if seg.isCode {
                        // `wl-action` JSON is rendered as a card instead; a block
                        // tagged as anything other than a shell (text/json/log/a
                        // config file) is quoted content, so it gets no Run button.
                        if !isActionJSON(seg.text) { codeBlock(seg.text, runnable: seg.isShell) }
                    } else {
                        prose(seg.text)
                    }
                }
                if let action = WLAction.parse(from: message.content) {
                    ActionCardView(action: action, loc: loc, onConfirm: onAction)
                }
            }
        }
    }

    private func prose(_ text: String) -> some View {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return Group {
            if trimmed.isEmpty { EmptyView() }
            else {
                Text(.init(trimmed))   // basic markdown (bold/inline code)
                    .font(WL.mono(fontSize)).foregroundStyle(WL.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func codeBlock(_ code: String, runnable: Bool) -> some View {
        let cmd = code.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 6) {
            Text(cmd)
                .font(WL.mono(fontSize)).foregroundStyle(runnable ? WL.green : WL.textDim)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if runnable {
                HStack(spacing: 6) {
                    Spacer()
                    BracketButton(loc.t("存片段", "Save")) { onSave(cmd) }
                    if let session {
                        BracketButton(loc.t("插入", "Insert")) { session.insertIntoTerminal(cmd) }
                        if runTargets.count > 1 {
                            // Multiple hosts connected: pick which one to run on.
                            Menu {
                                ForEach(runTargets) { t in
                                    Button(t.title) { t.runInTerminal(cmd) }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(loc.t("运行", "Run"))
                                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
                                }
                            }
                            .menuStyle(.button).buttonStyle(.wlChip()).menuIndicator(.hidden).fixedSize()
                            .help(loc.t("选择要运行的主机", "Choose a host to run on"))
                        } else {
                            BracketButton(loc.t("运行", "Run")) { session.runInTerminal(cmd) }
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(WL.textPrimary.opacity(WL.isLight ? 0.04 : 0.06),
                    in: RoundedRectangle(cornerRadius: WL.radius(10), style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: WL.radius(10), style: .continuous)
            .strokeBorder(WL.hairline, lineWidth: 1))
    }

    /// Whether a code segment is a wl-action JSON payload (rendered as a card).
    private func isActionJSON(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("{") && t.contains("\"action\"")
    }

    /// Split content into prose and fenced-code segments, carrying each block's
    /// language so the view can tell a command from quoted output.
    private func segments(_ s: String) -> [(isCode: Bool, isShell: Bool, text: String)] {
        var result: [(Bool, Bool, String)] = []
        var lang: String?
        var buffer: [String] = []
        func flush(code: Bool) {
            let text = buffer.joined(separator: "\n")
            buffer = []
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            result.append((code, code && AICodeFence.shellLangs.contains(lang ?? ""), text))
        }
        for line in s.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if lang != nil {
                    flush(code: true)
                    lang = nil
                } else {
                    let opened = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces).lowercased()
                    flush(code: false)
                    lang = opened
                }
            } else {
                buffer.append(line)
            }
        }
        // An unterminated fence: the reply is still streaming in.
        flush(code: lang != nil)
        return result
    }
}
