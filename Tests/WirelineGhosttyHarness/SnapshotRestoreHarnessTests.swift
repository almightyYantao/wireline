import AppKit
import XCTest
import GhosttyKit
import WirelineCore
@testable import Wireline

/// The session agent's attach, end to end on real libghostty surfaces: one
/// surface is fed a whole byte stream; another restores the agent's
/// snapshot of a prefix of it (`wireline-agent snapshot`, libghostty-vt),
/// prepends the history and is fed the rest. Both must end up identical —
/// screen, scrollback, the unfinished escape sequence at the cut — and the
/// restored one must not answer queries while replies are off.
///
///   WIRELINE_GHOSTTY_HARNESS=1 swift test --filter SnapshotRestoreHarnessTests
@MainActor
final class SnapshotRestoreHarnessTests: XCTestCase {
    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["WIRELINE_GHOSTTY_HARNESS"] == "1" else {
            throw XCTSkip("set WIRELINE_GHOSTTY_HARNESS=1 (opens a window)")
        }
    }

    private func wait(_ timeout: TimeInterval, until done: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if done() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return done()
    }

    private func text(_ view: GhosttyTerminalView, _ tag: ghostty_point_tag_e) -> String {
        guard let s = view.surface?.raw else { return "" }
        var t = ghostty_text_s()
        let sel = ghostty_selection_s(
            top_left: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        guard ghostty_surface_read_text(s, sel, &t) else { return "" }
        defer { ghostty_surface_free_text(s, &t) }
        return String(cString: t.text)
    }

    private func feed(_ view: GhosttyTerminalView, _ bytes: [UInt8]) {
        guard let s = view.surface?.raw else { return }
        bytes.withUnsafeBufferPointer { ghostty_surface_io_feed(s, $0.baseAddress, UInt($0.count)) }
    }

    /// `wireline-agent snapshot`, built next to this test bundle.
    private func agentSnapshot(_ bytes: [UInt8], cols: UInt16, rows: UInt16) throws -> [UInt8] {
        let bin = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("wireline-agent")
        let p = Process()
        p.executableURL = bin
        p.arguments = ["snapshot", "\(cols)", "\(rows)"]
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        try p.run()
        input.fileHandleForWriting.write(Data(bytes))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        return [UInt8](data)
    }

    /// A shell-like stream: prompts with OSC 133 marks, colored output long
    /// enough for plenty of scrollback, a title, wide characters.
    private func session(lines: Int) -> [UInt8] {
        var s = "\u{1b}]2;restore-test\u{7}"
        for i in 0..<lines {
            s += "\u{1b}]133;A\u{7}wl% \u{1b}]133;B\u{7}echo \(i)\r\n\u{1b}]133;C\u{7}"
            s += "\u{1b}[3\(i % 7 + 1)mline \(i)\u{1b}[0m 宽字符 \u{1b}[1mbold\u{1b}[0m\r\n\u{1b}]133;D;0\u{7}"
        }
        return Array(s.utf8)
    }

    func testRestoredSurfaceMatchesDirectlyFed() throws {
        // Cut inside an SGR sequence, so the snapshot carries a continuation.
        let before = session(lines: 400) + Array("\u{1b}[3".utf8)
        let after = Array("2mafter the cut\u{1b}[0m\r\n".utf8) + session(lines: 30)
        let r = try checkRestore(before: before, after: after, minHistoryChunks: 2)
        XCTAssertTrue(r.contains("after the cut"))
        XCTAssertTrue(r.contains("line 399 "), "history restored")
    }

    /// Cut while a full-screen program owns the alternate screen; it then
    /// exits and the shell's screen (with its history) comes back.
    func testRestoreInsideAlternateScreen() throws {
        var app = "\u{1b}[?1049h\u{1b}[2J\u{1b}[H"
        for row in 1...20 { app += "\u{1b}[\(row);1H~\u{1b}[\(row);10H\u{1b}[7mrow \(row)\u{1b}[0m" }
        app += "\u{1b}[22;1H-- INSERT --\u{1b}[5;12H"
        let before = session(lines: 120) + Array(app.utf8)
        let after = Array("typed\u{1b}[?1049l".utf8) + session(lines: 5)
        let r = try checkRestore(before: before, after: after)
        XCTAssertTrue(r.contains("line 119 "))
        XCTAssertFalse(r.contains("-- INSERT --"), "back on the primary screen")
    }

    /// Feed `before + after` to one surface; restore the agent's snapshot of
    /// `before` into another and feed it `after` (part of it before history
    /// arrives). Asserts they match; returns the restored screen text.
    @discardableResult
    private func checkRestore(before: [UInt8], after: [UInt8], minHistoryChunks: Int = 1) throws -> String {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        setenv("GHOSTTY_RESOURCES_DIR", repo.appendingPathComponent("Vendor/ghostty-share/ghostty").path, 1)
        NSApplication.shared.setActivationPolicy(.accessory)
        XCTAssertTrue(GhosttyRuntime.shared.start(), "runtime: \(GhosttyRuntime.shared.failure ?? "?")")

        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1300, height: 420),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1300, height: 420))
        window.contentView = content
        let direct = GhosttyTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 420))
        let restored = GhosttyTerminalView(frame: NSRect(x: 660, y: 0, width: 640, height: 420))
        var replies: [UInt8] = []
        restored.onInput = { replies += $0 }
        for v in [direct, restored] {
            v.applyAppearance(TerminalAppearance(theme: .wireline, font: TerminalFont.preferred(size: 13)!,
                                                 gpu: true, cursorShape: .block, cursorBlink: false))
            content.addSubview(v)
        }
        window.orderFrontRegardless()
        _ = wait(0.5) { false }
        let grid = direct.gridSize
        XCTAssertEqual(grid.ws_col, restored.gridSize.ws_col)
        XCTAssertEqual(grid.ws_row, restored.gridSize.ws_row)

        feed(direct, before + after)

        if let s = restored.surface?.raw { ghostty_surface_io_set_replies(s, false) }
        let snap = try agentSnapshot(before, cols: grid.ws_col, rows: grid.ws_row)
        let parts = try SnapshotFraming.split(snap, chunkBytes: 64 * 1024)
        print("[restore] snapshot \(snap.count) B, ready \(parts.ready.count) B, \(parts.history.count) history chunks, grid \(grid.ws_col)×\(grid.ws_row)")
        XCTAssertGreaterThanOrEqual(parts.history.count, minHistoryChunks, "history chunks")
        let raw = try XCTUnwrap(restored.surface?.raw)
        parts.ready.withUnsafeBufferPointer { ghostty_surface_io_restore(raw, $0.baseAddress, UInt($0.count)) }
        // Live output arrives while history is still coming in.
        let early = min(40, after.count)
        feed(restored, Array(after.prefix(early)))
        for chunk in parts.history {
            chunk.withUnsafeBufferPointer { ghostty_surface_io_restore_history(raw, $0.baseAddress, UInt($0.count)) }
        }
        feed(restored, Array(after.dropFirst(early)))

        // A query: the restored surface must stay quiet (the agent answers).
        feed(restored, Array("\u{1b}[c\u{1b}[6n".utf8))
        feed(direct, Array("\u{1b}[c\u{1b}[6n".utf8))

        let same = wait(5) { text(direct, GHOSTTY_POINT_SCREEN) == text(restored, GHOSTTY_POINT_SCREEN) }
        let d = text(direct, GHOSTTY_POINT_SCREEN), r = text(restored, GHOSTTY_POINT_SCREEN)
        if !same {
            let dl = d.components(separatedBy: "\n"), rl = r.components(separatedBy: "\n")
            print("[restore] direct \(dl.count) rows, restored \(rl.count) rows")
            if let i = zip(dl, rl).enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset {
                print("[restore] first difference at row \(i):\n  direct:   \(dl[i])\n  restored: \(rl[i])")
            }
        }
        XCTAssertTrue(same, "screen + scrollback identical")
        XCTAssertEqual(text(direct, GHOSTTY_POINT_VIEWPORT), text(restored, GHOSTTY_POINT_VIEWPORT))
        XCTAssertTrue(replies.isEmpty, "restored surface replied to a query: \(replies)")
        window.close()
        return r
    }
}
