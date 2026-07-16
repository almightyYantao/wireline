import XCTest
@testable import WirelineCore

final class TodoTests: XCTestCase {

    /// A payload written by an older build (no priority / dueDate / completedAt)
    /// must still decode, filling the missing fields with defaults.
    func testTolerantDecodingOfLegacyItem() throws {
        let legacy = """
        [{"id":"\(UUID().uuidString)","title":"old item","done":false,"note":"","createdAt":123.0}]
        """.data(using: .utf8)!
        let items = try JSONDecoder().decode([Todo].self, from: legacy)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].title, "old item")
        XCTAssertFalse(items[0].priority)
        XCTAssertNil(items[0].dueDate)
        XCTAssertNil(items[0].completedAt)
    }

    func testRoundTrip() throws {
        var todo = Todo(title: "ship it", createdAt: 100)
        todo.priority = true
        todo.dueDate = Date(timeIntervalSince1970: 200)
        todo.completedAt = 150
        let data = try JSONEncoder().encode([todo])
        let back = try JSONDecoder().decode([Todo].self, from: data)
        XCTAssertEqual(back, [todo])
    }

    func testOverdue() {
        var todo = Todo(title: "late", createdAt: 0)
        todo.dueDate = Date(timeIntervalSince1970: 0)
        XCTAssertTrue(todo.isOverdue(now: Date(timeIntervalSince1970: 10)))
        todo.done = true
        XCTAssertFalse(todo.isOverdue(now: Date(timeIntervalSince1970: 10)), "completed items are never overdue")
    }

    func testRecurrenceAdvances() {
        let base = Date(timeIntervalSince1970: 0)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertNil(Recurrence.none.next(after: base, calendar: cal))
        XCTAssertEqual(Recurrence.daily.next(after: base, calendar: cal),
                       Date(timeIntervalSince1970: 86_400))
        XCTAssertEqual(Recurrence.weekly.next(after: base, calendar: cal),
                       Date(timeIntervalSince1970: 7 * 86_400))
    }

    func testSubtaskProgress() {
        var todo = Todo(title: "parent", createdAt: 0)
        XCTAssertNil(todo.subtaskProgress)
        todo.subtasks = [Subtask(title: "a", done: true), Subtask(title: "b")]
        XCTAssertEqual(todo.subtaskProgress?.done, 1)
        XCTAssertEqual(todo.subtaskProgress?.total, 2)
    }

    func testTagsAndSubtasksRoundTrip() throws {
        var todo = Todo(title: "x", createdAt: 0)
        todo.tags = ["work", "urgent"]
        todo.subtasks = [Subtask(title: "step 1", done: true)]
        todo.recurrence = .weekly
        let data = try JSONEncoder().encode(todo)
        let back = try JSONDecoder().decode(Todo.self, from: data)
        XCTAssertEqual(back, todo)
    }

    /// A backup written before to-dos existed (no `todos` key) must still restore,
    /// and one written with to-dos must carry them.
    func testBackupBundleCarriesTodos() throws {
        let legacy = """
        {"hosts":[],"passwords":{}}
        """.data(using: .utf8)!
        let restored = try JSONDecoder().decode(BackupBundle.self, from: legacy)
        XCTAssertTrue(restored.todos.isEmpty)

        let bundle = BackupBundle(hosts: [], passwords: [:],
                                  todos: [Todo(title: "carried", createdAt: 1)])
        let data = try JSONEncoder().encode(bundle)
        let back = try JSONDecoder().decode(BackupBundle.self, from: data)
        XCTAssertEqual(back.todos.map(\.title), ["carried"])
    }
}
