import AppKit
import XCTest
import SwiftTerm
import WirelineCore
@testable import Wireline

/// The reconnect reset (`TerminalModeReset.afterChildExit`) on the SwiftTerm
/// engine: modes off, screen and scrollback kept, cursor where it was. (The
/// libghostty side is checked in `GhosttyHarnessTests`.) No window or shell,
/// so it always runs.
@MainActor
final class SwiftTermModeResetTests: XCTestCase {
    private func lines(_ t: Terminal) -> [String] {
        (0 ..< t.rows).map { row in
            t.getLine(row: row).map { line in
                (0 ..< t.cols).map { String(line[$0].getCharacter()) }.joined()
                    .replacingOccurrences(of: "\u{0}", with: " ")
                    .trimmingCharacters(in: .whitespaces)
            } ?? ""
        }
    }

    private func feed(_ view: WirelineTerminalView, _ s: String) { view.feed(text: s) }

    func testResetAfterChildDiedInFullScreenApp() {
        let view = WirelineTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 480))
        let t = view.getTerminal()
        // Scrollback from earlier, then a prompt, then a TUI that dies mid-screen.
        for i in 0 ..< (t.rows + 10) { feed(view, "history \(i)\r\n") }
        feed(view, "wl% htop")
        let cursorBefore = t.getCursorLocation()
        feed(view, "\u{1b}[?1049h\u{1b}[2J\u{1b}[5;20r\u{1b}[?1000h\u{1b}[?1006h\u{1b}[?1004h\u{1b}[?2004h"
             + "\u{1b}[?1h\u{1b}=\u{1b}[?25l\u{1b}[1;31;44m\u{1b}[10;10HTUI SCREEN")
        XCTAssertTrue(t.isCurrentBufferAlternate)
        XCTAssertNotEqual(t.mouseMode, .off)

        feed(view, TerminalModeReset.afterChildExit)

        XCTAssertFalse(t.isCurrentBufferAlternate)
        XCTAssertEqual(t.mouseMode, .off)
        XCTAssertFalse(t.bracketedPasteMode)
        XCTAssertFalse(t.applicationCursor)
        XCTAssertEqual(t.getCursorLocation().x, cursorBefore.x)
        XCTAssertEqual(t.getCursorLocation().y, cursorBefore.y)
        XCTAssertEqual(t.buffer.scrollTop, 0)
        XCTAssertEqual(t.buffer.scrollBottom, t.rows - 1)
        let screen = lines(t)
        XCTAssertEqual(screen.last { !$0.isEmpty }, "wl% htop")
        XCTAssertFalse(screen.contains { $0.contains("TUI SCREEN") })
        let saved = String(decoding: view.renderedBuffer, as: UTF8.self)
        XCTAssertTrue(saved.contains("history 0") && saved.contains("history \(t.rows + 9)"), "scrollback kept: \(saved.debugDescription)")
        XCTAssertGreaterThan(t.getTopVisibleRow(), 0)

        // The separator lands on the next line, in default colours.
        feed(view, "\r\nreconnecting\r\n")
        let after = lines(t)
        let mark = after.firstIndex(of: "wl% htop")
        XCTAssertNotNil(mark)
        if let mark { XCTAssertEqual(after[mark + 1], "reconnecting") }
        if let mark, let attr = t.getLine(row: mark + 1)?[0].attribute {
            XCTAssertEqual(attr.fg, .defaultColor)
            XCTAssertEqual(attr.bg, .defaultColor)
            XCTAssertEqual(attr.style, .none)
        }

        // Already on the primary screen (the usual case): nothing moves.
        feed(view, "wl% ")
        let before = t.getCursorLocation()
        feed(view, TerminalModeReset.afterChildExit)
        XCTAssertEqual(t.getCursorLocation().x, before.x)
        XCTAssertEqual(t.getCursorLocation().y, before.y)
    }
}
