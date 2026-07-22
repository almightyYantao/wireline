import SwiftUI
import WirelineCore

/// Drives the prompt-inline AI command flow for one terminal session — the
/// Aliyun-ECS-assistant-style interaction: you type a natural-language request at
/// the prompt (via ⌘; or a `# …` comment line), the model replies inline with a
/// short explanation and a single proposed command, and you 执行 / 修改 / 拒绝 it.
///
/// It intentionally reuses the app's existing `AIClient` / `AIConfig`. The model
/// is asked to return either a one-line explanation followed by a single fenced
/// command, or — when the request is too vague — a brief clarifying question with
/// no command, which keeps the input open for a follow-up (multi-turn).
@Observable
@MainActor
final class InlineAIController {
    /// Whether the inline card is showing at all.
    var active = false
    /// A request is in flight (streaming) — show the "thinking" state.
    var thinking = false
    /// The natural-language request being typed / just sent.
    var query = ""
    /// The model's short explanation shown above the command.
    var explanation = ""
    /// The proposed command (empty while clarifying or thinking).
    var command = ""
    /// The model asked a clarifying question instead of proposing a command, so
    /// the input stays open for the user's answer.
    var clarifying = false
    /// The command box is in edit mode (the user hit 修改 to tweak before running).
    var editing = false
    /// A transient error to surface in the card.
    var errorText: String?

    /// Multi-turn context for this inline conversation.
    private var transcript: [AIMessage] = []
    private var task: Task<Void, Never>?
    weak var session: TerminalSession?

    private var ai: AIConfig { AIConfig.shared }

    // MARK: - Entry points

    /// Open the inline input at the prompt. With `prefill`, submit it immediately
    /// (used by the `# …` comment trigger, which already has the full request).
    func activate(prefill: String? = nil) {
        guard ai.isConfigured else { return }
        active = true
        errorText = nil
        if let prefill, !prefill.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            query = prefill
            submit()
        }
    }

    /// ⌘; behaviour: run a ready command, else open / focus the input.
    func trigger() {
        if active, !command.isEmpty, !thinking { execute(); return }
        if !active { activate() }
    }

    // MARK: - Conversation

    func submit() {
        let nl = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nl.isEmpty, !thinking, let session else { return }
        thinking = true
        errorText = nil
        command = ""
        explanation = ""
        clarifying = false
        editing = false

        transcript.append(AIMessage(role: .user, content: contextualize(nl, session: session)))
        query = ""

        let client = AIClient(config: ai)
        let model = ai.hasFastModel ? ai.activeModelFast : nil
        let sys = systemPrompt(session: session)
        let msgs = transcript
        task = Task { [weak self] in
            var text = ""
            do {
                for try await d in client.stream(system: sys, messages: msgs, model: model) { text += d }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.thinking = false
                    self.errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
                return
            }
            await MainActor.run { self?.finish(text) }
        }
    }

    private func finish(_ raw: String) {
        thinking = false
        transcript.append(AIMessage(role: .assistant, content: raw))
        let (prose, cmd) = Self.parse(raw)
        explanation = prose
        if let cmd, !cmd.isEmpty {
            command = cmd
            clarifying = false
        } else {
            // No command → treat as a clarifying question; keep the input open.
            command = ""
            clarifying = true
        }
    }

    // MARK: - Actions

    func execute() {
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty, let session else { return }
        session.runInTerminal(cmd)
        close()
    }

    /// Put the command into an editable field so the user can tweak it before
    /// running (Return in the field then executes).
    func edit() {
        guard !command.isEmpty else { return }
        editing = true
    }

    /// Discard the current proposal and close the card without running anything.
    func reject() { close() }

    func cancel() { close() }

    private func close() {
        task?.cancel()
        task = nil
        active = false
        thinking = false
        query = ""
        command = ""
        explanation = ""
        clarifying = false
        editing = false
        errorText = nil
        transcript.removeAll()
    }

    // MARK: - Prompt building & parsing

    private func systemPrompt(session: TerminalSession) -> String {
        var s = """
        你是终端命令助手。用户会用自然语言描述一个任务，你的工作是给出一条可直接执行的 shell 命令。
        规则：
        1. 如果需求清晰：先用一句话（不超过 40 字）说明这条命令做什么、为什么这么写，然后另起一行，把命令放进单个 ``` 代码块里。只给一条命令，不要多条、不要额外解释。
        2. 如果需求太模糊、无法安全地给出单条命令：不要给命令，直接用一句话反问澄清（不要代码块）。
        3. 用户用中文就用中文回答，用英文就用英文。
        """
        switch session.kind {
        case .ssh, .sftp:
            s += "\n当前是通过 SSH 连接的远程主机 \(session.alias)（默认 Linux）。"
        case .localShell:
            s += "\n当前是本地 macOS shell。"
        }
        if let dir = session.currentDirectory { s += "\n当前工作目录：\(dir)。" }
        return s
    }

    /// Fold the recent terminal output into the user's request as context (redacted
    /// when the user has that enabled). Only the first turn carries the transcript
    /// of screen output; follow-ups are just the user's answer.
    private func contextualize(_ nl: String, session: TerminalSession) -> String {
        guard transcript.isEmpty else { return nl }   // follow-up: no need to re-send context
        let out = String(session.recentOutput.suffix(1500))
        let ctx = ai.redact ? AIRedactor.redact(out) : out
        return "终端最近内容（供参考）：\n\(ctx)\n\n需求：\(nl)"
    }

    /// Split a reply into (explanation, command). The command is the first fenced
    /// block, with an optional language hint line stripped; returns nil command
    /// when there's no fence (a clarifying question).
    static func parse(_ raw: String) -> (String, String?) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let open = text.range(of: "```") else { return (text, nil) }
        let prose = String(text[..<open.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let afterOpen = text[open.upperBound...]
        let close = afterOpen.range(of: "```")
        var body = close.map { String(afterOpen[..<$0.lowerBound]) } ?? String(afterOpen)
        // Drop an optional leading language hint (e.g. "bash\n").
        if let nl = body.firstIndex(of: "\n") {
            let first = body[body.startIndex..<nl].trimmingCharacters(in: .whitespaces)
            if first.range(of: #"^[A-Za-z0-9_+-]{1,15}$"#, options: .regularExpression) != nil {
                body = String(body[body.index(after: nl)...])
            }
        }
        let cmd = body.trimmingCharacters(in: CharacterSet(charactersIn: "`\n \t"))
        // Keep the first non-empty line — we only ever run a single command.
        let oneLine = cmd.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .first.map(String.init) ?? cmd
        return (prose, oneLine)
    }
}

/// The inline card pinned to the bottom of the terminal — the Aliyun-style
/// request echo + explanation + command box with 执行 / 修改 / 拒绝.
struct InlineAICommandView: View {
    @Environment(Localizer.self) private var loc
    let session: TerminalSession
    /// Whether this session is the focused one (so ⌘; targets it).
    var isActive: Bool

    @FocusState private var inputFocused: Bool
    @FocusState private var editFocused: Bool

    private var c: InlineAIController { session.inlineAI }

    var body: some View {
        // The overlay is a no-op (fully transparent, non-interactive) until the
        // controller is active, so it never steals terminal clicks otherwise.
        Group {
            if c.active {
                card
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.15), value: c.active)
        .animation(.easeOut(duration: 0.15), value: c.thinking)
        .animation(.easeOut(duration: 0.15), value: c.command)
        // ⌘; anywhere in the (active) terminal activates / runs.
        .onReceive(NotificationCenter.default.publisher(for: .suggestCommand)) { _ in
            guard isActive else { return }
            c.trigger()
            if c.active, c.command.isEmpty { inputFocused = true }
        }
        .onChange(of: c.active) { _, now in
            if now, c.command.isEmpty { DispatchQueue.main.async { inputFocused = true } }
        }
        .onChange(of: c.thinking) { _, now in
            // Streaming just finished with a clarifying question (no command) —
            // put the caret back in the input for the follow-up answer.
            if !now, c.active, c.command.isEmpty { DispatchQueue.main.async { inputFocused = true } }
        }
        .onChange(of: c.editing) { _, now in
            if now { DispatchQueue.main.async { editFocused = true } }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The echoed request line (Aliyun shows it in blue at the prompt).
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 11))
                    .foregroundStyle(c.thinking ? WL.amber : WL.teal)
                if c.command.isEmpty && !c.thinking {
                    // Awaiting input (initial request or a clarifying follow-up).
                    TextField(loc(c.clarifying ? "回答后回车…" : "描述要做什么，回车生成命令…",
                                  c.clarifying ? "answer, then Return…" : "describe a task, Return…"),
                              text: Binding(get: { c.query }, set: { c.query = $0 }))
                        .textFieldStyle(.plain).font(WL.mono(12)).foregroundStyle(WL.teal)
                        .focused($inputFocused)
                        .onSubmit { c.submit() }
                        .onExitCommand { c.cancel() }
                } else {
                    Text(c.thinking ? loc("AI 正在思考…", "AI is thinking…")
                                    : loc("已生成命令", "Command ready"))
                        .font(WL.mono(12)).foregroundStyle(WL.textDim)
                    Spacer()
                }
            }

            if let err = c.errorText {
                Text(err).font(WL.small).foregroundStyle(WL.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Explanation prose (the "why" line), shown once we have a reply.
            if !c.explanation.isEmpty {
                Text(.init(c.explanation))
                    .font(WL.mono(12)).foregroundStyle(WL.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // The proposed command + actions.
            if !c.command.isEmpty {
                commandBox
                HStack(spacing: 12) {
                    Spacer()
                    actionButton(loc("执行", "Run"), "⌘↩") { c.execute() }
                        .keyboardShortcut(.return, modifiers: .command)
                    actionButton(loc("修改", "Edit"), "⌘E") { c.edit() }
                        .keyboardShortcut("e", modifiers: .command)
                    actionButton(loc("拒绝", "Reject"), "⌘⌫") { c.reject() }
                        .keyboardShortcut(.delete, modifiers: .command)
                }
            }
        }
        .padding(12)
        .background(WL.bg.opacity(0.96), in: RoundedRectangle(cornerRadius: WL.radius(8)))
        .overlay(RoundedRectangle(cornerRadius: WL.radius(8))
            .stroke(WL.teal.opacity(0.5), lineWidth: WL.borderWidth))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
    }

    @ViewBuilder
    private var commandBox: some View {
        if c.editing {
            TextField("", text: Binding(get: { c.command }, set: { c.command = $0 }), axis: .vertical)
                .textFieldStyle(.plain).font(WL.mono(13)).foregroundStyle(WL.greenBright)
                .focused($editFocused)
                .onSubmit { c.execute() }
                .onExitCommand { c.editing = false }
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(WL.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: WL.radius(6)))
                .overlay(RoundedRectangle(cornerRadius: WL.radius(6)).stroke(WL.green.opacity(0.6), lineWidth: WL.borderWidth))
        } else {
            Text(c.command)
                .font(WL.mono(13)).foregroundStyle(WL.green)
                .textSelection(.enabled)
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(WL.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: WL.radius(6)))
                .overlay(RoundedRectangle(cornerRadius: WL.radius(6)).stroke(WL.border, lineWidth: WL.borderWidth))
        }
    }

    private func actionButton(_ label: String, _ key: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(label).font(WL.small.weight(.semibold))
                Text(key).font(WL.caption).foregroundStyle(WL.textDim)
            }
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(WL.surface.opacity(0.8), in: RoundedRectangle(cornerRadius: WL.radius(5)))
            .overlay(RoundedRectangle(cornerRadius: WL.radius(5)).stroke(WL.border, lineWidth: WL.borderWidth))
        }
        .buttonStyle(.plain)
    }
}
