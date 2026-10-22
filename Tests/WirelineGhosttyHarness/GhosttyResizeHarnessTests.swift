import AppKit
import XCTest
import GhosttyKit
import SwiftTerm
@testable import Wireline

/// A live edge-drag resize on the libghostty engine must leave exactly one
/// clean prompt — no stacked prompts, no right-prompt copies scattered across
/// the screen. During a live drag `TerminalContainerView` sets the terminal's
/// frame on every frame, so this does the same to the view directly: many
/// small size steps a few ms apart, shrinking and growing.
///
/// The shell runs through Wireline's real zsh shim (`ZDOTDIR` shim + user
/// rc), once with a plain `PROMPT` / `RPROMPT` rc and once with the user's own
/// config when it uses powerlevel10k.
///
///   WIRELINE_GHOSTTY_HARNESS=1 swift test --filter GhosttyResizeHarnessTests
@MainActor
final class GhosttyResizeHarnessTests: XCTestCase {
    private func log(_ s: String) { print("[resize-harness] \(s)") }

    @discardableResult
    private func wait(_ timeout: TimeInterval, until done: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if done() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return done()
    }

    private func pump(_ seconds: TimeInterval) { _ = wait(seconds) { false } }

    private func read(_ view: GhosttyTerminalView, _ tag: ghostty_point_tag_e) -> [String] {
        guard let s = view.surface?.raw else { return [] }
        var text = ghostty_text_s()
        let sel = ghostty_selection_s(
            top_left: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        guard ghostty_surface_read_text(s, sel, &text) else { return [] }
        defer { ghostty_surface_free_text(s, &text) }
        return String(cString: text.text).components(separatedBy: "\n")
    }

    /// Non-empty rows of the whole screen (scrollback too: a stray prompt
    /// copy pushed off the top still counts).
    private func rows(_ view: GhosttyTerminalView) -> [String] {
        read(view, GHOSTTY_POINT_SCREEN).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private struct Run {
        let window: NSWindow
        let view: GhosttyTerminalView
        let io: TerminalIO
    }

    private func launch(userZDOTDIR: String) throws -> Run {
        guard ProcessInfo.processInfo.environment["WIRELINE_GHOSTTY_HARNESS"] == "1" else {
            throw XCTSkip("set WIRELINE_GHOSTTY_HARNESS=1 to run the libghostty harness (opens a window)")
        }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        setenv("GHOSTTY_RESOURCES_DIR", repo.appendingPathComponent("Vendor/ghostty-share/ghostty").path, 1)
        NSApplication.shared.setActivationPolicy(.accessory)
        XCTAssertTrue(GhosttyRuntime.shared.start(), "runtime: \(GhosttyRuntime.shared.failure ?? "?")")

        let window = NSWindow(contentRect: NSRect(x: 160, y: 160, width: 900, height: 420),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = "Wireline resize harness"
        window.isReleasedWhenClosed = false
        let view = GhosttyTerminalView(frame: window.contentView!.bounds)
        let io = TerminalIO(password: nil, autoSudo: false)
        // As TerminalSession.init wires it.
        view.io = io
        io.engine = view
        view.onInput = { [weak io] bytes in io?.send(bytes) }
        view.onGridResize = { [weak io] in io?.gridDidChange() }
        window.contentView!.addSubview(view)
        view.applyAppearance(TerminalAppearance(theme: .wireline, font: TerminalFont.preferred(size: 13)!,
                                                gpu: true, cursorShape: .bar, cursorBlink: false))
        window.orderFrontRegardless()            // never activate: don't steal focus
        pump(0.1)

        // TerminalSession.launch for a local zsh.
        guard let shim = TerminalSession.zshIntegrationZDOTDIR() else { throw XCTSkip("no zsh shim") }
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        env.append("LANG=en_US.UTF-8")
        env.removeAll { $0.hasPrefix("ZDOTDIR=") || $0.hasPrefix("PATH=") }
        env += ["ZDOTDIR=\(shim.path)", "WIRELINE_USER_ZDOTDIR=\(userZDOTDIR)",
                "PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"]
        io.start(executable: "/bin/zsh", args: ["-l"], environment: env, execName: "-zsh",
                 currentDirectory: NSHomeDirectory())
        return Run(window: window, view: view, io: io)
    }

    /// Shrink and grow by `step` points per frame, `frameMs` apart.
    private func drag(_ view: GhosttyTerminalView, from: CGFloat, to: CGFloat, step: CGFloat, frameMs: Double) {
        let h = view.frame.height
        var w = from
        let dir: CGFloat = to < from ? -1 : 1
        while dir < 0 ? w > to : w < to {
            w += dir * step
            view.setFrameSize(NSSize(width: w, height: h))
            RunLoop.main.run(until: Date().addingTimeInterval(frameMs / 1000))
        }
    }

    private func liveDrag(_ view: GhosttyTerminalView) {
        let w = view.frame.width
        drag(view, from: w, to: w - 420, step: 7, frameMs: 4)       // shrink past the prompt's width
        drag(view, from: w - 420, to: w, step: 9, frameMs: 6)       // and back
        drag(view, from: w, to: w - 250, step: 3, frameMs: 3)
        drag(view, from: w - 250, to: w - 60, step: 11, frameMs: 8)
    }

    private func finish(_ run: Run) {
        run.io.terminate()
        run.view.removeFromSuperview()
        run.window.close()
        pump(0.2)
    }

    /// The plain rc: a left prompt and an `RPROMPT`, marked only by the shim.
    func testLiveDragKeepsOnePromptWithRPROMPT() throws {
        let user = FileManager.default.temporaryDirectory.appendingPathComponent("wl-resize-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: user) }
        try """
            PROMPT='wlp %~ %# '
            RPROMPT='RPMARK 🏠~'
            """.write(to: user.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        let run = try launch(userZDOTDIR: user.path)
        defer { finish(run) }
        XCTAssertTrue(wait(10) { rows(run.view).contains { $0.contains("RPMARK") } }, "prompt: \(rows(run.view))")
        // Some history above the prompt, then a fresh prompt at the bottom.
        run.view.send(txt: "for i in {1..5}; do echo out-$i; done\r")
        XCTAssertTrue(wait(5) { rows(run.view).last?.contains("RPMARK") == true && rows(run.view).contains("out-5") })
        pump(0.3)
        let before = rows(run.view)

        liveDrag(run.view)
        pump(1.0)

        let after = rows(run.view)
        let prompts = after.filter { $0.contains("wlp") }
        let rights = after.filter { $0.contains("RPMARK") }
        log("plain rc: before \(before.count) rows, after \(after.count) rows; grid \(run.view.gridSize.ws_col)×\(run.view.gridSize.ws_row)\n"
            + after.suffix(8).joined(separator: "\n"))
        // The command line keeps its prompt (and zsh leaves its RPROMPT on
        // it): one there, one live — no copies.
        XCTAssertEqual(prompts.count, 2, "prompt lines:\n\(after.joined(separator: "\n"))")
        XCTAssertEqual(rights.count, 2, "right-prompt copies:\n\(after.joined(separator: "\n"))")
        XCTAssertTrue(after.last?.hasPrefix("wlp") == true && after.last?.hasSuffix("RPMARK 🏠~") == true,
                      "live prompt is one clean line: \(after.last ?? "")")
        XCTAssertEqual(after.filter { $0.hasPrefix("out-") }.count, 5, "history kept")
    }

    /// The user's own config, when it's powerlevel10k (POWERLEVEL9K_TERM_SHELL_INTEGRATION).
    func testLiveDragWithUsersP10k() throws {
        let home = NSHomeDirectory()
        guard FileManager.default.fileExists(atPath: home + "/.p10k.zsh") else { throw XCTSkip("no ~/.p10k.zsh") }
        let run = try launch(userZDOTDIR: home)
        defer { finish(run) }
        XCTAssertTrue(wait(15) { !rows(run.view).isEmpty })
        pump(2.0)                                   // instant prompt → real prompt, gitstatus
        run.view.send(txt: "clear\r")
        pump(1.5)
        let before = rows(run.view)
        XCTAssertEqual(before.last, "❯", "p10k prompt up: \(before)")

        liveDrag(run.view)
        pump(1.5)

        // p10k's two-line prompt: ` ~ <padding> system` (home glyph + dir,
        // right-aligned context padded to the full width), then `❯`. The
        // first line is what used to scatter: every stray copy brings a `~`.
        let after = rows(run.view)
        let tildes = { (r: [String]) in r.reduce(0) { $0 + $1.filter { $0 == "~" }.count } }
        log("p10k: before \(before.count) rows, \(tildes(before)) ~; after \(after.count) rows, \(tildes(after)) ~\n"
            + after.joined(separator: "\n"))
        XCTAssertEqual(after.count, before.count, "prompt rows:\n\(after.joined(separator: "\n"))")
        XCTAssertEqual(tildes(after), tildes(before), "prompt copies:\n\(after.joined(separator: "\n"))")
        XCTAssertEqual(after.last, "❯", "live prompt ends the screen")
    }
}
