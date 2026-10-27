import XCTest
@testable import WirelineCore

final class AgentHookTargetsTests: XCTestCase {
    let id = UUID()
    var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("wl-hooks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func t(_ a: CodingAgent) -> AgentHookTarget { AgentHookTarget.target(for: a)! }

    private func json(_ d: Data?) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: d ?? Data())) as? [String: Any] ?? [:]
    }

    func testParseAgentEvents() {
        XCTAssertEqual(AgentHooks.parse("\(id) codex:Stop {\"session_id\":\"th-1\"}"),
                       .init(sessionID: id, event: .stop, agent: .codex, agentSessionID: "th-1"))
        XCTAssertEqual(AgentHooks.parse("\(id) gemini:Notification {\"message\":\"ok?\"}"),
                       .init(sessionID: id, event: .notification("ok?"), agent: .gemini))
        XCTAssertEqual(AgentHooks.parse("\(id) cursor-agent:beforeSubmitPrompt {\"conversation_id\":\"c9\"}"),
                       .init(sessionID: id, event: .promptSubmitted, agent: .cursor, agentSessionID: "c9"))
        XCTAssertEqual(AgentHooks.parse("\(id) aider:waiting"), .init(sessionID: id, event: .stop, agent: .aider))
        XCTAssertEqual(AgentHooks.parse("\(id) opencode:permission {\"message\":\"Run ls\"}")?.event, .notification("Run ls"))
        XCTAssertNil(AgentHooks.parse("\(id) codex:PreToolUse {}"))
        XCTAssertNil(AgentHooks.parse("\(id) nobody:Stop"))
        XCTAssertNil(AgentHooks.parse("\(id) goose:Stop"))
        // Claude stays bare.
        XCTAssertEqual(AgentHooks.parse("\(id) Stop"), .init(sessionID: id, event: .stop))
    }

    func testClaudeTargetMatchesLegacy() throws {
        let legacy = json(try AgentHooks.merged(settingsJSON: nil))
        let new = json(try t(.claude).installed(into: nil))
        XCTAssertEqual(NSDictionary(dictionary: legacy), NSDictionary(dictionary: new))
    }

    func testGroupedJSONRoundTrip() throws {
        let user = #"{"model":"x","hooks":{"Stop":[{"hooks":[{"type":"command","command":"say hi"}]}]}}"#
        let target = t(.codex)
        let url = target.url(home: home)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(user.utf8).write(to: url)

        try target.install(home: home)
        XCTAssertTrue(target.isInstalled(home: home))
        let once = try Data(contentsOf: url)
        let hooks = try XCTUnwrap(json(once)["hooks"] as? [String: Any])
        XCTAssertEqual(Set(hooks.keys), ["UserPromptSubmit", "PermissionRequest", "Stop"])
        XCTAssertEqual((hooks["Stop"] as? [Any])?.count, 2)
        XCTAssertEqual(json(once)["model"] as? String, "x")
        XCTAssertEqual(try Data(contentsOf: url.appendingPathExtension("wireline-backup")), Data(user.utf8))

        try target.install(home: home)
        XCTAssertEqual(try Data(contentsOf: url), once)

        try target.uninstall(home: home)
        XCTAssertFalse(target.isInstalled(home: home))
        let back = json(try Data(contentsOf: url))
        XCTAssertEqual(NSDictionary(dictionary: back), NSDictionary(dictionary: json(Data(user.utf8))))
        XCTAssertNil(try target.uninstalled(from: try Data(contentsOf: url)))
    }

    func testFlatJSONCursor() throws {
        let user = #"{"version":1,"hooks":{"stop":[{"command":"./hooks/mine.sh"}]}}"#
        let target = t(.cursor)
        let out = try XCTUnwrap(try target.installed(into: Data(user.utf8)))
        let hooks = try XCTUnwrap(json(out)["hooks"] as? [String: Any])
        XCTAssertEqual((hooks["stop"] as? [Any])?.count, 2)
        XCTAssertNotNil(hooks["beforeSubmitPrompt"])
        XCTAssertTrue(target.isInstalled(out))
        let back = try XCTUnwrap(try target.uninstalled(from: out))
        XCTAssertEqual(NSDictionary(dictionary: json(back)), NSDictionary(dictionary: json(Data(user.utf8))))
        XCTAssertEqual(json(try target.installed(into: nil))["version"] as? Int, 1)
    }

    func testUnreadableJSONThrows() {
        XCTAssertThrowsError(try t(.gemini).installed(into: Data("{ // comment\n}".utf8)))
    }

    func testPluginFile() throws {
        let target = t(.opencode)
        let url = target.url(home: home)
        try target.install(home: home)
        XCTAssertTrue(target.isInstalled(home: home))
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("opencode:idle"))
        try target.uninstall(home: home)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        // Someone else's file with our name is left alone.
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("export const Mine = 1".utf8).write(to: url)
        XCTAssertThrowsError(try target.install(home: home))
        try target.uninstall(home: home)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testAiderYAML() throws {
        let target = t(.aider)
        let user = "model: sonnet\n# mine\nauto-commits: false\n"
        let out = try XCTUnwrap(try target.installed(into: Data(user.utf8)))
        let text = String(decoding: out, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix(user))
        XCTAssertTrue(text.contains("notifications: true"))
        XCTAssertTrue(text.contains("aider:waiting"))
        XCTAssertTrue(target.isInstalled(out))
        XCTAssertNil(try target.installed(into: out))
        XCTAssertEqual(String(decoding: try XCTUnwrap(target.uninstalled(from: out)), as: UTF8.self), user)
        XCTAssertNil(try target.uninstalled(from: Data(user.utf8)))

        XCTAssertThrowsError(try target.installed(into: Data("notifications-command: say hi\n".utf8)))
        XCTAssertThrowsError(try target.installed(into: Data("notifications: false\n".utf8)))
        let enabled = try XCTUnwrap(try target.installed(into: Data("notifications: true\n".utf8)))
        XCTAssertEqual(String(decoding: enabled, as: UTF8.self).components(separatedBy: "notifications: true").count, 2)
        XCTAssertTrue(String(decoding: try XCTUnwrap(target.installed(into: nil)), as: UTF8.self).contains(AiderConfig.begin))
    }

    func testIncompleteHooksKeepGuessing() {
        var tr = CodingAgentTracker(now: Date(timeIntervalSince1970: 0))
        tr.hook(.stop, at: Date(timeIntervalSince1970: 1), exclusive: false)
        XCTAssertFalse(tr.hookDriven)
        XCTAssertEqual(tr.state, .done)
    }

    func testCommandsCarryMarker() {
        for target in AgentHookTarget.all {
            for (name, _) in target.events {
                XCTAssertTrue(target.command(for: name).contains(AgentHooks.marker) || {
                    if case .plugin = target.format { return true } else { return false }
                }())
            }
        }
        XCTAssertTrue(t(.codex).command(for: "Stop").contains("codex:Stop"))
        XCTAssertFalse(t(.aider).command(for: "waiting").contains("tr -d"))
    }
}
