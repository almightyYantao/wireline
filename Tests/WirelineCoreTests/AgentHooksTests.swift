import XCTest
@testable import WirelineCore

final class AgentHooksTests: XCTestCase {
    let id = UUID()
    let t0 = Date(timeIntervalSince1970: 1_000)

    func testParse() {
        XCTAssertEqual(AgentHooks.parse("\(id) UserPromptSubmit {\"prompt\":\"hi\"}"),
                       .init(sessionID: id, event: .promptSubmitted))
        XCTAssertEqual(AgentHooks.parse("\(id) Stop \n"), .init(sessionID: id, event: .stop))
        XCTAssertEqual(AgentHooks.parse("\(id) Notification {\"message\":\"Claude needs your permission to use Bash\"}"),
                       .init(sessionID: id, event: .notification("Claude needs your permission to use Bash")))
        XCTAssertEqual(AgentHooks.parse("\(id) Notification not-json"), .init(sessionID: id, event: .notification(nil)))
        XCTAssertNil(AgentHooks.parse("\(id) PreToolUse {}"))
        XCTAssertNil(AgentHooks.parse("nope Stop"))
        XCTAssertNil(AgentHooks.parse(""))
    }

    func testEventStates() {
        XCTAssertEqual(AgentHooks.Event.promptSubmitted.state, .working)
        XCTAssertEqual(AgentHooks.Event.notification("x").state, .needsYou("x"))
        XCTAssertEqual(AgentHooks.Event.stop.state, .done)
    }

    func testHooksBeatHeuristics() {
        var t = CodingAgentTracker(now: t0)
        XCTAssertEqual(t.hook(.promptSubmitted, at: t0), .startedWorking)
        // Quiet output no longer ends the turn…
        t.output(at: t0.addingTimeInterval(1))
        XCTAssertNil(t.tick(at: t0.addingTimeInterval(30)))
        XCTAssertNil(t.nextTick)
        // …nor do titles or bells change it.
        XCTAssertNil(t.title("✳ task", at: t0.addingTimeInterval(31)))
        XCTAssertNil(t.attention(nil, at: t0.addingTimeInterval(32)))
        XCTAssertEqual(t.state, .working)
        XCTAssertEqual(t.hook(.notification("ok?"), at: t0.addingTimeInterval(40)), .needsYou("ok?"))
        XCTAssertNil(t.hook(.notification("ok?"), at: t0.addingTimeInterval(41)))
        // Answering resumes the turn.
        t.input(at: t0.addingTimeInterval(42))
        XCTAssertEqual(t.state, .working)
        XCTAssertEqual(t.hook(.stop, at: t0.addingTimeInterval(50)), .finished(8))
        // Typing the next prompt doesn't clear "done"; submitting it does.
        t.input(at: t0.addingTimeInterval(51))
        XCTAssertEqual(t.state, .done)
        XCTAssertEqual(t.hook(.promptSubmitted, at: t0.addingTimeInterval(52)), .startedWorking)
    }

    private func json(_ d: Data?) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: d ?? Data())) as? [String: Any] ?? [:]
    }

    func testMergeIntoEmpty() throws {
        let out = json(try AgentHooks.merged(settingsJSON: nil))
        let hooks = try XCTUnwrap(out["hooks"] as? [String: Any])
        XCTAssertEqual(Set(hooks.keys), Set(AgentHooks.Event.hookNames))
        XCTAssertTrue(AgentHooks.isInstalled(settingsJSON: try AgentHooks.merged(settingsJSON: Data())))
    }

    func testMergeKeepsUserHooksAndIsIdempotent() throws {
        let user = """
        {"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}],
         "PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"lint"}]}]}}
        """
        let first = try XCTUnwrap(try AgentHooks.merged(settingsJSON: Data(user.utf8)))
        let out = json(first)
        XCTAssertEqual(out["model"] as? String, "opus")
        let hooks = try XCTUnwrap(out["hooks"] as? [String: Any])
        XCTAssertEqual((hooks["PreToolUse"] as? [Any])?.count, 1)
        let stop = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        XCTAssertEqual(stop.count, 2)
        XCTAssertEqual(((stop[0]["hooks"] as? [[String: Any]])?.first?["command"] as? String), "say done")
        XCTAssertTrue(((stop[1]["hooks"] as? [[String: Any]])?.first?["command"] as? String)?
            .contains(AgentHooks.marker) == true)
        // Second install: nothing to write.
        XCTAssertNil(try AgentHooks.merged(settingsJSON: first))
        XCTAssertTrue(AgentHooks.isInstalled(settingsJSON: first))
        XCTAssertFalse(AgentHooks.isInstalled(settingsJSON: Data(user.utf8)))
    }

    func testMergeRejectsNonObject() {
        XCTAssertThrowsError(try AgentHooks.merged(settingsJSON: Data("[1]".utf8)))
    }
}
