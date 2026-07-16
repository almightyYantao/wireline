import Foundation

/// How often a to-do repeats. When a recurring item is completed, the next
/// occurrence is spawned automatically (see `TodoStore.toggle`).
public enum Recurrence: String, Codable, Sendable, CaseIterable {
    case none, daily, weekly, monthly

    /// Advance `date` by one period. `nil` for `.none`.
    public func next(after date: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .none:    return nil
        case .daily:   return calendar.date(byAdding: .day, value: 1, to: date)
        case .weekly:  return calendar.date(byAdding: .weekOfYear, value: 1, to: date)
        case .monthly: return calendar.date(byAdding: .month, value: 1, to: date)
        }
    }
}

/// A checklist item nested inside a `Todo`.
public struct Subtask: Identifiable, Codable, Sendable, Equatable {
    public var id = UUID()
    public var title: String
    public var done: Bool = false

    public init(id: UUID = UUID(), title: String, done: Bool = false) {
        self.id = id
        self.title = title
        self.done = done
    }
}

/// A single to-do item. Deliberately generic — not tied to any host or command,
/// so the to-do window works as a plain daily list. Lives in Core (not the app
/// target) so it can ride along inside the encrypted backup bundle.
public struct Todo: Identifiable, Codable, Sendable, Equatable {
    public var id = UUID()
    public var title: String
    public var done: Bool = false
    public var note: String = ""
    /// Optional due date/time. `nil` means "no deadline".
    public var dueDate: Date? = nil
    /// Starred / important.
    public var priority: Bool = false
    /// Free-form labels for grouping / filtering.
    public var tags: [String] = []
    /// Nested checklist.
    public var subtasks: [Subtask] = []
    /// Repeat schedule.
    public var recurrence: Recurrence = .none
    /// Seconds since 1970, captured at creation.
    public var createdAt: Double
    /// Seconds since 1970 when it was marked done; `nil` while open. Drives the
    /// daily / monthly recap.
    public var completedAt: Double? = nil

    public init(id: UUID = UUID(), title: String, createdAt: Double) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
    }

    /// Past its due date and still open.
    public func isOverdue(now: Date) -> Bool {
        guard !done, let due = dueDate else { return false }
        return due < now
    }

    /// "done / total" over subtasks (nil when there are none).
    public var subtaskProgress: (done: Int, total: Int)? {
        guard !subtasks.isEmpty else { return nil }
        return (subtasks.filter(\.done).count, subtasks.count)
    }

    enum CodingKeys: String, CodingKey {
        case id, title, done, note, dueDate, priority, tags, subtasks, recurrence, createdAt, completedAt
    }

    /// Tolerant decoding so items written by an earlier build (before these
    /// fields existed) still load — missing keys fall back to defaults instead
    /// of failing the whole file.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        dueDate = try c.decodeIfPresent(Date.self, forKey: .dueDate)
        priority = try c.decodeIfPresent(Bool.self, forKey: .priority) ?? false
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        subtasks = try c.decodeIfPresent([Subtask].self, forKey: .subtasks) ?? []
        recurrence = try c.decodeIfPresent(Recurrence.self, forKey: .recurrence) ?? .none
        createdAt = try c.decodeIfPresent(Double.self, forKey: .createdAt) ?? 0
        completedAt = try c.decodeIfPresent(Double.self, forKey: .completedAt)
    }
}
