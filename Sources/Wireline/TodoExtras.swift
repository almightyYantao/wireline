import SwiftUI
import WirelineCore

// MARK: - AI assistant

/// AI helpers for the to-do list: a natural-language daily / monthly recap and
/// smart-add (turn a sentence into a titled item with a due date). Reuses the
/// app's configured OpenAI-compatible / Ollama endpoint via `AIClient`.
@MainActor
enum TodoAI {
    enum Scope { case today, month }

    static var isAvailable: Bool { AIConfig.shared.enabled && AIConfig.shared.isConfigured }

    /// A plain-language recap of what was done in the scope plus what's still open.
    static func recap(_ scope: Scope, store: TodoStore, now: Date) async -> String {
        let loc = Localizer.shared
        let cal = Calendar.current
        let (start, label): (Date, String)
        switch scope {
        case .today:
            start = cal.startOfDay(for: now)
            label = loc.t("今天", "today")
        case .month:
            start = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now
            label = loc.t("本月", "this month")
        }
        let done = store.completed(from: start, to: now)
        let open = store.openItems

        let df = DateFormatter(); df.dateFormat = "MM-dd HH:mm"
        func lines(_ items: [Todo]) -> String {
            items.isEmpty ? loc.t("（无）", "(none)")
                : items.map { t in
                    let due = t.dueDate.map { " [due \(df.string(from: $0))]" } ?? ""
                    return "- \(t.title)\(due)"
                }.joined(separator: "\n")
        }

        let sys = loc.t(
            "你是简洁的待办助手。根据用户\(label)完成的事项和仍未完成的事项，用中文写一段自然、简短的总结：先概括完成情况，再点出仍需关注/逾期的重点，最后给一句下一步建议。不要客套、不要用 markdown 标题。",
            "You are a concise to-do assistant. From what the user completed \(label) and what's still open, write a short natural-language recap: summarize what got done, flag what still needs attention (especially overdue), and end with one next-step suggestion. No pleasantries, no markdown headings.")
        let user = """
        \(loc.t("\(label)已完成：", "Completed \(label):"))
        \(lines(done))

        \(loc.t("未完成：", "Still open:"))
        \(lines(open))
        """

        return await complete(system: sys, user: user)
    }

    /// Parse a free-text line into a to-do. Falls back to a plain item if the AI
    /// is unavailable or returns something unparseable.
    static func smartAdd(_ text: String, now: Date) async -> Todo {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var fallback = Todo(title: trimmed, createdAt: now.timeIntervalSince1970)
        guard isAvailable else { return fallback }

        let iso = ISO8601DateFormatter()
        let sys = """
        You extract a to-do from a sentence. Reply with ONLY compact JSON:
        {"title": string, "priority": bool, "due": string|null}
        `due` is an ISO-8601 datetime or null. Resolve relative dates against the
        reference time. Keep the title short; strip the time phrase from it.
        """
        let user = "Reference time: \(iso.string(from: now))\nSentence: \(trimmed)"
        let raw = await complete(system: sys, user: user)
        guard let data = extractJSON(raw),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return fallback
        }
        if let title = obj["title"] as? String, !title.isEmpty {
            fallback.title = title
        }
        fallback.priority = (obj["priority"] as? Bool) ?? false
        if let due = obj["due"] as? String, let date = iso.date(from: due) {
            fallback.dueDate = date
        }
        return fallback
    }

    // MARK: helpers

    private static func complete(system: String, user: String) async -> String {
        guard isAvailable else { return "" }
        let client = AIClient(config: AIConfig.shared)
        var out = ""
        do {
            for try await d in client.stream(system: system,
                                             messages: [AIMessage(role: .user, content: user)]) {
                out += d
            }
        } catch {
            return ""
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Pull the first {...} block out of a possibly fenced reply.
    private static func extractJSON(_ s: String) -> Data? {
        guard let lo = s.firstIndex(of: "{"), let hi = s.lastIndex(of: "}"), lo < hi else { return nil }
        return String(s[lo...hi]).data(using: .utf8)
    }
}

// MARK: - Menu-bar popover

/// Compact list shown from the menu-bar icon: quick-add, quick-toggle, and a way
/// into the full window.
struct TodoMenuBarView: View {
    @Environment(TodoStore.self) private var store
    @Environment(Localizer.self) private var loc
    var openWindow: () -> Void

    @State private var draft = ""

    var body: some View {
        // Touch `todos` directly so this popover re-renders when the list
        // changes — @Observable tracking across the MenuBarExtra scene boundary
        // is unreliable unless a stored property is read in the body itself.
        let open = store.todos.filter { !$0.done }
        let shown = Array(store.ordered.filter { !$0.done }.prefix(8))

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(loc("待办", "TODO")).font(.headline)
                Spacer()
                Text(loc("\(open.count) 项未完成", "\(open.count) open"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                TextField(loc("快速添加…", "Quick add…"), text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { store.add(title: draft); draft = "" }
                Button(loc("添加", "Add")) { store.add(title: draft); draft = "" }
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Divider()

            if open.isEmpty {
                Text(loc("全部完成 🎉", "All clear 🎉"))
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 6)
            } else {
                // Render rows directly (capped at 8) rather than in a ScrollView:
                // a ScrollView has zero ideal height and collapses inside the
                // auto-sizing menu-bar popover, hiding the list.
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(shown) { todo in
                        Button { store.toggle(todo) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "circle")
                                Text(todo.title.isEmpty ? loc("(无标题)", "(untitled)") : todo.title)
                                    .lineLimit(1)
                                Spacer()
                                if todo.priority { Image(systemName: "star.fill").foregroundStyle(.yellow) }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 2)
                    }
                    if open.count > shown.count {
                        Text(loc("还有 \(open.count - shown.count) 项…", "\(open.count - shown.count) more…"))
                            .font(.caption).foregroundStyle(.secondary).padding(.top, 2)
                    }
                }
            }

            Divider()
            HStack {
                Button(loc("打开待办窗", "Open window")) {
                    // Bring the app forward first — from a menu-bar popover the
                    // app isn't active, and openWindow alone opens behind.
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow()
                }
                Spacer()
                Button(loc("退出", "Quit")) { NSApp.terminate(nil) }
            }
            .font(.callout)
        }
        .padding(12)
        .frame(width: 300)
    }
}
