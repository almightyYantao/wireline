import SwiftUI
import WirelineCore

/// Something an MCP client wants to do that needs the user's OK. Everything in
/// it is the restored, real value: the user approves what actually runs.
struct MCPApproval: Identifiable, Equatable {
    let id = UUID()
    /// `clientInfo.name` from `initialize` ("claude-code").
    var client: String
    /// "在 web1 上执行", "写入 web1:/etc/hosts".
    var title: String
    /// The command, or the path.
    var subject: String
    /// The diff of a file write, or the hosts of a fleet run.
    var detail: String?
    var dangerous: Bool
    /// "Don't ask again for this connection": commands, not file writes.
    var canAlwaysAllow: Bool
    /// The AI's impact assessment of a dangerous command, when it arrives.
    var review: String?
    var sessionID: UUID?
}

/// One question at a time, asked on the notch island, as a card in the main
/// window, and (with Wireline in the background) as a notification. The first
/// answer wins; nobody answering in `timeout` is a no.
@Observable
@MainActor
final class MCPApprovalCenter {
    static let shared = MCPApprovalCenter()

    private(set) var queue: [MCPApproval] = []
    var current: MCPApproval? { queue.first }

    @ObservationIgnored private var waiters: [UUID: CheckedContinuation<IslandDecision, Never>] = [:]
    @ObservationIgnored var timeout: TimeInterval = 120

    func ask(_ approval: MCPApproval) async -> IslandDecision {
        await withCheckedContinuation { cont in
            waiters[approval.id] = cont
            queue.append(approval)
            if queue.count == 1 { present() }
            if approval.dangerous { fetchReview(approval) }
            let id = approval.id, wait = timeout
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                self?.answer(id, .deny)
            }
        }
    }

    func answer(_ id: UUID, _ decision: IslandDecision) {
        guard let cont = waiters.removeValue(forKey: id) else { return }
        queue.removeAll { $0.id == id }
        IslandCenter.shared.remove(islandID(id))
        cont.resume(returning: decision)
        present()
    }

    private func islandID(_ id: UUID) -> String { "mcp:" + id.uuidString }

    private func present() {
        guard let a = current else { return }
        let loc = Localizer.shared
        let note = a.review ?? a.detail.map { String($0.prefix(300)) }
        let confirmation = IslandConfirmation(kind: a.dangerous ? .dangerousCommand : .toolCall,
                                              subject: a.title + "\n" + a.subject,
                                              canAlwaysAllow: a.canAlwaysAllow, note: note)
        IslandCenter.shared.upsert(IslandItem(id: islandID(a.id), source: .ai,
                                              title: loc.t("外部 AI · ", "AI client · ") + a.client,
                                              detail: loc.t("等你确认", "Needs your OK"), tone: .attention,
                                              confirmation: confirmation, sessionID: a.sessionID, at: Date()))
        IslandCenter.shared.setDecision(islandID(a.id)) { [weak self] d in self?.answer(a.id, d) }
        if let app = NSApp, !app.isActive {
            Notifier.post(title: loc.t("\(a.client) 请求操作", "\(a.client) wants to act"),
                          body: a.title + "：" + a.subject)
        }
    }

    /// Ask the AI for a one-line impact note on a dangerous command (masked
    /// like any other AI request), and show it when it lands.
    private func fetchReview(_ a: MCPApproval) {
        let ai = AIConfig.shared
        guard ai.enabled, ai.isConfigured else { return }
        let client = AIClient(config: ai)
        let model = ai.hasFastModel ? ai.activeModelFast : nil
        let sys = "你是命令安全评审员。用中文一两句话说明这条命令的影响面和主要风险，非常简短，不要客套、不要重复命令本身。"
        let subject = a.subject
        Task { [weak self] in
            var text = ""
            do { for try await d in client.stream(system: sys, messages: [AIMessage(role: .user, content: subject)], model: model) { text += d } }
            catch { return }
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let self, !t.isEmpty, let i = self.queue.firstIndex(where: { $0.id == a.id }) else { return }
            self.queue[i].review = t
            if i == 0 { self.present() }
        }
    }
}

/// The main window's card for the pending approval.
struct MCPApprovalModal: ViewModifier {
    @State private var center = MCPApprovalCenter.shared

    func body(content: Content) -> some View {
        content.wlModal(item: Binding(get: { center.current }, set: { new in
            // Closing the card (×, Esc) is a no.
            if new == nil, let a = center.current { center.answer(a.id, .deny) }
        })) { a in
            MCPApprovalSheet(approval: a) { center.answer(a.id, $0) }
        }
    }
}

private struct MCPApprovalSheet: View {
    @Environment(Localizer.self) private var loc
    let approval: MCPApproval
    let decide: (IslandDecision) -> Void

    var body: some View {
        WLSheet(loc("外部 AI 请求操作", "An AI client wants to act"),
                subtitle: approval.client, symbol: approval.dangerous ? "exclamationmark.triangle" : "hand.raised",
                width: 560, onClose: { decide(.deny) }) {
            VStack(alignment: .leading, spacing: 10) {
                Text(approval.title).font(WL.body).foregroundStyle(WL.textPrimary)
                Text(approval.subject)
                    .font(WL.mono(12)).foregroundStyle(approval.dangerous ? WL.amber : WL.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(WL.textPrimary.opacity(WL.isLight ? 0.04 : 0.06),
                                in: RoundedRectangle(cornerRadius: WL.radius(10), style: .continuous))
                if let review = approval.review {
                    Text(review).font(WL.small).foregroundStyle(WL.amber).textSelection(.enabled)
                } else if approval.dangerous {
                    Text(loc("高危命令。", "A risky command.")).font(WL.small).foregroundStyle(WL.amber)
                }
                if let detail = approval.detail {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(detail.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                                Text(line.isEmpty ? " " : line)
                                    .font(WL.mono(11))
                                    .foregroundStyle(line.hasPrefix("+ ") ? WL.green : line.hasPrefix("- ") ? WL.red : WL.textDim)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .textSelection(.enabled)
                    }
                    .frame(maxHeight: 260)
                }
                Text(loc("\(Int(MCPApprovalCenter.shared.timeout)) 秒内不处理视为拒绝。", "No answer within \(Int(MCPApprovalCenter.shared.timeout)) s counts as a no."))
                    .font(WL.caption).foregroundStyle(WL.textDim)
            }
        } footer: {
            Spacer()
            Button(loc("拒绝", "Deny")) { decide(.deny) }
                .buttonStyle(.wlSecondary).keyboardShortcut(.cancelAction)
            if approval.canAlwaysAllow {
                Button(loc("本连接不再询问", "Allow for this connection")) { decide(.allowAlways) }
                    .buttonStyle(.wlSecondary)
            }
            Button(approval.dangerous ? loc("仍然执行", "Run anyway") : loc("允许", "Allow")) { decide(.allow) }
                .buttonStyle(.wlPrimary)
        }
    }
}

// MARK: - Audit log

/// Every MCP tool call, one JSON line each, in
/// `~/Library/Application Support/Wireline/mcp-audit.jsonl`. Local only, so it
/// keeps the real (restored) values: it's the user's record of what ran.
enum MCPAudit {
    struct Entry: Codable, Identifiable, Equatable {
        var id = UUID()
        var time: Date
        var client: String
        var tool: String
        /// Arguments as JSON, file contents replaced by their size.
        var arguments: String
        /// "auto", "approved", "denied", "refused", "error", "ok".
        var outcome: String
    }

    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wireline/mcp-audit.jsonl")
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    static func summarize(_ args: [String: Any]) -> String {
        var a = args
        if let content = a["content"] as? String { a["content"] = "<\(content.utf8.count) bytes>" }
        guard let data = try? JSONSerialization.data(withJSONObject: a, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    static func record(_ entry: Entry) {
        guard var line = try? encoder.encode(entry) else { return }
        line.append(0x0A)
        let u = url
        // Keep one previous file once this one passes 5 MB.
        if let size = (try? FileManager.default.attributesOfItem(atPath: u.path))?[.size] as? Int, size > 5 << 20 {
            let old = u.appendingPathExtension("1")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: u, to: old)
        }
        if let h = try? FileHandle(forWritingTo: u) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: line)
        } else {
            try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? line.write(to: u, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: u.path)
        }
    }

    /// The last `limit` entries, newest first.
    static func recent(_ limit: Int = 200) -> [Entry] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").suffix(limit).reversed()
            .compactMap { try? d.decode(Entry.self, from: Data($0.utf8)) }
    }
}
