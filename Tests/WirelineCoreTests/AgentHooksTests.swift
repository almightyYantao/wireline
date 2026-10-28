import XCTest
@testable import WirelineCore

final class AgentHooksTests: XCTestCase {
    let id = UUID()
    let t0 = Date(timeIntervalSince1970: 1_000)

    func testParse() {
        XCTAssertEqual(AgentHooks.parse("\(id) UserPromptSubmit {\"prompt\":\"hi\"}"),
                       .init(sessionID: id, event: .prompted("hi")))
        XCTAssertEqual(AgentHooks.parse("\(id) UserPromptSubmit"), .init(sessionID: id, event: .promptSubmitted))
        XCTAssertEqual(AgentHooks.parse("\(id) PreToolUse {\"tool_name\":\"Bash\"}"),
                       .init(sessionID: id, event: .toolStarted("Bash")))
        XCTAssertEqual(AgentHooks.parse("\(id) PermissionRequest {\"tool_name\":\"Edit\"}"),
                       .init(sessionID: id, event: .permission("Edit")))
        XCTAssertNil(AgentHooks.parse("\(id) Notification {\"notification_type\":\"idle_prompt\"}"))
        XCTAssertEqual(AgentHooks.parse("\(id) Stop \n"), .init(sessionID: id, event: .stop))
        XCTAssertEqual(AgentHooks.parse("\(id) Notification {\"message\":\"Claude needs your permission to use Bash\"}"),
                       .init(sessionID: id, event: .notification("Claude needs your permission to use Bash")))
        XCTAssertEqual(AgentHooks.parse("\(id) Notification not-json"), .init(sessionID: id, event: .notification(nil)))
        XCTAssertNil(AgentHooks.parse("\(id) Bogus {}"))
        XCTAssertNil(AgentHooks.parse("nope Stop"))
        XCTAssertNil(AgentHooks.parse(""))
    }

    func testEventStates() {
        XCTAssertEqual(AgentHooks.Event.promptSubmitted.state, .working)
        XCTAssertEqual(AgentHooks.Event.notification("x").state, .needsYou("x"))
        XCTAssertEqual(AgentHooks.Event.stop.state, .done)
    }

    func testRichHooks() {
        var t = CodingAgentTracker(now: t0)
        t.hook(.prompted("fix it"), at: t0)
        t.hook(.toolStarted("Bash"), at: t0)
        XCTAssertEqual(t.currentTool, "Bash")
        XCTAssertEqual(t.hook(.permission("Bash"), at: t0), .needsYou(nil))
        XCTAssertNil(t.hook(.notification("Claude needs your permission"), at: t0))
        XCTAssertEqual(t.hook(.toolFinished("Bash", failed: false), at: t0), .startedWorking)
        XCTAssertNil(t.permissionTool)
        // The main agent's Stop while a subagent runs isn't the end.
        t.hook(.subagentStarted, at: t0)
        XCTAssertNil(t.hook(.stop, at: t0))
        XCTAssertEqual(t.state, .working)
        t.hook(.subagentStopped, at: t0)
        XCTAssertEqual(t.hook(.stop, at: t0.addingTimeInterval(20)), .finished(20))
        XCTAssertEqual(t.lastPrompt, "fix it")
        XCTAssertEqual(t.toolCount, 1)
        t.hook(.promptSubmitted, at: t0)
        t.hook(.stopFailed("rate limited"), at: t0)
        XCTAssertEqual(t.state, .done)
        XCTAssertEqual(t.lastError, "rate limited")
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
        XCTAssertEqual((hooks["PreToolUse"] as? [Any])?.count, 2)   // the user's lint, then ours
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

    func testRemoveKeepsUserHooks() throws {
        let user = """
        {"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}],
         "PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"lint"}]}]}}
        """
        var installed = json(try XCTUnwrap(try AgentHooks.merged(settingsJSON: Data(user.utf8))))
        // A user hook sharing a group with ours survives.
        var hooks = installed["hooks"] as! [String: Any]
        var stop = hooks["Stop"] as! [[String: Any]]
        stop[1]["hooks"] = (stop[1]["hooks"] as! [Any]) + [["type": "command", "command": "afplay x"]]
        hooks["Stop"] = stop
        installed["hooks"] = hooks
        let data = try JSONSerialization.data(withJSONObject: installed)
        XCTAssertTrue(AgentHooks.hasAny(settingsJSON: data))

        let out = json(try XCTUnwrap(try AgentHooks.removed(settingsJSON: data)))
        XCTAssertEqual(out["model"] as? String, "opus")
        let left = try XCTUnwrap(out["hooks"] as? [String: Any])
        XCTAssertEqual(Set(left.keys), ["Stop", "PreToolUse"])
        let commands = (left["Stop"] as! [[String: Any]]).flatMap { ($0["hooks"] as! [[String: Any]]).map { $0["command"] as! String } }
        XCTAssertEqual(commands, ["say done", "afplay x"])
        XCTAssertFalse(AgentHooks.hasAny(settingsJSON: try JSONSerialization.data(withJSONObject: out)))
    }

    func testRemoveOnlyOursDropsHooksKey() throws {
        let installed = try XCTUnwrap(try AgentHooks.merged(settingsJSON: Data(#"{"model":"x"}"#.utf8)))
        let out = json(try XCTUnwrap(try AgentHooks.removed(settingsJSON: installed)))
        XCTAssertNil(out["hooks"])
        XCTAssertEqual(out["model"] as? String, "x")
        XCTAssertNil(try AgentHooks.removed(settingsJSON: Data(#"{"model":"x"}"#.utf8)))
        XCTAssertNil(try AgentHooks.removed(settingsJSON: nil))
    }

    func testMergeRejectsNonObject() {
        XCTAssertThrowsError(try AgentHooks.merged(settingsJSON: Data("[1]".utf8)))
    }
}
