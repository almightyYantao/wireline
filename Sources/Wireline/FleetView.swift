import SwiftUI
import WirelineCore

/// Fleet mode: pick many hosts, describe a goal, let the AI turn it into one
/// command, run it across all hosts in parallel, and aggregate the results.
struct FleetView: View {
    @Environment(HostStore.self) private var store
    @Environment(Localizer.self) private var loc
    @State private var ai = AIConfig.shared
    var onClose: () -> Void

    @State private var selected: Set<String> = []
    @State private var goal = ""
    @State private var command = ""
    @State private var generating = false
    @State private var running = false
    @State private var results: [FleetResult] = []
    @State private var summary = ""
    @State private var summarizing = false
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(WL.border).frame(height: 1)
            HStack(spacing: 0) {
                hostPicker.frame(width: 240)
                Rectangle().fill(WL.border).frame(width: 1)
                main
            }
        }
        .frame(width: 840, height: 640)
        .background(WL.bg)
        .preferredColorScheme(.dark)
        .onDisappear { task?.cancel() }
    }

    private var header: some View {
        HStack {
            Image(systemName: "square.grid.3x3.fill").foregroundStyle(WL.green)
            Text(loc("舰队群跑", "Fleet Run")).font(WL.body.weight(.semibold)).foregroundStyle(WL.textPrimary)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(WL.textDim)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 12)
    }

    // MARK: hosts

    private var hostPicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(loc("目标主机 (\(selected.count))", "Targets (\(selected.count))"))
                    .font(WL.small.weight(.semibold)).foregroundStyle(WL.green)
                Spacer()
                BracketButton(selected.count == store.hosts.count ? loc("清空", "None") : loc("全选", "All")) {
                    if selected.count == store.hosts.count { selected.removeAll() }
                    else { selected = Set(store.hosts.map(\.alias)) }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Rectangle().fill(WL.border).frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(store.hosts) { host in
                        Button { toggle(host.alias) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: selected.contains(host.alias) ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(selected.contains(host.alias) ? WL.green : WL.textDim)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(host.alias).font(WL.small).foregroundStyle(WL.textPrimary)
                                    if let g = host.group {
                                        Text(g).font(WL.caption).foregroundStyle(WL.textDim)
                                    }
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 14).padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func toggle(_ alias: String) {
        if selected.contains(alias) { selected.remove(alias) } else { selected.insert(alias) }
    }

    // MARK: main

    private var main: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(loc("目标（自然语言）", "Goal (natural language)")).font(WL.small).foregroundStyle(WL.textDim)
            HStack(spacing: 8) {
                TextField(loc("例如：检查磁盘和内存使用率", "e.g. check disk & memory usage"), text: $goal)
                    .textFieldStyle(.plain).font(WL.body).foregroundStyle(WL.textPrimary)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(WL.surface, in: RoundedRectangle(cornerRadius: WL.radius(5)))
                    .overlay(RoundedRectangle(cornerRadius: WL.radius(5)).stroke(WL.border, lineWidth: WL.borderWidth))
                    .onSubmit { generate() }
                BracketButton(generating ? loc("生成中", "…") : loc("生成命令", "Generate")) { generate() }
                    .disabled(generating || !ai.isConfigured)
            }

            Text(loc("将执行的命令（可编辑）", "Command to run (editable)")).font(WL.small).foregroundStyle(WL.textDim)
            TextField("df -h; free -h", text: $command)
                .textFieldStyle(.plain).font(WL.mono(12)).foregroundStyle(WL.green)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(WL.surface, in: RoundedRectangle(cornerRadius: WL.radius(5)))
                .overlay(RoundedRectangle(cornerRadius: WL.radius(5)).stroke(WL.border, lineWidth: WL.borderWidth))

            HStack {
                Button(action: runFleet) {
                    Text("[\(loc("在 \(selected.count) 台执行", "Run on \(selected.count)"))]")
                        .font(WL.small).foregroundStyle(canRun ? WL.green : WL.textDim)
                }.buttonStyle(.plain).disabled(!canRun)
                if running { Text(loc("执行中…", "Running…")).font(WL.small).foregroundStyle(WL.amber) }
                Spacer()
                if !results.isEmpty {
                    BracketButton(summarizing ? loc("汇总中", "…") : loc("AI 汇总", "Summarize")) { summarize() }
                        .disabled(summarizing || !ai.isConfigured)
                }
            }

            if AICommandSafety.isDangerous(command) {
                Text(loc("⚠️ 命令疑似高危，将在所有选中主机执行，请确认后再运行。",
                        "⚠️ This looks risky and will run on every selected host — double-check."))
                    .font(WL.caption).foregroundStyle(WL.red)
            }

            resultsList
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var canRun: Bool {
        !command.trimmingCharacters(in: .whitespaces).isEmpty && !selected.isEmpty && !running
    }

    private var resultsList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if !summary.isEmpty {
                    Text(.init(summary))
                        .font(WL.small).foregroundStyle(WL.textPrimary)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(WL.green.opacity(0.1), in: RoundedRectangle(cornerRadius: WL.radius(6)))
                        .textSelection(.enabled)
                }
                ForEach(results) { r in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Circle().fill(r.ok ? WL.green : WL.red).frame(width: 7, height: 7)
                            Text(r.alias).font(WL.small.weight(.semibold)).foregroundStyle(WL.textPrimary)
                            Spacer()
                            Text(r.ok ? loc("成功", "ok") : loc("退出码 \(r.exitCode)", "exit \(r.exitCode)"))
                                .font(WL.caption).foregroundStyle(r.ok ? WL.textDim : WL.red)
                        }
                        Text(r.output.isEmpty ? "(无输出)" : r.output)
                            .font(WL.mono(11)).foregroundStyle(WL.textDim)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .padding(9)
                    .background(WL.surface.opacity(0.4), in: RoundedRectangle(cornerRadius: WL.radius(6)))
                    .overlay(RoundedRectangle(cornerRadius: WL.radius(6)).stroke(WL.border, lineWidth: WL.borderWidth))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: actions

    private func generate() {
        let g = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !g.isEmpty, !generating else { return }
        generating = true
        let client = AIClient(config: ai)
        let model = ai.hasFastModel ? ai.activeModelFast : nil
        let sys = "你是运维助手。把需求转成一条可在多台 Linux 主机上安全执行的 shell 命令（尽量只读、幂等）；只输出命令本身，不要解释、代码块或反引号。"
        let msg = AIMessage(role: .user, content: "需求：\(g)")
        task = Task {
            var text = ""
            do { for try await d in client.stream(system: sys, messages: [msg], model: model) { text += d } }
            catch { await MainActor.run { generating = false }; return }
            await MainActor.run {
                command = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "```", with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "`\n "))
                generating = false
            }
        }
    }

    private func runFleet() {
        guard canRun else { return }
        running = true
        summary = ""
        results = []
        let cmd = command
        let hosts = store.hosts.map(\.alias).filter { selected.contains($0) }
        task = Task {
            let r = await FleetRunner.run(command: cmd, on: hosts)
            await MainActor.run { results = r; running = false }
        }
    }

    private func summarize() {
        guard !results.isEmpty, !summarizing else { return }
        summarizing = true
        let client = AIClient(config: ai)
        let joined = results.map { "### \($0.alias) (exit \($0.exitCode))\n\($0.output)" }.joined(separator: "\n\n")
        let ctx = ai.redact ? AIRedactor.redact(joined) : joined
        let sys = "你是运维助手。根据多台主机执行同一命令的结果，用中文给出简明汇总：整体结论、异常/需要关注的主机（点名），必要时用简单表格或列表。"
        let msg = AIMessage(role: .user, content: "命令：\(command)\n\n各主机结果：\n\(String(ctx.suffix(8000)))")
        task = Task {
            var text = ""
            do { for try await d in client.stream(system: sys, messages: [msg]) { text += d } }
            catch { await MainActor.run { summarizing = false }; return }
            await MainActor.run { summary = text; summarizing = false }
        }
    }
}
