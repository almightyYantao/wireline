import AppKit
import XCTest
import GhosttyKit
import WirelineCore
@testable import Wireline

/// A real `TerminalSession` (libghostty + `AgentPTY`) living in a real
/// `wireline-agent`: the app "quits" (drops its connection), a new session
/// attaches to the same agent session, and finds the same shell — its screen
/// restored, its state intact.
///
///   WIRELINE_GHOSTTY_HARNESS=1 swift test --filter AgentSessionHarnessTests
@MainActor
final class AgentSessionHarnessTests: XCTestCase {
    private var dir = ""
    private var agent: Process?

    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["WIRELINE_GHOSTTY_HARNESS"] == "1" else {
            throw XCTSkip("set WIRELINE_GHOSTTY_HARNESS=1 (opens a window)")
        }
        dir = "/tmp/wl-agent-h-\(UUID().uuidString.prefix(6))"
        let p = Process()
        p.executableURL = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("wireline-agent")
        p.arguments = ["serve", "--socket", dir + "/s.sock", "--idle-exit", "30", "--foreground"]
        // xctest (Apple-signed) on one side: the debug-only escape hatch, both ends.
        p.environment = ProcessInfo.processInfo.environment.merging(["WIRELINE_AGENT_TRUST_ANY": "1"]) { $1 }
        setenv("WIRELINE_AGENT_TRUST_ANY", "1", 1)
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        agent = p
        AgentClient.shared.socketPath = dir + "/s.sock"
        UserDefaults.standard.set(true, forKey: "sessionAgent")
        _ = wait(3) { FileManager.default.fileExists(atPath: self.dir + "/s.sock") }
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: "sessionAgent")
        unsetenv("WIRELINE_AGENT_TRUST_ANY")
        agent?.terminate()
        agent?.waitUntilExit()
        try? FileManager.default.removeItem(atPath: dir)
    }

    @discardableResult
    private func wait(_ timeout: TimeInterval, until done: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if done() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return done()
    }

    private func screen(_ s: TerminalSession) -> String {
        guard let v = s.terminalView as? GhosttyTerminalView, let raw = v.surface?.raw else { return "" }
        var t = ghostty_text_s()
        let sel = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        guard ghostty_surface_read_text(raw, sel, &t) else { return "" }
        defer { ghostty_surface_free_text(raw, &t) }
        return String(cString: t.text)
    }

    private func host(_ s: TerminalSession, in window: NSWindow) {
        s.terminalView.frame = window.contentView!.bounds
        s.terminalView.applyAppearance(TerminalAppearance(theme: .wireline, font: TerminalFont.preferred(size: 13)!,
                                                          gpu: true, cursorShape: .block, cursorBlink: false))
        window.contentView!.subviews.forEach { $0.removeFromSuperview() }
        window.contentView!.addSubview(s.terminalView)
        _ = wait(0.3) { false }                    // the grid reaches the PTY size
    }

    func testSessionSurvivesTheAppAndReattaches() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        setenv("GHOSTTY_RESOURCES_DIR", repo.appendingPathComponent("Vendor/ghostty-share/ghostty").path, 1)
        NSApplication.shared.setActivationPolicy(.accessory)
        XCTAssertTrue(GhosttyRuntime.shared.start())
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 700, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()

        // 1. A local shell in the agent.
        let first = TerminalSession(kind: .localShell, title: "Local Shell")
        let agentPTY = try XCTUnwrap(first.io.agent, "lives in the agent")
        host(first, in: window)
        first.start()
        XCTAssertTrue(wait(10) { first.connectionState == .connected }, "connected")
        XCTAssertFalse(agentPTY.runsLocally)
        _ = wait(3) { !self.screen(first).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        first.io.send(txt: "export WLMARK=survived-$((40+2)); echo marker-one\r")
        XCTAssertTrue(wait(5) { self.screen(first).contains("marker-one") }, screen(first))
        let pid = agentPTY.pid
        XCTAssertGreaterThan(pid, 0)
        let id = agentPTY.id

        // 2. The app "quits": the connection goes, the session stays.
        AgentClient.shared.disconnect()
        let alive = expectation(description: "listed")
        var listed: [AgentSessionInfo] = []
        Task { listed = await AgentClient.shared.listSessions(); alive.fulfill() }
        wait(for: [alive], timeout: 5)
        XCTAssertEqual(listed.map(\.id), [id])
        XCTAssertEqual(listed.first?.state, .running)
        XCTAssertEqual(listed.first?.pid, pid, "same process")

        // 3. A new launch attaches to it.
        let second = TerminalSession(kind: .localShell, title: "Local Shell", attachingToAgent: id)
        host(second, in: window)
        second.start()
        XCTAssertTrue(wait(5) { self.screen(second).contains("marker-one") }, "restored screen: \(screen(second))")
        XCTAssertTrue(wait(5) { second.connectionState == .connected })
        second.io.send(txt: "echo mark=$WLMARK\r")
        XCTAssertTrue(wait(5) { self.screen(second).contains("mark=survived-42") }, "same shell: \(screen(second))")

        // 4. Closing the tab ends it in the agent too.
        second.terminate()
        let gone = expectation(description: "listed again")
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            listed = await AgentClient.shared.listSessions()
            gone.fulfill()
        }
        wait(for: [gone], timeout: 5)
        XCTAssertTrue(listed.isEmpty, "closed: \(listed)")
        window.close()
    }

    private func setUpWindow() -> NSWindow {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        setenv("GHOSTTY_RESOURCES_DIR", repo.appendingPathComponent("Vendor/ghostty-share/ghostty").path, 1)
        NSApplication.shared.setActivationPolicy(.accessory)
        XCTAssertTrue(GhosttyRuntime.shared.start())
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 700, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        return window
    }

    /// No agent to be had: the session runs in the app instead, and works.
    func testFallsBackToALocalPTY() throws {
        let window = setUpWindow()
        AgentClient.shared.disconnect()
        AgentClient.shared.socketPath = dir + "/nobody-here.sock"
        defer { AgentClient.shared.socketPath = dir + "/s.sock" }
        let s = TerminalSession(kind: .localShell, title: "Local Shell")
        host(s, in: window)
        s.start()
        XCTAssertTrue(wait(10) { s.io.agent?.runsLocally == true }, "fell back")
        s.io.send(txt: "echo local-$((1+2))\r")
        XCTAssertTrue(wait(5) { self.screen(s).contains("local-3") }, screen(s))
        s.terminate()
        window.close()
    }

    /// SSH (password via askpass) against the wl-xrdp container's sshd
    /// (127.0.0.1:12222, test / Test1234): survives the app, reattaches.
    /// Skipped unless WIRELINE_SSH_HARNESS=1.
    func testSSHSessionSurvivesTheApp() throws {
        guard ProcessInfo.processInfo.environment["WIRELINE_SSH_HARNESS"] == "1" else {
            throw XCTSkip("set WIRELINE_SSH_HARNESS=1 with the wl-xrdp container running")
        }
        let window = setUpWindow()
        let known = dir + "/known_hosts"
        let args = ["-p", "12222", "-o", "UserKnownHostsFile=\(known)", "-o", "PubkeyAuthentication=no"]
        let kind = SessionKind.ssh(alias: "test@127.0.0.1", password: "Test1234", sudoPassword: nil, autoSudo: false, args: args)
        let first = TerminalSession(kind: kind, title: "ssh")
        host(first, in: window)
        first.start()
        let agentPTY = try XCTUnwrap(first.io.agent)
        XCTAssertTrue(wait(20) { self.screen(first).contains("$") || self.screen(first).contains("#") }, screen(first))
        first.io.send(txt: "export WLMARK=ssh-$((6*7)); echo ssh-marker\r")
        XCTAssertTrue(wait(5) { self.screen(first).contains("ssh-marker") }, screen(first))
        let id = agentPTY.id

        AgentClient.shared.disconnect()
        let second = TerminalSession(kind: kind, title: "ssh", attachingToAgent: id)
        host(second, in: window)
        second.start()
        XCTAssertTrue(wait(5) { self.screen(second).contains("ssh-marker") }, "restored: \(screen(second))")
        second.io.send(txt: "echo mark=$WLMARK\r")
        XCTAssertTrue(wait(5) { self.screen(second).contains("mark=ssh-42") }, "same ssh session: \(screen(second))")
        second.terminate()
        window.close()
    }

    /// The agent dies: the session shows as disconnected; Reconnect starts it
    /// again in a fresh agent.
    func testAgentCrashThenReconnect() throws {
        let window = setUpWindow()
        let s = TerminalSession(kind: .localShell, title: "Local Shell")
        host(s, in: window)
        s.start()
        XCTAssertTrue(wait(10) { s.connectionState == .connected })
        s.io.send(txt: "echo before-crash\r")
        XCTAssertTrue(wait(5) { self.screen(s).contains("before-crash") })

        kill(agent!.processIdentifier, SIGKILL)
        agent!.waitUntilExit()
        XCTAssertTrue(wait(5) { s.connectionState == .disconnected }, "crash shows as a disconnect")

        // A new agent (the app would start one beside itself).
        let p = Process()
        p.executableURL = agent!.executableURL
        p.arguments = agent!.arguments
        p.environment = agent!.environment
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        agent = p
        _ = wait(3) { (try? AgentConnection.connect(path: self.dir + "/s.sock")).map { close($0); return true } ?? false }

        s.reconnect()
        XCTAssertTrue(wait(10) { s.connectionState == .connected }, "reconnected")
        s.io.send(txt: "echo after-$((2+3))\r")
        XCTAssertTrue(wait(5) { self.screen(s).contains("after-5") }, screen(s))
        XCTAssertTrue(screen(s).contains("before-crash"), "the old screen stays above")
        XCTAssertEqual(s.io.agent?.runsLocally, false, "back in the agent")
        s.terminate()
        window.close()
    }
}
