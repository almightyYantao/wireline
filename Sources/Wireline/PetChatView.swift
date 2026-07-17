import SwiftUI
import AppKit
import WirelineCore

/// The desktop pet's own conversation surface — deliberately NOT the terminal AI
/// panel. You talk to it in natural language ("把 fn 机器在跑的 docker 容器总结下",
/// "把 IAI 的所有机器总结下当前的 Docker 状态"); it figures out which host(s) you
/// mean (by alias or by group), runs a command across them with `FleetRunner`
/// (non-interactive, no need to connect first), then summarizes the results.
struct PetChatView: View {
    @Environment(HostStore.self) private var store
    @Environment(Localizer.self) private var loc
    @State private var ai = AIConfig.shared
    var onClose: () -> Void

    init(onClose: @escaping () -> Void) { self.onClose = onClose }

    @State private var items: [PetChatItem] = []      // what the user sees
    @State private var modelMessages: [AIMessage] = []  // what the model sees
    @State private var input = ""
    @State private var streaming = ""
    @State private var isBusy = false
    @State private var steps = 0
    @State private var errorText: String?
    @State private var task: Task<Void, Never>?
    @State private var pendingPlan: PetPlan?           // dangerous command awaiting OK
    @State private var pendingMCP: PendingMCPCall?     // MCP tool call awaiting OK
    @FocusState private var focused: Bool

    private let maxSteps = 5
    private let mcpResultCap = 4000
    private var chats = AIChatStore.shared
    private let convoKey = "__pet__"

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(WL.border).frame(height: 1)
            conversation
            Rectangle().fill(WL.border).frame(height: 1)
            inputBar
        }
        .frame(width: 420, height: 560)
        .background(WL.bg.opacity(0.98))
        .overlay(RoundedRectangle(cornerRadius: WL.radius(10)).stroke(WL.border, lineWidth: WL.borderWidth))
        .onAppear { loadConvo(); focusSoon() }
        .onDisappear { task?.cancel(); persist() }
        .alert(loc("确认在多台机器执行高危命令？", "Run this risky command on your hosts?"),
               isPresented: Binding(get: { pendingPlan != nil }, set: { if !$0 { pendingPlan = nil } })) {
            Button(loc("取消", "Cancel"), role: .cancel) { declinePlan() }
            Button(loc("仍然执行", "Run anyway"), role: .destructive) {
                if let p = pendingPlan { pendingPlan = nil; execute(p.command, on: p.targets, intent: p.intent) }
            }
        } message: {
            if let p = pendingPlan {
                Text("\(p.command)\n\n" + loc("目标：", "Targets: ") + p.targets.joined(separator: ", "))
            }
        }
        .alert(loc("调用外部工具？", "Call this external tool?"),
               isPresented: Binding(get: { pendingMCP != nil }, set: { if !$0 { pendingMCP = nil } })) {
            Button(loc("取消", "Cancel"), role: .cancel) { declineMCP() }
            Button(loc("调用", "Call")) {
                if let p = pendingMCP { pendingMCP = nil; executeMCP(p) }
            }
            Button(loc("始终允许并调用", "Always allow & call")) {
                if let p = pendingMCP {
                    pendingMCP = nil
                    MCPStore.shared.approve("\(p.server).\(p.tool)")
                    executeMCP(p)
                }
            }
        } message: {
            if let p = pendingMCP {
                Text("\(p.server).\(p.tool)" + (p.argsJSON == "{}" ? "" : "\n\n" + p.argsJSON))
            }
        }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles").font(.system(size: 13)).foregroundStyle(WL.green)
            Text(loc("宠物助手", "Pet Assistant")).font(WL.body.weight(.semibold)).foregroundStyle(WL.textPrimary)
            Spacer()
            if !items.isEmpty {
                BracketButton(loc("清空", "Clear")) {
                    items.removeAll(); modelMessages.removeAll(); errorText = nil; chats.clear(convoKey)
                }
            }
            Button(action: onClose) {
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold)).foregroundStyle(WL.textDim)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
    }

    // MARK: conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if items.isEmpty && streaming.isEmpty { emptyState }
                    ForEach(items) { item in PetItemView(item: item, loc: loc) }
                    if isBusy || !streaming.isEmpty {
                        PetItemView(item: PetChatItem(kind: .assistant, text: streaming.isEmpty ? "…" : streaming), loc: loc)
                            .id("streaming")
                    }
                    if let errorText {
                        Text(errorText).font(WL.caption).foregroundStyle(WL.red)
                            .padding(10).background(WL.red.opacity(0.1), in: RoundedRectangle(cornerRadius: WL.radius(6)))
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(12)
            }
            .onChange(of: streaming) { stick(proxy) }
            .onChange(of: items.count) { stick(proxy) }
            .onChange(of: errorText) { stick(proxy) }
        }
    }

    private func stick(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo("bottom", anchor: .bottom) }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !ai.isConfigured {
                Text(loc("尚未配置 AI。到 设置 → AI 填写服务地址与 API Key 后即可使用。",
                        "AI isn't configured. Set the endpoint & key in Settings → AI."))
                    .font(WL.caption).foregroundStyle(WL.amber)
            } else {
                Text(loc("用大白话告诉我要在哪台/哪组机器做什么,我来跑并汇总。",
                        "Tell me what to check on which host(s) — I'll run it and summarize."))
                    .font(WL.caption).foregroundStyle(WL.textDim)
                exampleChip("把 fn 机器在跑的 docker 容器总结下", "Summarize running docker containers on fn")
                exampleChip("把 IAI 的所有机器总结下当前的 Docker 状态", "Summarize Docker status across all IAI hosts")
                exampleChip("看看 db1 的磁盘和内存够不够", "Check disk & memory on db1")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func exampleChip(_ zh: String, _ en: String) -> some View {
        let text = loc(zh, en)
        return Button { input = text; focused = true } label: {
            Text("↳ " + text).font(WL.caption).foregroundStyle(WL.green)
                .frame(maxWidth: .infinity, alignment: .leading)
        }.buttonStyle(.plain)
    }

    // MARK: input

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField(loc("要在哪台/哪组机器做什么…", "What to run, and where…"), text: $input, axis: .vertical)
                .textFieldStyle(.plain).font(WL.body).foregroundStyle(WL.textPrimary)
                .lineLimit(1...4).focused($focused)
                .onSubmit { send() }
            if isBusy {
                Button { task?.cancel(); isBusy = false; steps = 0 } label: {
                    Image(systemName: "stop.fill").font(.system(size: 12)).foregroundStyle(WL.red)
                }.buttonStyle(.plain)
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 16))
                        .foregroundStyle(canSend ? WL.green : WL.textDim)
                }.buttonStyle(.plain).disabled(!canSend)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private var canSend: Bool { !input.trimmingCharacters(in: .whitespaces).isEmpty && !isBusy && ai.isConfigured }

    /// Focus the input after the window has settled into key state — setting
    /// `@FocusState` immediately on appear doesn't stick because the floating
    /// window isn't key yet at that instant.
    private func focusSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { focused = true }
    }

    // MARK: turn loop

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isBusy else { return }
        input = ""
        errorText = nil
        steps = 0
        items.append(PetChatItem(kind: .user, text: text))
        modelMessages.append(AIMessage(role: .user, content: text))
        startTurn()
    }

    private func startTurn() {
        isBusy = true
        streaming = ""
        let client = AIClient(config: ai)
        let sys = systemPrompt()
        let history = modelMessages
        task = Task {
            var text = ""
            do {
                for try await d in client.stream(system: sys, messages: history) {
                    text += d
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
        if !text.isEmpty { modelMessages.append(AIMessage(role: .assistant, content: text)) }

        // If the model asked to execute (a `plan` block) and we still have budget,
        // resolve targets → run → feed results back for a summary.
        if let plan = PetPlan.parse(text), steps < maxSteps {
            let prose = stripFenced(text)
            if !prose.isEmpty { items.append(PetChatItem(kind: .assistant, text: prose)) }

            let aliases = resolve(plan.targets)
            guard !aliases.isEmpty else {
                items.append(PetChatItem(kind: .note,
                    text: loc("没找到匹配的主机：\(plan.targets.joined(separator: ", "))",
                              "No matching hosts: \(plan.targets.joined(separator: ", "))")))
                modelMessages.append(AIMessage(role: .user, content: "没有匹配到任何主机。请只用主机清单里的真实别名或分组名重新指定目标。"))
                startTurn()
                return
            }
            if AICommandSafety.isDangerous(plan.command) {
                pendingPlan = PetPlan(targets: aliases, command: plan.command, intent: plan.intent)
                isBusy = false
                return
            }
            execute(plan.command, on: aliases, intent: plan.intent)
        } else if steps < maxSteps,
                  case let .mcpCall(server, tool, argsJSON)? = WLAction.parse(from: text) {
            let prose = stripFenced(text)
            if !prose.isEmpty { items.append(PetChatItem(kind: .assistant, text: prose)) }
            routeMCP(PendingMCPCall(server: server, tool: tool, argsJSON: argsJSON))
        } else {
            if !text.isEmpty { items.append(PetChatItem(kind: .assistant, text: text)) }
            isBusy = false
            steps = 0
            persist()
        }
    }

    // MARK: MCP tool calls

    private func routeMCP(_ call: PendingMCPCall) {
        let store = MCPStore.shared
        guard let ref = store.find(server: call.server, tool: call.tool) else {
            items.append(PetChatItem(kind: .note,
                text: loc("MCP 工具未找到：\(call.server).\(call.tool)", "MCP tool not found: \(call.server).\(call.tool)")))
            modelMessages.append(AIMessage(role: .user,
                content: "工具 \(call.server).\(call.tool) 不存在或未连接，请改用可用工具或用自然语言回答。"))
            startTurn()
            return
        }
        if store.requiresConfirmation(ref) {
            pendingMCP = call
            isBusy = false
        } else {
            executeMCP(call)
        }
    }

    private func executeMCP(_ call: PendingMCPCall) {
        steps += 1
        isBusy = true
        items.append(PetChatItem(kind: .note,
            text: loc("▶︎ 调用 MCP 工具：\(call.server).\(call.tool)", "▶︎ Calling MCP tool: \(call.server).\(call.tool)")))
        let cap = mcpResultCap, redact = ai.redact
        task = Task {
            let raw: String
            do { raw = try await MCPStore.shared.callTool(server: call.server, tool: call.tool, argsJSON: call.argsJSON) }
            catch { raw = loc("工具调用失败：", "Tool call failed: ") + ((error as? MCPError)?.description ?? error.localizedDescription) }
            let shown = redact ? AIRedactor.redact(String(raw.prefix(cap))) : String(raw.prefix(cap))
            await MainActor.run {
                items.append(PetChatItem(kind: .note, text: shown))
                modelMessages.append(AIMessage(role: .user,
                    content: "工具 \(call.server).\(call.tool) 的结果：\n\(shown)"))
                startTurn()
            }
        }
    }

    private func declineMCP() {
        guard let p = pendingMCP else { return }
        pendingMCP = nil
        items.append(PetChatItem(kind: .note, text: loc("已取消工具调用。", "Tool call cancelled.")))
        modelMessages.append(AIMessage(role: .user,
            content: "用户拒绝了工具 \(p.server).\(p.tool)。不要重试该工具；如仍需信息，用自然语言告知用户或改用只读工具。"))
        isBusy = false
        steps = 0
    }

    private func execute(_ cmd: String, on aliases: [String], intent: String?) {
        steps += 1
        isBusy = true
        items.append(PetChatItem(kind: .run, text: intent ?? "", command: cmd, targets: aliases))
        task = Task {
            let results = await FleetRunner.run(command: cmd, on: aliases)
            await MainActor.run {
                items.append(PetChatItem(kind: .results, text: "", results: results))
                let joined = results.map { "### \($0.alias) (exit \($0.exitCode))\n\($0.output)" }.joined(separator: "\n\n")
                let ctx = ai.redact ? AIRedactor.redact(joined) : joined
                modelMessages.append(AIMessage(role: .user, content:
                    "命令 `\(cmd)` 在这些机器的执行结果如下：\n\(String(ctx.suffix(8000)))\n请用中文给出简明汇总：整体结论 + 逐机要点/异常点名。若确实需要再执行命令才能回答，可再给一个 plan 块。"))
                startTurn()
            }
        }
    }

    private func declinePlan() {
        pendingPlan = nil
        items.append(PetChatItem(kind: .note, text: loc("已取消执行。", "Cancelled.")))
        isBusy = false
        steps = 0
    }

    // MARK: target resolution

    /// Map model-named targets (aliases OR group names OR fuzzy) to real aliases.
    private func resolve(_ targets: [String]) -> [String] {
        var out: [String] = []
        for raw in targets {
            let t = raw.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            if store.hosts.contains(where: { $0.alias == t }) { out.append(t); continue }
            let grp = store.hosts(inGroup: t).map(\.alias)
            if !grp.isEmpty { out.append(contentsOf: grp); continue }
            let fuzzy = store.hosts.filter {
                $0.alias.localizedCaseInsensitiveContains(t)
                    || ($0.group ?? "").localizedCaseInsensitiveCompare(t) == .orderedSame
            }.map(\.alias)
            out.append(contentsOf: fuzzy)
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    // MARK: prompt

    private func systemPrompt() -> String {
        var s = "你是 Wireline 的多机运维助手。用户用自然语言描述要在若干台机器上做的事。\n"
        s += "当需要在机器上执行时，只输出一个 ```plan 代码块，内容是 JSON：\n"
        s += "{\"targets\":[\"别名\"],\"command\":\"要执行的 shell 命令\",\"intent\":\"一句话说明\"}\n"
        s += "规则：targets 必须来自下面的主机清单（用真实别名）；用户指某个分组时，把该组的所有别名都列进 targets。"
        s += "command 尽量只读/幂等（如 docker ps、systemctl status、df -h、free -h）。"
        s += "拿到各机器结果后，用中文给出简明汇总（整体结论 + 逐机要点/异常点名），不要再输出 plan 块。"
        s += "若只是普通问答、无需上机执行，直接用中文回答。\n"
        let mcp = MCPStore.shared
        if mcp.hasTools {
            s += "\n你还能调用外部工具(MCP)：需要时输出一个 ```wl-action 代码块 {\"action\":\"mcp_call\",\"server\":\"服务名\",\"tool\":\"工具名\",\"args\":{…}}，我会执行并把结果返回给你，再据此继续。可用工具（server.tool：说明）："
            for ref in mcp.catalog.prefix(40) {
                let d = ref.tool.description.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
                s += "\n- \(ref.serverName).\(ref.tool.name)：\(d.prefix(100))"
            }
            s += "\n写操作类工具会由用户二次确认；每次仅一个动作块。\n"
        }
        s += "主机清单：\n" + inventory()
        return s
    }

    private func inventory() -> String {
        if store.hosts.isEmpty { return "（当前没有已保存的主机）" }
        return store.hosts.map { h in
            var line = "- \(h.alias)"
            if let g = h.group, !g.isEmpty { line += " [组:\(g)]" }
            if let host = h.hostname { line += " host=\(host)" }
            if let u = h.user { line += " user=\(u)" }
            return line
        }.joined(separator: "\n")
    }

    // MARK: persistence

    private func loadConvo() {
        let convo = chats.load(convoKey)
        modelMessages = convo.model
        // Rebuild a lightweight display from persisted model messages.
        if items.isEmpty {
            items = convo.display.compactMap { m in
                switch m.role {
                case .user: return PetChatItem(kind: .user, text: m.content)
                case .assistant: return PetChatItem(kind: .assistant, text: m.content)
                case .system: return PetChatItem(kind: .note, text: m.content)
                }
            }
        }
    }

    private func persist() {
        // Persist a compact display transcript (user + assistant text only).
        let display: [AIMessage] = items.compactMap { item in
            switch item.kind {
            case .user: return AIMessage(role: .user, content: item.text)
            case .assistant: return AIMessage(role: .assistant, content: item.text)
            default: return nil
            }
        }
        chats.save(convoKey, display: display, model: modelMessages)
    }

    /// Strip fenced code blocks, leaving just the prose the model wrote around them.
    private func stripFenced(_ s: String) -> String {
        let parts = s.components(separatedBy: "```")
        var prose = ""
        for (i, p) in parts.enumerated() where i % 2 == 0 { prose += p }
        return prose.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Model

/// An execution plan the model emits in a ```plan block.
struct PetPlan: Codable, Equatable {
    var targets: [String]
    var command: String
    var intent: String?

    /// Parse a plan out of the model's reply: prefer a ```plan/```json fenced
    /// block, else the first `{…}` object that carries a "command".
    static func parse(_ text: String) -> PetPlan? {
        for candidate in [fenced(text), firstObject(text)].compactMap({ $0 }) {
            if let data = candidate.data(using: .utf8),
               let p = try? JSONDecoder().decode(PetPlan.self, from: data),
               !p.command.trimmingCharacters(in: .whitespaces).isEmpty,
               !p.targets.isEmpty {
                return p
            }
        }
        return nil
    }

    private static func fenced(_ s: String) -> String? {
        let parts = s.components(separatedBy: "```")
        guard parts.count >= 3 else { return nil }
        for i in stride(from: 1, to: parts.count, by: 2) {
            var body = parts[i]
            if let nl = body.firstIndex(of: "\n") {
                let lang = body[body.startIndex..<nl].trimmingCharacters(in: .whitespaces).lowercased()
                if lang == "plan" || lang == "json" || lang.isEmpty { body = String(body[body.index(after: nl)...]) }
            }
            let t = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.contains("\"command\"") { return t }
        }
        return nil
    }

    private static func firstObject(_ s: String) -> String? {
        guard let start = s.firstIndex(of: "{"), let end = s.lastIndex(of: "}"), start < end else { return nil }
        let sub = String(s[start...end])
        return sub.contains("\"command\"") ? sub : nil
    }
}

/// One visible entry in the pet chat.
struct PetChatItem: Identifiable {
    enum Kind { case user, assistant, note, run, results }
    let id = UUID()
    var kind: Kind
    var text: String
    var command: String? = nil
    var targets: [String]? = nil
    var results: [FleetResult]? = nil
}

// MARK: - Item rendering

private struct PetItemView: View {
    let item: PetChatItem
    let loc: Localizer

    var body: some View {
        switch item.kind {
        case .user:
            Text(item.text)
                .font(WL.mono(13)).foregroundStyle(WL.textPrimary)
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(WL.green.opacity(0.12), in: RoundedRectangle(cornerRadius: WL.radius(6)))
        case .assistant:
            // Split on ``` fences so fenced code renders as a real, multi-line
            // monospace block (inline markdown alone collapses newlines and never
            // recognizes code fences, which mashed configs into one wall of text).
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(segments(item.text).enumerated()), id: \.offset) { _, seg in
                    if seg.isCode { codeBlock(seg.text) } else { prose(seg.text) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .note:
            Text(item.text)
                .font(WL.mono(12)).foregroundStyle(WL.textDim)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .run:
            runCard
        case .results:
            resultsCard
        }
    }

    // MARK: assistant rendering

    /// Prose between code fences. Uses whitespace-preserving markdown so soft
    /// line breaks and lists the model wrote survive (plain `Text(.init:)` would
    /// collapse them into a single paragraph).
    private func prose(_ text: String) -> some View {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return Group {
            if t.isEmpty { EmptyView() }
            else {
                Text(attributed(t))
                    .font(WL.mono(13)).foregroundStyle(WL.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func attributed(_ s: String) -> AttributedString {
        (try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(s)
    }

    /// A fenced code block: monospace, newlines preserved, with a copy button.
    private func codeBlock(_ code: String) -> some View {
        let text = code.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 6) {
            Text(text)
                .font(WL.mono(12)).foregroundStyle(WL.green)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Spacer()
                BracketButton(loc("复制", "Copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
        }
        .padding(9)
        .background(WL.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: WL.radius(6)))
        .overlay(RoundedRectangle(cornerRadius: WL.radius(6)).stroke(WL.border, lineWidth: WL.borderWidth))
    }

    /// Split content on ``` fences into prose/code segments (code strips an
    /// optional leading language hint like `nginx`).
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

    private var runCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !item.text.isEmpty {
                Text(item.text).font(WL.caption).foregroundStyle(WL.textDim)
            }
            HStack(spacing: 6) {
                Image(systemName: "play.fill").font(.system(size: 9)).foregroundStyle(WL.green)
                Text(loc("在 \((item.targets ?? []).count) 台执行", "Run on \((item.targets ?? []).count)"))
                    .font(WL.caption).foregroundStyle(WL.textDim)
                Text((item.targets ?? []).joined(separator: ", "))
                    .font(WL.caption).foregroundStyle(WL.green).lineLimit(1)
            }
            Text(item.command ?? "")
                .font(WL.mono(12)).foregroundStyle(WL.green).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(9)
        .background(WL.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: WL.radius(6)))
        .overlay(RoundedRectangle(cornerRadius: WL.radius(6)).stroke(WL.border, lineWidth: WL.borderWidth))
    }

    private var resultsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(item.results ?? []) { r in
                DisclosureGroup {
                    Text(r.output.isEmpty ? loc("(无输出)", "(no output)") : r.output)
                        .font(WL.mono(11)).foregroundStyle(WL.textDim).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 3)
                } label: {
                    HStack(spacing: 6) {
                        Circle().fill(r.ok ? WL.green : WL.red).frame(width: 7, height: 7)
                        Text(r.alias).font(WL.small.weight(.semibold)).foregroundStyle(WL.textPrimary)
                        Spacer()
                        Text(r.ok ? loc("成功", "ok") : loc("退出码 \(r.exitCode)", "exit \(r.exitCode)"))
                            .font(WL.caption).foregroundStyle(r.ok ? WL.textDim : WL.red)
                    }
                }
                .font(WL.small).tint(WL.green)
            }
        }
        .padding(9)
        .background(WL.surface.opacity(0.35), in: RoundedRectangle(cornerRadius: WL.radius(6)))
        .overlay(RoundedRectangle(cornerRadius: WL.radius(6)).stroke(WL.border, lineWidth: WL.borderWidth))
    }
}
