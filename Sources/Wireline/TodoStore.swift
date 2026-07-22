import Foundation
import Observation
import WirelineCore

/// Stores to-do items, persisted to Application Support as JSON — same pattern as
/// `SnippetStore` / `HostMemoryStore`. No server, no ~/.ssh/config involvement:
/// to-dos are app state, so they live only in `todos.json` on this machine (and,
/// opt-in, inside the encrypted backup bundle).
@Observable
@MainActor
final class TodoStore {
    private(set) var todos: [Todo] = []
    /// True when the last mutation can be undone (⌘Z).
    private(set) var canUndo = false
    /// Master switch for the whole to-do feature. When off, the menu-bar extra
    /// and the To-Do menu command disappear — the feature is opt-in chrome, so
    /// users who don't use it can hide it entirely. Mirrored into UserDefaults.
    var enabled: Bool = UserDefaults.standard.object(forKey: "todoEnabled") as? Bool ?? false {
        didSet { UserDefaults.standard.set(enabled, forKey: "todoEnabled") }
    }

    private let fileURL: URL
    /// Snapshots for undo — capped so it never grows unbounded.
    private var undoStack: [[Todo]] = []
    private let undoLimit = 50

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wireline", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.fileURL = base.appendingPathComponent("todos.json")
        load()
        rescheduleAll()
    }

    /// Sort order: open items first, then starred ahead of the rest, then by
    /// soonest due date (items with no date last), then oldest first. Completed
    /// items sink to the bottom, most-recently-completed first.
    var ordered: [Todo] {
        todos.sorted { a, b in
            if a.done != b.done { return !a.done }
            if a.done { return (a.completedAt ?? 0) > (b.completedAt ?? 0) }
            if a.priority != b.priority { return a.priority }
            switch (a.dueDate, b.dueDate) {
            case let (x?, y?) where x != y: return x < y
            case (.some, .none): return true
            case (.none, .some): return false
            default: return a.createdAt < b.createdAt
            }
        }
    }

    var activeCount: Int { todos.lazy.filter { !$0.done }.count }

    /// Every distinct tag in use, sorted, for the tag filter.
    var allTags: [String] {
        Array(Set(todos.flatMap(\.tags))).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    // MARK: - Mutations (each snapshots for undo)

    func add(title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        snapshot()
        let todo = Todo(title: trimmed, createdAt: Date().timeIntervalSince1970)
        todos.append(todo)
        commit()
    }

    /// Add a fully-formed item (used by AI smart-add, which may set a due date).
    func add(_ todo: Todo) {
        snapshot()
        todos.append(todo)
        commit()
    }

    func update(_ todo: Todo) {
        guard let i = todos.firstIndex(where: { $0.id == todo.id }) else { return }
        snapshot()
        todos[i] = todo
        commit()
    }

    func toggle(_ todo: Todo) {
        guard let i = todos.firstIndex(where: { $0.id == todo.id }) else { return }
        snapshot()
        let nowCompleting = !todos[i].done
        todos[i].done = nowCompleting
        todos[i].completedAt = nowCompleting ? Date().timeIntervalSince1970 : nil
        // Completing a recurring item spawns its next occurrence.
        if nowCompleting, todos[i].recurrence != .none {
            spawnNextOccurrence(of: todos[i])
        }
        commit()
    }

    /// Build the next instance of a recurring item: same title/tags/subtasks
    /// (reset to open), due date advanced by one period.
    private func spawnNextOccurrence(of todo: Todo) {
        let base = todo.dueDate ?? Date()
        guard let nextDue = todo.recurrence.next(after: base) else { return }
        var next = Todo(title: todo.title, createdAt: Date().timeIntervalSince1970)
        next.note = todo.note
        next.priority = todo.priority
        next.tags = todo.tags
        next.recurrence = todo.recurrence
        next.dueDate = nextDue
        next.subtasks = todo.subtasks.map { Subtask(title: $0.title) }  // reset to undone
        todos.append(next)
    }

    func toggleSubtask(_ subID: UUID, in todo: Todo) {
        guard let i = todos.firstIndex(where: { $0.id == todo.id }),
              let j = todos[i].subtasks.firstIndex(where: { $0.id == subID }) else { return }
        snapshot()
        todos[i].subtasks[j].done.toggle()
        commit()
    }

    func remove(_ todo: Todo) {
        snapshot()
        todos.removeAll { $0.id == todo.id }
        commit()
    }

    func clearCompleted() {
        snapshot()
        todos.removeAll { $0.done }
        commit()
    }

    func undo() {
        guard let last = undoStack.popLast() else { return }
        todos = last
        canUndo = !undoStack.isEmpty
        save()
        rescheduleAll()
    }

    /// Replace the whole list — used when restoring from a backup.
    func replaceAll(_ items: [Todo]) {
        undoStack.removeAll()
        canUndo = false
        todos = items
        save()
        rescheduleAll()
    }

    // MARK: - Recap helpers

    /// Items completed within `[start, end)`, newest first.
    func completed(from start: Date, to end: Date) -> [Todo] {
        let lo = start.timeIntervalSince1970, hi = end.timeIntervalSince1970
        return todos
            .filter { $0.done && ($0.completedAt.map { $0 >= lo && $0 < hi } ?? false) }
            .sorted { ($0.completedAt ?? 0) > ($1.completedAt ?? 0) }
    }

    var openItems: [Todo] { todos.filter { !$0.done } }

    // MARK: - Persistence

    private func snapshot() {
        undoStack.append(todos)
        if undoStack.count > undoLimit { undoStack.removeFirst() }
        canUndo = true
    }

    /// Persist + reschedule notifications after a mutation.
    private func commit() {
        save()
        rescheduleAll()
    }

    private func load() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([Todo].self, from: data) {
            todos = decoded
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(todos) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: - Due reminders

    private func reminderID(_ todo: Todo) -> String { "todo.\(todo.id.uuidString)" }

    /// Re-sync all pending due notifications to the current list: schedule one for
    /// every open item with a future due date, cancel the rest.
    private func rescheduleAll() {
        let loc = Localizer.shared
        for todo in todos {
            let id = reminderID(todo)
            guard !todo.done, let due = todo.dueDate, due > Date() else {
                Notifier.cancel(id: id)
                continue
            }
            Notifier.schedule(id: id,
                              title: loc.t("待办到期", "To-do due"),
                              body: todo.title,
                              at: due)
        }
    }
}
