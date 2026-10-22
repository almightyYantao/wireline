import XCTest
@testable import WirelineCore

/// The libghostty engine relies on this to learn a remote shell's directory
/// (libghostty drops non-local OSC 7) and the focus-report / alternate-screen
/// modes, so it has to hold up against real streams: sequences split across
/// reads, both OSC terminators, and noise it must ignore.
final class TerminalStreamSnifferTests: XCTestCase {
    private func events(_ chunks: [String]) -> [TerminalStreamSniffer.Event] {
        var s = TerminalStreamSniffer()
        return chunks.flatMap { s.feed(Array($0.utf8)) }
    }

    func testOSC7WithBothTerminators() {
        XCTAssertEqual(events(["\u{1b}]7;file://web-1/var/log\u{07}"]), [.workingDirectory("file://web-1/var/log")])
        XCTAssertEqual(events(["a\u{1b}]7;file:///tmp\u{1b}\\b"]), [.workingDirectory("file:///tmp")])
    }

    func testSplitAcrossReads() {
        XCTAssertEqual(events(["\u{1b}", "]7;file://h/a", "/b\u{1b}", "\\", "\u{1b}[?10", "49h"]),
                       [.workingDirectory("file://h/a/b"), .privateMode(1049, true)])
    }

    func testPrivateModes() {
        XCTAssertEqual(events(["\u{1b}[?1004h\u{1b}[?1049;2004l"]),
                       [.privateMode(1004, true), .privateMode(1049, false), .privateMode(2004, false)])
        // Not private (no '?'), and other finals, are ignored.
        XCTAssertEqual(events(["\u{1b}[4h\u{1b}[?25$p\u{1b}[31m"]), [])
    }

    func testIgnoresOtherOSCsAndHugePayloads() {
        XCTAssertEqual(events(["\u{1b}]0;title\u{07}\u{1b}]133;A\u{07}"]), [])
        let big = String(repeating: "x", count: 10_000)
        XCTAssertEqual(events(["\u{1b}]7;\(big)\u{07}\u{1b}[?1004h"]), [.privateMode(1004, true)])
    }

    func testCommandStart() {
        // C (with or without options) is reported; A / B / D and look-alikes aren't.
        XCTAssertEqual(events(["\u{1b}]133;A\u{07}wl% \u{1b}]133;B\u{07}", "\u{1b}]133;C\u{07}out\u{1b}]133;D;0\u{07}"]),
                       [.commandStarted])
        XCTAssertEqual(events(["\u{1b}]133;C;cmdline=ls\u{1b}", "\\"]), [.commandStarted])
        XCTAssertEqual(events(["\u{1b}]133;Cx\u{07}\u{1b}]1133;C\u{07}"]), [])
    }

    func testCancelledSequences() {
        // CAN aborts the OSC; the next one still parses.
        XCTAssertEqual(events(["\u{1b}]7;file://x/a\u{18}\u{1b}]7;file://x/b\u{07}"]), [.workingDirectory("file://x/b")])
    }
}
