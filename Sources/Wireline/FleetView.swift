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
        WLSheet(loc("舰队群跑", "Fleet Run"),
                subtitle: loc("用自然语言描述目标，AI 生成一条命令，在选中的主机上并行执行并汇总",
                              "Describe a goal, let the AI write one command, run it on many hosts in parallel"),
                symbol: "square.grid.3x3.fill", width: 840, height: 640, scrolls: false,
                onClose: onClose) {
            HStack(alignment: .top, spacing: 16) {
                hostPicker
                    .frame(width: 230)
                    .frame(maxHeight: .infinity)
                    .wlCard()
                main
            }
            .frame(maxHeight: .infinity)
        } footer: {
            if !results.isEmpty {
                Button(summarizing ? loc("汇总中…", "Summarizing…") : loc("AI 汇总", "Summarize")) { summarize() }
                    .buttonStyle(.wlSecondary)
                    .disabled(summarizing || !ai.isConfigured)
            }
            if running { Text(loc("执行中…", "Running…")).font(WL.small).foregroundStyle(WL.amber) }
            Spacer()
            Button(loc("关闭", "Close"), action: onClose)
                .buttonStyle(.wlSecondary).keyboardShortcut(.cancelAction)
            // No Return shortcut: Return in the goal field generates, and running
            // on a whole fleet should always be a deliberate click.
            Button(loc("在 \(selected.count) 台执行", "Run on \(selected.count)"), action: runFleet)
                .buttonStyle(.wlPrimary)
                .disabled(!canRun)
        }
        .onDisappear { task?.cancel() }
    }

    // MARK: hosts

    private var hostPicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(loc("目标主机 (\(selected.count))", "Targets (\(selected.count))"))
                    .font(WL.small.weight(.semibold)).foregroundStyle(WL.textPrimary)
                Spacer()
                BracketButton(selected.count == store.hosts.count ? loc("清空", "None") : loc("全选", "All")) {
                    if selected.count == store.hosts.count { selected.removeAll() }
                    else { selected = Set(store.hosts.map(\.alias)) }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            WLFormDivider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(store.hosts) { host in
                        Toggle(isOn: Binding(get: { selected.contains(host.alias) },
                                             set: { _ in toggle(host.alias) })) {
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(host.alias).font(WL.small).foregroundStyle(WL.textPrimary)
                                    if let g = host.group {
                                        Text(g).font(WL.caption).foregroundStyle(WL.textDim)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                        }
                        .toggleStyle(.wlCheckbox)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func toggle(_ alias: String) {
        if selected.contains(alias) { selected.remove(alias) } else { selected.insert(alias) }
    }

    // MARK: main

    private var main: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(loc("目标（自然语言）", "Goal (natural language)")).font(WL.small).foregroundStyle(WL.textDim)
                HStack(spacing: 8) {
                    TextField(loc("例如：检查磁盘和内存使用率", "e.g. check disk & memory usage"), text: $goal)
                        .wlField(font: WL.body)
                        .onSubmit { generate() }
                    BracketButton(generating ? loc("生成中", "…") : loc("生成命令", "Generate")) { generate() }
                        .disabled(generating || !ai.isConfigured)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(loc("将执行的命令（可编辑）", "Command to run (editable)")).font(WL.small).foregroundStyle(WL.textDim)
                TextField("df -h; free -h", text: $command)
                    .foregroundStyle(WL.green)
                    .wlField()
            }

            if AICommandSafety.isDangerous(command) {
                Text(loc("⚠️ 命令疑似高危，将在所有选中主机执行，请确认后再运行。",
                        "⚠️ This looks risky and will run on every selected host — double-check."))
                    .font(WL.caption).foregroundStyle(WL.red)
            }

            resultsList
        }
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
                        .background(WL.green.opacity(0.1), in: RoundedRectangle(cornerRadius: WL.radius(10), style: .continuous))
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
                    .wlCard(radius: 10)
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
        // The run shows on the notch island too: n/total, failures, a pulse at the end.
        let islandID = "fleet:\(UUID().uuidString)"
        let island = IslandCenter.shared
        island.fleetStarted(islandID, command: cmd, total: hosts.count)
        var done = 0, failed = 0
        task = Task {
            let r = await FleetRunner.run(command: cmd, on: hosts) { one in
                done += 1
                if !one.ok { failed += 1 }
                island.fleetProgress(islandID, done: done, failed: failed)
            }
            await MainActor.run {
                results = r; running = false
                island.fleetFinished(islandID, total: hosts.count, failed: r.filter { !$0.ok }.count)
            }
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
