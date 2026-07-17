import SwiftUI

/// Edit a remote config file with a natural-language instruction: read the file,
/// ask the model to return the full modified content, preview it (editable), then
/// write it back over SFTP. Nothing is written until the user confirms.
struct AIFileEditView: View {
    @Environment(Localizer.self) private var loc
    @State private var ai = AIConfig.shared
    let model: FileBrowserModel
    let entry: SFTPEntry
    let hostName: String
    var onClose: () -> Void

    @State private var original = ""
    @State private var instruction = ""
    @State private var edited = ""
    @State private var loading = true
    @State private var generating = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var reviewText = ""
    @State private var reviewing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "sparkles").foregroundStyle(WL.green)
                Text(loc("AI 改文件 · \(entry.name)", "AI edit · \(entry.name)"))
                    .font(WL.body.weight(.semibold)).foregroundStyle(WL.textPrimary)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(WL.textDim)
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 12)
            Rectangle().fill(WL.border).frame(height: 1)

            if !ai.isConfigured {
                notice(loc("尚未配置 AI，请到 设置 → AI。", "Configure AI first in Settings → AI."))
            } else if loading {
                notice(loc("读取文件中…", "Reading file…"))
            } else {
                content
            }
        }
        .frame(width: 640, height: 560)
        .background(WL.bg)
        .preferredColorScheme(.dark)
        .onAppear { loadFile() }
        .onDisappear { task?.cancel() }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(loc("修改指令", "Instruction")).font(WL.small).foregroundStyle(WL.textDim)
            HStack(spacing: 8) {
                TextField(loc("例如：把超时改成 30s；关闭 gzip", "e.g. set timeout to 30s"),
                          text: $instruction)
                    .textFieldStyle(.plain).font(WL.body).foregroundStyle(WL.textPrimary)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(WL.surface, in: RoundedRectangle(cornerRadius: WL.radius(5)))
                    .overlay(RoundedRectangle(cornerRadius: WL.radius(5)).stroke(WL.border, lineWidth: WL.borderWidth))
                    .onSubmit { generate() }
                if generating {
                    Button { task?.cancel(); generating = false } label: {
                        Image(systemName: "stop.fill").foregroundStyle(WL.red)
                    }.buttonStyle(.plain)
                } else {
                    BracketButton(loc("生成", "Generate")) { generate() }
                }
            }
            if let error { Text(error).font(WL.caption).foregroundStyle(WL.red) }

            Text(edited.isEmpty ? loc("原内容", "Original") : loc("修改后（可再编辑）", "Modified (editable)"))
                .font(WL.small).foregroundStyle(WL.textDim)
            TextEditor(text: edited.isEmpty ? .constant(original) : $edited)
                .textEditorStyle(.plain).font(WL.mono(12)).foregroundStyle(WL.textPrimary)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(WL.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: WL.radius(6)))
                .overlay(RoundedRectangle(cornerRadius: WL.radius(6)).stroke(WL.border, lineWidth: WL.borderWidth))

            if reviewing || !reviewText.isEmpty {
                Text(loc("变更评审（影响与风险）", "Change review (impact & risks)"))
                    .font(WL.small).foregroundStyle(WL.amber)
                ScrollView {
                    Text(reviewText.isEmpty ? loc("评审中…", "Reviewing…") : .init(reviewText))
                        .font(WL.small).foregroundStyle(WL.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                .frame(maxHeight: 120)
                .padding(8)
                .background(WL.amber.opacity(0.08), in: RoundedRectangle(cornerRadius: WL.radius(6)))
                .overlay(RoundedRectangle(cornerRadius: WL.radius(6)).stroke(WL.amber.opacity(0.4), lineWidth: 1))
            }

            HStack {
                Spacer()
                BracketButton(loc("取消", "Cancel")) { onClose() }
                if !edited.isEmpty {
                    if reviewText.isEmpty {
                        // First step: review the change before writing.
                        BracketButton(reviewing ? loc("评审中", "…") : loc("评审并写回", "Review & write")) { reviewChange() }
                    } else {
                        Button(action: writeBack) {
                            Text("[\(loc("确认写回", "Confirm write"))]").font(WL.small).foregroundStyle(WL.green)
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(18)
    }

    /// Ask the AI to assess the diff (impact + risks) before writing it back.
    private func reviewChange() {
        guard !reviewing else { return }
        reviewing = true
        reviewText = ""
        let client = AIClient(config: ai)
        let model = ai.hasFastModel ? ai.activeModelFast : nil
        let sys = "你是配置变更评审员。对比原文件与修改后的文件，用中文简要给出：① 实际改了什么 ② 影响面/需要重启或重载的服务 ③ 风险点或需注意的地方。要精炼，分条列出。"
        let msg = AIMessage(role: .user, content: "文件：\(entry.name)\n\n原内容：\n```\n\(original)\n```\n\n修改后：\n```\n\(edited)\n```")
        task = Task {
            var text = ""
            do {
                for try await d in client.stream(system: sys, messages: [msg], model: model) { text += d }
            } catch {
                let m = error.localizedDescription
                await MainActor.run { reviewing = false; self.error = m }
                return
            }
            await MainActor.run { reviewText = text.trimmingCharacters(in: .whitespacesAndNewlines); reviewing = false }
        }
    }

    private func notice(_ text: String) -> some View {
        Text(text).font(WL.body).foregroundStyle(WL.textDim)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadFile() {
        Task {
            let text = await model.readRemoteText(entry) ?? ""
            await MainActor.run { original = text; loading = false }
        }
    }

    private func generate() {
        let instr = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instr.isEmpty, !generating else { return }
        error = nil
        generating = true
        let client = AIClient(config: ai)
        let system = "你是配置文件编辑助手。根据用户指令修改给定文件，只输出修改后的【完整文件内容】，放进一个 ``` 代码块里，不要任何解释或多余文字。保持原有格式与缩进，只做必要改动。"
        let user = AIMessage(role: .user, content: "文件名：\(entry.name)\n主机：\(hostName)\n指令：\(instr)\n\n原内容：\n```\n\(original)\n```")
        task = Task {
            var out = ""
            do {
                for try await d in client.stream(system: system, messages: [user]) { out += d }
            } catch is CancellationError {
            } catch {
                await MainActor.run { self.error = error.localizedDescription; generating = false }
                return
            }
            let newContent = extractCodeBlock(out) ?? out
            await MainActor.run { edited = newContent; generating = false }
        }
    }

    private func writeBack() {
        Task {
            let ok = await model.writeRemoteText(entry, edited)
            await MainActor.run { if ok { onClose() } else { error = loc("写回失败", "Write failed") } }
        }
    }

    /// Pull the content of the first fenced code block (dropping a language hint).
    private func extractCodeBlock(_ text: String) -> String? {
        let parts = text.components(separatedBy: "```")
        guard parts.count >= 3 else { return nil }
        var body = parts[1]
        if let nl = body.firstIndex(of: "\n") {
            let first = body[body.startIndex..<nl].trimmingCharacters(in: .whitespaces)
            if first.range(of: #"^[A-Za-z0-9_+.-]{1,20}$"#, options: .regularExpression) != nil {
                body = String(body[body.index(after: nl)...])
            }
        }
        return body.trimmingCharacters(in: .newlines)
    }
}
