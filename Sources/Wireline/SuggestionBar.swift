import SwiftUI
import WirelineCore

/// A thin command bar under the terminal:
/// 1. ⌘; focuses the input; type a natural-language request and press Return →
///    the AI turns it into a shell command (shown in grey).
/// 2. ⌘; again (or the Run button) executes that command in the terminal.
struct SuggestionBar: View {
    @Environment(Localizer.self) private var loc
    @State private var ai = AIConfig.shared
    let session: TerminalSession
    let host: Host?

    @State private var nlInput = ""
    @State private var command = ""
    @State private var loading = false
    @State private var task: Task<Void, Never>?
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").font(.system(size: 10))
                .foregroundStyle(loading ? WL.amber : WL.green)

            if command.isEmpty {
                TextField(loc("⌘; 输入需求，回车生成命令…", "⌘; describe a task, Return to generate…"),
                          text: $nlInput)
                    .textFieldStyle(.plain).font(WL.mono(12)).foregroundStyle(WL.textPrimary)
                    .focused($focused)
                    .onSubmit { generate() }
                if loading {
                    Text(loc("生成中…", "Generating…")).font(WL.small).foregroundStyle(WL.textDim)
                }
            } else {
                Text("→ \(command)").font(WL.mono(12)).foregroundStyle(WL.green.opacity(0.9))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                BracketButton(loc("执行 ⌘;", "Run ⌘;")) { run() }
                BracketButton(loc("插入", "Insert")) { session.insertIntoTerminal(command); command = "" }
                BracketButton("×") { command = "" }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 5)
        .background(WL.bg.opacity(0.6))
        .onReceive(NotificationCenter.default.publisher(for: .suggestCommand)) { _ in trigger() }
        .onDisappear { task?.cancel() }
    }

    /// ⌘;: run the ready command, else focus the input to type a request.
    private func trigger() {
        guard ai.isConfigured else { return }
        if !command.isEmpty { run() } else { focused = true }
    }

    private func generate() {
        let nl = nlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nl.isEmpty, !loading else { return }
        loading = true
        let client = AIClient(config: ai)
        let model = ai.hasFastModel ? ai.activeModelFast : nil
        var sys = "你是终端命令生成助手。把用户的自然语言需求转成一条可直接执行的 shell 命令，只输出命令本身，不要解释、不要代码块标记、不要反引号。"
        if let host { sys += "当前主机 \(host.alias)（默认 Linux）。" } else { sys += "当前是本地 macOS shell。" }
        let out = String(session.recentOutput.suffix(1500))
        let ctx = ai.redact ? AIRedactor.redact(out) : out
        let msg = AIMessage(role: .user, content: "终端最近内容（供参考）：\n\(ctx)\n\n需求：\(nl)")
        task = Task {
            var text = ""
            do {
                for try await d in client.stream(system: sys, messages: [msg], model: model) { text += d }
            } catch {
                await MainActor.run { loading = false }
                return
            }
            await MainActor.run {
                command = clean(text)
                nlInput = ""
                loading = false
            }
        }
    }

    private func run() {
        guard !command.isEmpty else { return }
        session.runInTerminal(command)   // execute (adds newline)
        command = ""
    }

    /// Keep the first non-empty line, strip stray fences / backticks.
    private func clean(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.replacingOccurrences(of: "```", with: "")
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "`\n "))
        return t.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).first.map(String.init) ?? t
    }
}
