import XCTest
@testable import WirelineCore

final class WorkspaceTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func sample() -> [WorkspaceTab] {
        let claude = AIResume(agent: .claude, sessionID: "0b6f1c1e-1111-4222-8333-944455556666", directory: "/tmp/p")
        return [
            WorkspaceTab(name: "dev", root: .split(vertical: true, ratio: 0.3,
                first: .pane(WorkspacePane(kind: .local, title: "p", directory: "/tmp/p", aiResume: claude)),
                second: .split(vertical: false, ratio: 0.5,
                               first: .pane(WorkspacePane(kind: .ssh, alias: "web", title: "web")),
                               second: .pane(WorkspacePane(kind: .local, title: "Local Shell")))),
                focusedPane: 1),
            WorkspaceTab(root: .pane(WorkspacePane(kind: .rdp, alias: "win", title: "win"))),
        ]
    }

    func testRoundTrip() throws {
        var lib = WorkspaceLibrary()
        lib.save(name: "  Work ", tabs: sample(), activeTab: 0, at: t0)
        let back = try WorkspaceLibrary.decode(lib.encoded())
        XCTAssertEqual(back, lib)
        XCTAssertEqual(back.workspaces[0].name, "Work")
        XCTAssertEqual(back.workspaces[0].paneCount, 4)
        XCTAssertEqual(back.workspaces[0].tabs[0].root.panes.map(\.kind), [.local, .ssh, .local])
    }

    func testMigratesBareArrayAndMissingFields() throws {
        let json = """
        [{"id":"\(UUID())","name":"old","created":"2024-01-01T00:00:00Z","updated":"2024-01-01T00:00:00Z",
          "tabs":[{"root":{"vertical":true,"ratio":7,"first":{"pane":{"kind":"local"}},
                           "second":{"pane":{"kind":"ssh","alias":"a","aiResume":{"bogus":1}}}}}]}]
        """
        let lib = try WorkspaceLibrary.decode(Data(json.utf8))
        XCTAssertEqual(lib.version, WorkspaceLibrary.currentVersion)
        guard case .split(_, let ratio, .pane(let a), .pane(let b)) = lib.workspaces[0].tabs[0].root else {
            return XCTFail()
        }
        XCTAssertEqual(ratio, 0.88)
        XCTAssertEqual(a.title, "")
        XCTAssertNil(b.aiResume)
        XCTAssertEqual(b.alias, "a")
    }

    func testRefusesNewerVersion() {
        let json = #"{"version":99,"workspaces":[]}"#
        XCTAssertThrowsError(try WorkspaceLibrary.decode(Data(json.utf8)))
    }

    func testSaveRenameDelete() {
        var lib = WorkspaceLibrary()
        let a = lib.save(name: "A", tabs: sample(), activeTab: nil, at: t0)!
        let b = lib.save(name: "B", tabs: sample(), activeTab: nil, at: t0)!
        XCTAssertNil(lib.save(name: "  ", tabs: sample(), activeTab: nil))
        XCTAssertNil(lib.save(name: "C", tabs: [], activeTab: nil))
        // Same name (any case) overwrites, keeping identity.
        let a2 = lib.save(name: "a", tabs: Array(sample().prefix(1)), activeTab: 0, at: t0 + 10)!
        XCTAssertEqual(a2.id, a.id)
        XCTAssertEqual(lib.workspaces.count, 2)
        XCTAssertEqual(lib.sorted.first?.id, a.id)
        XCTAssertFalse(lib.rename(a.id, to: "b"))
        XCTAssertFalse(lib.rename(a.id, to: ""))
        XCTAssertTrue(lib.rename(a.id, to: "Renamed"))
        XCTAssertEqual(lib.workspace(named: "renamed")?.id, a.id)
        lib.delete(b.id)
        XCTAssertEqual(lib.workspaces.map(\.id), [a.id])
    }

    func testFilteredCollapses() {
        let root = sample()[0].root
        let onlyLocal = root.filtered { $0.kind == .local }
        XCTAssertEqual(onlyLocal?.panes.count, 2)
        if case .split(let v, let r, _, _)? = onlyLocal { XCTAssertTrue(v); XCTAssertEqual(r, 0.3) } else { XCTFail() }
        XCTAssertNil(root.filtered { _ in false })
    }

    func testResumeCommands() {
        XCTAssertEqual(AIResume(agent: .claude, sessionID: "abc-123").command, "claude --resume abc-123")
        XCTAssertEqual(AIResume(agent: .codex, sessionID: "019d12fd-539e").command, "codex resume 019d12fd-539e")
        XCTAssertNil(AIResume(agent: .claude, sessionID: "x; rm -rf ~").command)
        XCTAssertNil(AIResume(agent: .claude, sessionID: "").command)
        XCTAssertNil(AIResume(agent: .codex, sessionID: "a\nb").command)
        XCTAssertNil(AIResume(agent: .codex, sessionID: "é").command)
    }

    func testClaudeHookPayload() {
        let id = UUID()
        let msg = AgentHooks.parse("\(id) Stop {\"session_id\":\"s-1\",\"cwd\":\"/w\",\"hook_event_name\":\"Stop\"}")
        XCTAssertEqual(msg?.resume, AIResume(agent: .claude, sessionID: "s-1", directory: "/w"))
        XCTAssertNil(AgentHooks.parse("\(id) Stop {\"session_id\":\"$(x)\"}")?.resume)
        XCTAssertNil(AgentHooks.parse("\(id) Stop")?.resume)
    }

    func testCodexSessionScan() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let day = root.appendingPathComponent(String(format: "%04d/%02d/%02d", c.year!, c.month!, c.day!))
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        func write(_ name: String, id: String, cwd: String, age: TimeInterval) throws {
            let url = day.appendingPathComponent("rollout-\(name).jsonl")
            let line = #"{"timestamp":"2026-10-27T00:00:00.000Z","type":"session_meta","payload":{"id":"\#(id)","timestamp":"2026-10-27T00:00:00.123Z","cwd":"\#(cwd)"}}"#
            try (line + "\n{\"type\":\"event\"}\n").write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
        }
        try write("a", id: "old-proj", cwd: "/proj", age: 3600)
        try write("b", id: "new-proj", cwd: "/proj", age: 5)
        try write("c", id: "other", cwd: "/elsewhere", age: 1)
        let since = Date().addingTimeInterval(-60)
        XCTAssertEqual(CodingAgentSessions.latestCodex(cwd: "/proj/", since: since, root: root)?.sessionID, "new-proj")
        XCTAssertNil(CodingAgentSessions.latestCodex(cwd: "/none", since: since, root: root))
        XCTAssertEqual(CodingAgentSessions.latestCodex(cwd: "/proj", since: .distantPast, root: root)?.sessionID, "new-proj")
        XCTAssertNotNil(CodingAgentSessions.codexMeta(line: #"{"type":"session_meta","payload":{"session_id":"x1"}}"#))
        XCTAssertNil(CodingAgentSessions.codexMeta(line: #"{"type":"event","payload":{"id":"x1"}}"#))
    }
}
