import XCTest
@testable import WirelineCore

final class RemoteAssistTests: XCTestCase {
    func testGateNeedsMarks() {
        var g = RemotePromptGate()
        XCTAssertFalse(g.isOpen)
        g.commandStarted()
        XCTAssertFalse(g.isOpen)
        g.commandFinished()
        XCTAssertTrue(g.isOpen)
    }

    func testGateNesting() {
        var g = RemotePromptGate()
        g.commandFinished()
        g.submitted("ssh other")
        XCTAssertFalse(g.isOpen)
        g.submitted("exit")
        XCTAssertTrue(g.isOpen)
        g.submitted("sudo -i")
        g.endOfInput(lineWasEmpty: false)
        XCTAssertFalse(g.isOpen)
        g.endOfInput(lineWasEmpty: true)
        XCTAssertTrue(g.isOpen)
        g.submitted("exit")            // the outer shell's exit: no underflow
        XCTAssertEqual(g.nesting, 0)
    }

    func testOpensShell() {
        let yes = ["ssh host", "ssh -p 22 host", "mosh h", "su -", "sudo su", "sudo -i", "bash", "zsh -l",
                   "tmux", "tmux attach", "docker exec -it c sh", "kubectl exec -it p -- bash", "FOO=1 ssh h"]
        let no = ["ssh host uptime", "ssh -p 22 host ls -la", "bash -c x", "bash script.sh", "ls", "sudo ls",
                  "docker ps", "git status"]
        for s in yes { XCTAssertTrue(RemotePromptGate.opensShell(CompletionContext.parse(s + " ").words), s) }
        for s in no { XCTAssertFalse(RemotePromptGate.opensShell(CompletionContext.parse(s + " ").words), s) }
    }

    func testRemoteDirectory() {
        XCTAssertEqual(RemoteCompletionPaths.directory(for: "/etc/ng", cwd: nil), "/etc/")
        XCTAssertEqual(RemoteCompletionPaths.directory(for: "~/", cwd: nil), ".")
        XCTAssertEqual(RemoteCompletionPaths.directory(for: "~/src/a", cwd: nil), "src/")
        XCTAssertEqual(RemoteCompletionPaths.directory(for: "~", cwd: nil), ".")
        XCTAssertNil(RemoteCompletionPaths.directory(for: "~bob/", cwd: nil))
        XCTAssertNil(RemoteCompletionPaths.directory(for: "src/a", cwd: nil))
        XCTAssertEqual(RemoteCompletionPaths.directory(for: "src/a", cwd: "/var/www"), "/var/www/src/")
        XCTAssertEqual(RemoteCompletionPaths.directory(for: "a", cwd: "/"), "/")
        XCTAssertEqual(RemoteCompletionPaths.directory(for: "a", cwd: "~"), ".")
        XCTAssertEqual(RemoteCompletionPaths.directory(for: "x/", cwd: "~/proj"), "proj/x/")
    }

    func testParseOSC() {
        let json = Data(#"{"message":"Claude needs your permission","hook_event_name":"Notification"}"#.utf8)
        XCTAssertEqual(AgentHooks.parseOSC("Notification;" + json.base64EncodedString()),
                       .notification("Claude needs your permission"))
        XCTAssertEqual(AgentHooks.parseOSC("Stop;"), .stop)
        XCTAssertEqual(AgentHooks.parseOSC("UserPromptSubmit"), .promptSubmitted)
        XCTAssertNil(AgentHooks.parseOSC("PreToolUse;"))
        // Cut off by the size limit, but the message came first.
        let cut = Data(#"{"session_id":"x","message":"wait \"here\"","transcript_path":"/very/lo"#.utf8)
        XCTAssertEqual(AgentHooks.parseOSC("Notification;" + cut.base64EncodedString()), .notification("wait \"here\""))
    }

    func testSnifferSeesHook() {
        var s = TerminalStreamSniffer()
        let seq = Array("x\u{1b}]1337;WirelineHook=Stop;e30=\u{07}y".utf8)
        XCTAssertEqual(s.feed(seq[..<10]) + s.feed(seq[10...]), [.agentHook("Stop;e30=")])
    }

    func testRemoteMergeIsSeparate() throws {
        let local = try XCTUnwrap(AgentHooks.merged(settingsJSON: nil))
        XCTAssertTrue(AgentHooks.isInstalled(settingsJSON: local))
        XCTAssertFalse(AgentHooks.isInstalled(settingsJSON: local, remote: true))
        let both = try XCTUnwrap(AgentHooks.merged(settingsJSON: local, remote: true))
        XCTAssertTrue(AgentHooks.isInstalled(settingsJSON: both, remote: true))
        XCTAssertNil(try AgentHooks.merged(settingsJSON: both, remote: true))
        XCTAssertTrue(AgentHooks.remoteCommand(for: "Stop").contains("/dev/tty"))
    }

    /// The remote command really emits the OSC the sniffer reads.
    func testRemoteCommandOutput() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        let cmd = AgentHooks.remoteCommand(for: "Notification").replacingOccurrences(of: ">/dev/tty", with: "")
        p.arguments = ["-c", cmd]
        let inp = Pipe(), out = Pipe()
        p.standardInput = inp
        p.standardOutput = out
        try p.run()
        inp.fileHandleForWriting.write(Data(#"{"message":"hi there"}"#.utf8))
        try inp.fileHandleForWriting.close()
        p.waitUntilExit()
        var s = TerminalStreamSniffer()
        let events = s.feed(out.fileHandleForReading.readDataToEndOfFile())
        guard case let .agentHook(payload)? = events.first else { return XCTFail("\(events)") }
        XCTAssertEqual(AgentHooks.parseOSC(payload), .notification("hi there"))
    }
}
