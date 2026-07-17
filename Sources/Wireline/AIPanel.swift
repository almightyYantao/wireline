import SwiftUI
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
    @State private var ai = AIConfig.shared
    let session: TerminalSession?
    let host: Host?
    var onClose: () -> Void

    @State private var messages: [AIMessage] = []      // shown in the transcript
    @State private var modelMessages: [AIMessage] = []  // what the model actually sees
    @State private var input = ""
    @State private var streaming = ""
    @State private var isStreaming = false
    @State private var errorText: String?
    @State private var task: Task<Void, Never>?
    @State private var agentSteps = 0
    @State private var chats = AIChatStore.shared
    @State private var loadedKey: String?
    @State private var sessionTokens = 0
    @State private var lastPromptTokens = 0
    @State private var useFast = false
    @State private var showFleet = false
    @State private var pendingDanger: String?           // command awaiting confirmation
    @State private var dangerReview = ""                 // AI impact assessment for it
    @State private var pendingMCP: PendingMCPCall?       // MCP tool call awaiting confirmation
    @FocusState private var inputFocused: Bool

    private let maxAgentSteps = 8
    private let mcpResultCap = 4000                      // chars of tool output fed back
    // Circuit breaker: stop the agent loop when it stalls or spins.
    @State private var timeoutStreak = 0                 // consecutive capture timeouts
    @State private var lastAgentCmd: String?             // to detect an identical-command loop
    @State private var repeatStreak = 0
    private let maxTimeoutStreak = 2
    private let maxRepeatStreak = 2

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(WL.border).frame(height: 1)
            quickActions
            Rectangle().fill(WL.border).frame(height: 1)
            conversation
            Rectangle().fill(WL.border).frame(height: 1)
            inputBar
        }
        .frame(width: 380)
        .frame(maxHeight: .infinity)
        .background(WL.bg.opacity(store.terminalOpacity * WL.chromeOpacity))
        .overlay(Rectangle().stroke(WL.border, lineWidth: WL.borderWidth))
        .sheet(isPresented: $showFleet) {
            FleetView(onClose: { showFleet = false })
                .environment(store).environment(loc)
        }
        .onAppear { inputFocused = true; loadConvo() }
        .onChange(of: conversationKey) { _, _ in loadConvo() }
        .onChange(of: messages) { persistConvo() }
        .onDisappear { task?.cancel(); persistConvo() }
        .alert(loc("确认执行高危命令？", "Run this risky command?"),
               isPresented: Binding(get: { pendingDanger != nil },
                                    set: { if !$0 { pendingDanger = nil } })) {
            Button(loc("取消", "Cancel"), role: .cancel) { declineDanger() }
            Button(loc("仍然执行", "Run anyway"), role: .destructive) {
                if let c = pendingDanger { pendingDanger = nil; executeAndContinue(c) }
            }
        } message: {
            Text((pendingDanger ?? "") + (dangerReview.isEmpty ? "" : "\n\n" + dangerReview))
        }
        .alert(loc("调用外部工具？", "Call this external tool?"),
               isPresented: Binding(get: { pendingMCP != nil },
                                    set: { if !$0 { pendingMCP = nil } })) {
            Button(loc("取消", "Cancel"), role: .cancel) { declineMCP() }
            Button(loc("调用", "Call")) {
                if let p = pendingMCP { pendingMCP = nil; executeMCPAndContinue(p) }
            }
            Button(loc("始终允许并调用", "Always allow & call")) {
                if let p = pendingMCP {
                    pendingMCP = nil
                    MCPStore.shared.approve("\(p.server).\(p.tool)")
                    executeMCPAndContinue(p)
                }
            }
        } message: {
            if let p = pendingMCP {
                Text("\(p.server).\(p.tool)" + (p.argsJSON == "{}" ? "" : "\n\n" + p.argsJSON))
            }
        }
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles").font(.system(size: 13)).foregroundStyle(WL.green)
                Text(loc("AI 助手", "AI Assistant")).font(WL.body.weight(.semibold)).foregroundStyle(WL.textPrimary)
                Spacer()
                if ai.hasFastModel {
                    Button { useFast.toggle() } label: {
                        Text("\(useFast ? "[x]" : "[ ]") \(loc("快速", "Fast"))")
                            .font(WL.small).foregroundStyle(useFast ? WL.green : WL.textDim)
                    }
                    .buttonStyle(.plain)
                    .help(loc("用便宜/快速模型跑这条", "Use the fast/cheap model"))
                }
                // Bracket checkbox — matches the app's [button] motif, clearly clickable.
                Button { ai.agentMode.toggle() } label: {
                    Text("\(ai.agentMode ? "[x]" : "[ ]") \(loc("自动执行", "Agent"))")
                        .font(WL.small)
                        .foregroundStyle(ai.agentMode ? WL.green : WL.textDim)
                }
                .buttonStyle(.plain)
                .help(loc("开启后 AI 会自动执行命令并根据输出继续", "Let AI run commands and continue from their output"))
                if !messages.isEmpty {
                    BracketButton(loc("清空", "Clear")) {
                        messages.removeAll(); modelMessages.removeAll(); errorText = nil
                        sessionTokens = 0; chats.clear(conversationKey)
                    }
                }
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(WL.textDim)
                }.buttonStyle(.plain)
            }
            if sessionTokens > 0 {
                Text(usageText).font(WL.caption).foregroundStyle(WL.textDim)
            }
        }
        .padding(.horizontal, 14).padding(.top, 32).padding(.bottom, 10)
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
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }

    private func chip(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 9))
                Text(title).font(WL.caption)
            }
            .foregroundStyle(WL.textPrimary)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(WL.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: WL.radius(5)))
            .overlay(RoundedRectangle(cornerRadius: WL.radius(5)).stroke(WL.border, lineWidth: WL.borderWidth))
        }
        .buttonStyle(.plain)
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
                        MessageBubble(message: msg, session: session, loc: loc,
                                      fontSize: ai.fontSize, onSave: saveAsSnippet, onAction: executeAction)
                    }
                    if isStreaming || !streaming.isEmpty {
                        MessageBubble(message: AIMessage(role: .assistant, content: streaming.isEmpty ? "…" : streaming),
                                      session: session, loc: loc, fontSize: ai.fontSize,
                                      onSave: saveAsSnippet, onAction: { _ in })
                            .id("streaming")
                    }
                    if let errorText {
                        Text(errorText).font(WL.caption).foregroundStyle(WL.red)
                            .padding(10)
                            .background(WL.red.opacity(0.1), in: RoundedRectangle(cornerRadius: WL.radius(6)))
                    }
                    // Invisible bottom anchor: scrolling to it always sticks the
                    // view to the very bottom as content streams in / grows.
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(12)
            }
            .onChange(of: streaming) { stickToBottom(proxy) }
            .onChange(of: messages.count) { stickToBottom(proxy) }
            .onChange(of: errorText) { stickToBottom(proxy) }
            .onAppear { stickToBottom(proxy) }
        }
    }

    private func stickToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo("bottom", anchor: .bottom) }
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
                Text(loc("可用 @输出 引用终端输出、@主机 引用主机信息、@历史 引用命令历史。",
                        "Use @output, @host, or @history to inject that context."))
                    .font(WL.caption).foregroundStyle(WL.textDim)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: input

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField(loc("输入问题…", "Ask…"), text: $input, axis: .vertical)
                .textFieldStyle(.plain).font(WL.body).foregroundStyle(WL.textPrimary)
                .lineLimit(1...4)
                .focused($inputFocused)
                .onSubmit { sendFreeform() }
            if isStreaming {
                Button { task?.cancel(); isStreaming = false; agentSteps = 0 } label: {
                    Image(systemName: "stop.fill").font(.system(size: 12)).foregroundStyle(WL.red)
                }.buttonStyle(.plain)
            } else {
                Button(action: sendFreeform) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 16))
                        .foregroundStyle(input.trimmingCharacters(in: .whitespaces).isEmpty ? WL.textDim : WL.green)
                }
                .buttonStyle(.plain)
                .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    // MARK: actions

    // MARK: per-host persistence

    /// Conversation key: each host keeps its own history; local shells share one.
    private var conversationKey: String { host?.alias ?? "__local__" }

    private func loadConvo() {
        // Save the previous conversation before switching.
        if let loadedKey, loadedKey != conversationKey {
            chats.save(loadedKey, display: messages, model: modelMessages)
        }
        let convo = chats.load(conversationKey)
        messages = convo.display
        modelMessages = convo.model
        loadedKey = conversationKey
        errorText = nil
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
             promptForModel: "根据下面的终端历史，把我执行过的关键命令整理成一个可复用的 shell 脚本；把其中可变的部分（路径 / IP / 主机名 / 参数）替换成 {{参数名}} 占位符；只输出一个 ```bash 代码块，脚本第一行写注释 `# name: <简短名称>`。然后点代码块的「存片段」即可保存：\n\n\(out)")
    }

    private func makeRunbook() {
        let out = contextOutput()
        send(userVisible: loc("生成本次操作的 Runbook", "Generate a runbook for this session"),
             promptForModel: "根据下面的终端历史（命令与输出），整理成一份可复用的 Runbook，用 Markdown 输出，结构包含：## 目标 / ## 前置条件 / ## 步骤（每步：一句说明 + 对应命令放进 ```bash 块）/ ## 验证 / ## 回滚与注意。命令中可变部分用 {{参数名}} 标注。\n\n\(out)")
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
        snippets.add(Snippet(name: name, command: body))
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
            if let s = snippets.snippets.first(where: { $0.name == name })
                ?? snippets.snippets.first(where: { $0.name.localizedCaseInsensitiveContains(name) }) {
                if s.placeholders.isEmpty { session?.runInTerminal(s.command) }
                else { session?.insertIntoTerminal(s.command) }   // has placeholders: let user fill
                messages.append(AIMessage(role: .system, content: loc("✓ 已运行片段：\(s.name)", "✓ Ran snippet: \(s.name)")))
            } else {
                messages.append(AIMessage(role: .system, content: loc("未找到片段：\(name)", "Snippet not found: \(name)")))
            }
        case let .remember(note):
            HostMemoryStore.shared.add(note, for: conversationKey)
            messages.append(AIMessage(role: .system, content: loc("🧠 已记住：\(note)", "🧠 Remembered: \(note)")))
        case let .useSkill(id):
            loadSkill(id)     // inject the playbook and continue the conversation
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
        messages.append(AIMessage(role: .user, content: userVisible))
    }

    private func startTurn() {
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
        sessionTokens += lastPromptTokens + AITokenEstimator.estimate(text)
        lastPromptTokens = 0
        if !text.isEmpty {
            messages.append(AIMessage(role: .assistant, content: text))
            modelMessages.append(AIMessage(role: .assistant, content: text))
        }
        // Agent mode: if the model proposed a command or an MCP tool call, run it
        // and feed the result back.
        if ai.agentMode, agentSteps < maxAgentSteps, let cmd = firstRunnableCommand(text) {
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
        } else {
            isStreaming = false
            agentSteps = 0
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
        messages.append(AIMessage(role: .system, content: "▶︎ \(cmd)"))
        task = Task {
            let output = ai.agentInTerminal
                ? await session.runInTerminalCapturing(cmd)
                : await session.runCapturing(cmd)
            let shown = String(output.suffix(4000))
            await MainActor.run {
                messages.append(AIMessage(role: .system, content: shown))
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


    /// The first shell command inside a fenced code block, if any.
    private func firstRunnableCommand(_ text: String) -> String? {
        let parts = text.components(separatedBy: "```")
        guard parts.count >= 3 else { return nil }
        var body = parts[1]
        if let nl = body.firstIndex(of: "\n") {
            let first = body[body.startIndex..<nl].trimmingCharacters(in: .whitespaces)
            if first.range(of: #"^[A-Za-z0-9_+-]{1,15}$"#, options: .regularExpression) != nil {
                body = String(body[body.index(after: nl)...])
            }
        }
        let cmd = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return cmd.isEmpty ? nil : cmd
    }

    private func systemPrompt() -> String {
        var ctx = "你是 Wireline SSH 客户端里的终端运维助手。回答简洁、可操作，用中文。"
        if ai.agentMode {
            ctx += "【重要】你处于自动执行模式：你**有能力**执行命令——把要执行的**一条**命令放在 ```bash 代码块里，本客户端会真实执行并把输出返回给你。"
            ctx += "严禁回答“我无法执行/我不能直接运行”之类的话；需要信息就直接给出命令让系统执行。"
            ctx += "拿到输出后，继续给下一条命令，或在任务完成时用自然语言给出最终结论（结论里不要再放代码块）。"
            ctx += "优先使用只读/幂等命令；高危操作会由系统弹窗让用户二次确认，你照常给出即可。"
            if ai.agentReadOnly {
                ctx += "【只读沙盒已开启】只能执行只读/查询命令（ls、cat、ps、df、systemctl status、docker ps 等），任何写操作/删除/重启都会被系统拒绝，不要尝试。"
            }
        } else {
            ctx += "所有可直接执行的 shell 命令必须放在 ```bash 代码块里，一行一条；解释放在代码块外。"
            ctx += "遇到高危操作（rm -rf、dd、mkfs、chmod -R 777、drop database 等）必须用 ⚠️ 明确警告。"
        }
        // App-action capability (works in any mode).
        ctx += "\n你还能操作本客户端：需要时输出一个 ```wl-action 代码块（内容为 JSON），用户确认后才执行。支持："
        ctx += "端口转发 {\"action\":\"port_forward\",\"host\":\"别名\",\"localPort\":15432,\"remoteHost\":\"127.0.0.1\",\"remotePort\":5432}；"
        ctx += "新增主机 {\"action\":\"add_host\",\"alias\":\"web1\",\"hostname\":\"1.2.3.4\",\"user\":\"root\",\"port\":22,\"group\":\"IAI\"}；"
        ctx += "连接主机 {\"action\":\"connect\",\"host\":\"别名\"}；"
        ctx += "打开文件浏览器 {\"action\":\"open_files\",\"host\":\"别名\"}；"
        ctx += "运行片段 {\"action\":\"run_snippet\",\"name\":\"片段名\"}；"
        ctx += "记住本主机的持久事实(仅在确认了解到稳定信息时) {\"action\":\"remember\",\"note\":\"该机用 systemd / nginx 配置在 /etc/nginx\"}。每次仅一个 wl-action 块，并附一句简短说明。"
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
        return ctx
    }
}

/// One chat message. Assistant messages are split into prose + fenced code
/// blocks; each code block gets an "insert into terminal" button.
private struct MessageBubble: View {
    let message: AIMessage
    let session: TerminalSession?
    let loc: Localizer
    let fontSize: Double
    var onSave: (String) -> Void = { _ in }
    var onAction: (WLAction) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch message.role {
            case .user:
                Text(message.content)
                    .font(WL.mono(fontSize)).foregroundStyle(WL.textPrimary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(WL.green.opacity(0.12), in: RoundedRectangle(cornerRadius: WL.radius(6)))
            case .system:
                // Agent execution trace: the run command (▶︎ …) and its output.
                Text(message.content)
                    .font(WL.mono(fontSize - 1)).foregroundStyle(WL.textDim)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(WL.surface.opacity(0.4), in: RoundedRectangle(cornerRadius: WL.radius(6)))
                    .overlay(alignment: .leading) { Rectangle().fill(WL.green.opacity(0.5)).frame(width: 2) }
            case .assistant:
                ForEach(Array(segments(message.content).enumerated()), id: \.offset) { _, seg in
                    if seg.isCode {
                        if !isActionJSON(seg.text) { codeBlock(seg.text) }   // card handles wl-action
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

    private func codeBlock(_ code: String) -> some View {
        let cmd = code.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 6) {
            Text(cmd)
                .font(WL.mono(fontSize)).foregroundStyle(WL.green)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 12) {
                Spacer()
                BracketButton(loc.t("存片段", "Save")) { onSave(cmd) }
                if session != nil {
                    BracketButton(loc.t("插入", "Insert")) { session?.insertIntoTerminal(cmd) }
                    BracketButton(loc.t("运行", "Run")) { session?.runInTerminal(cmd) }
                }
            }
        }
        .padding(9)
        .background(WL.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: WL.radius(6)))
        .overlay(RoundedRectangle(cornerRadius: WL.radius(6)).stroke(WL.border, lineWidth: WL.borderWidth))
    }

    /// Whether a code segment is a wl-action JSON payload (rendered as a card).
    private func isActionJSON(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("{") && t.contains("\"action\"")
    }

    /// Split content on ``` fences into prose/code segments (code strips an
    /// optional leading language hint like `bash`).
    private func segments(_ s: String) -> [(isCode: Bool, text: String)] {
        let parts = s.components(separatedBy: "```")
        var result: [(Bool, String)] = []
        for (i, part) in parts.enumerated() {
            let isCode = i % 2 == 1
            if isCode {
                var body = part
                if let nl = body.firstIndex(of: "\n") {
                    let firstLine = body[body.startIndex..<nl].trimmingCharacters(in: .whitespaces)
                    if firstLine.range(of: #"^[A-Za-z0-9_+-]{1,15}$"#, options: .regularExpression) != nil {
                        body = String(body[body.index(after: nl)...])
                    }
                }
                result.append((true, body))
            } else {
                result.append((false, part))
            }
        }
        return result
    }
}
