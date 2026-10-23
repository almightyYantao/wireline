import XCTest
import CoreGraphics
@testable import WirelineCore

/// The notch island's pure parts: attention sniffing, the coding-agent
/// heuristics, the board's show / grow / shrink rules, and notch geometry.
final class AttentionSniffingTests: XCTestCase {
    private func events(_ chunks: [String]) -> [TerminalStreamSniffer.Event] {
        var s = TerminalStreamSniffer()
        return chunks.flatMap { s.feed(Array($0.utf8)) }
    }

    func testBareBellButNotOSCTerminator() {
        XCTAssertEqual(events(["done\u{07}"]), [.bell])
        // BEL ending an OSC is a terminator, not a bell.
        XCTAssertEqual(events(["\u{1b}]0;title\u{07}"]), [])
    }

    func testOSC9() {
        XCTAssertEqual(events(["\u{1b}]9;Claude needs your permission\u{07}"]),
                       [.notification(title: "", body: "Claude needs your permission")])
        // Split across reads, ST terminator.
        XCTAssertEqual(events(["\u{1b}]9;Task ", "done\u{1b}", "\\"]),
                       [.notification(title: "", body: "Task done")])
        // ConEmu sub-commands (9;4 progress) aren't messages…
        XCTAssertEqual(events(["\u{1b}]9;4;1;50\u{07}\u{1b}]9;12\u{07}"]), [])
        // …but a message that merely starts with a number is.
        XCTAssertEqual(events(["\u{1b}]9;3 files changed\u{07}"]),
                       [.notification(title: "", body: "3 files changed")])
        XCTAssertEqual(events(["\u{1b}]9;\u{07}"]), [])
    }

    func testOSC777() {
        XCTAssertEqual(events(["\u{1b}]777;notify;Claude Code;Waiting for input; really\u{07}"]),
                       [.notification(title: "Claude Code", body: "Waiting for input; really")])
        XCTAssertEqual(events(["\u{1b}]777;notify;Only title\u{07}"]),
                       [.notification(title: "Only title", body: "")])
        XCTAssertEqual(events(["\u{1b}]777;other;x\u{07}"]), [])
    }

    func testOSC99() {
        XCTAssertEqual(events(["\u{1b}]99;;Hello\u{1b}\\"]), [.notification(title: "", body: "Hello")])
        XCTAssertEqual(events(["\u{1b}]99;i=1:p=title;Build\u{1b}\\"]), [.notification(title: "Build", body: "")])
        XCTAssertEqual(events(["\u{1b}]99;i=1:e=1;SGVsbG8=\u{1b}\\"]), [])
    }

    func testExistingEventsUnchanged() {
        XCTAssertEqual(events(["\u{1b}]7;file://h/x\u{07}\u{07}\u{1b}]133;C\u{07}"]),
                       [.workingDirectory("file://h/x"), .bell, .commandStarted])
    }
}

final class CodingAgentTrackerTests: XCTestCase {
    let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
    func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    func testAgentNames() {
        XCTAssertEqual(CodingAgent(processName: "claude"), .claude)
        XCTAssertEqual(CodingAgent(processName: "Codex"), .codex)
        XCTAssertEqual(CodingAgent(processName: "cursor-agent"), .cursor)
        XCTAssertNil(CodingAgent(processName: "node"))
    }

    /// Feed output every 0.1s over [from, to].
    func stream(_ t: inout CodingAgentTracker, _ from: TimeInterval, _ to: TimeInterval) -> [CodingAgentTracker.Change] {
        var changes: [CodingAgentTracker.Change] = []
        var s = from
        while s <= to + 1e-9 { if let c = t.output(at: at(s)) { changes.append(c) }; s += 0.1 }
        return changes
    }

    func testSustainedOutputIsWorkingThenQuietIsDone() {
        var t = CodingAgentTracker(now: t0)
        XCTAssertEqual(stream(&t, 0, 0.5), [])              // a short redraw isn't work
        XCTAssertEqual(t.state, .idle)
        XCTAssertEqual(stream(&t, 0.6, 3), [.startedWorking])
        XCTAssertEqual(t.state, .working)
        XCTAssertNil(t.tick(at: at(4)))                      // not quiet long enough
        XCTAssertEqual(t.nextTick, at(3).addingTimeInterval(CodingAgentTracker.quietAfter))
        guard case .finished(let ran)? = t.tick(at: at(3 + CodingAgentTracker.quietAfter)) else {
            return XCTFail("expected finished")
        }
        XCTAssertEqual(ran, 2.0, accuracy: 0.11)             // from when it was judged working
        XCTAssertEqual(t.state, .done)
    }

    func testTypingEchoIsNotWork() {
        var t = CodingAgentTracker(now: t0)
        var s = 0.0
        while s < 4 {                                        // type a key, echo follows, repeatedly
            t.input(at: at(s))
            XCTAssertNil(t.output(at: at(s + 0.05)))
            s += 0.2
        }
        XCTAssertEqual(t.state, .idle)
        // After the user stops (pressed Return), the burst that keeps going is work.
        XCTAssertEqual(stream(&t, 4, 6), [.startedWorking])
    }

    func testAttentionHoldsUntilTyping() {
        var t = CodingAgentTracker(now: t0)
        _ = stream(&t, 0, 2)
        XCTAssertEqual(t.attention("needs permission", at: at(2.1)), .needsYou("needs permission"))
        XCTAssertNil(t.attention("needs permission", at: at(2.2)))   // repeats are one request
        XCTAssertEqual(stream(&t, 3, 6), [])                 // output alone doesn't clear it
        XCTAssertNil(t.tick(at: at(20)))
        XCTAssertEqual(t.state, .needsYou("needs permission"))
        t.input(at: at(21))
        XCTAssertEqual(t.state, .idle)
        XCTAssertEqual(stream(&t, 22.2, 24), [.startedWorking])
    }

    func testTitleHints() {
        XCTAssertEqual(CodingAgentTracker.titleHint("⠐ Fixing the build"), .working)
        XCTAssertEqual(CodingAgentTracker.titleHint("✳ Fixing the build"), .idle)
        XCTAssertNil(CodingAgentTracker.titleHint("user@host: ~"))
        XCTAssertNil(CodingAgentTracker.titleHint("⠀ blank braille"))
        var t = CodingAgentTracker(now: t0)
        XCTAssertEqual(t.title("⠂ Refactor", at: at(1)), .startedWorking)
        XCTAssertNil(t.title("⠐ Refactor", at: at(1.1)))
        XCTAssertEqual(t.title("✳ Refactor", at: at(9)), .finished(8))
        XCTAssertEqual(t.state, .done)
        t.input(at: at(10))
        XCTAssertEqual(t.state, .idle)
    }
}

final class IslandBoardTests: XCTestCase {
    let t0 = Date(timeIntervalSinceReferenceDate: 2_000_000)
    func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    func item(_ id: String, _ tone: IslandTone, confirmation: IslandConfirmation? = nil,
              persistent: Bool = false, at s: TimeInterval = 0) -> IslandItem {
        IslandItem(id: id, source: .ai, title: id, detail: "", tone: tone,
                   confirmation: confirmation, persistent: persistent, at: at(s))
    }

    func testHiddenWhenEmpty() {
        let b = IslandBoard()
        XCTAssertEqual(b.mode(at: t0, hovering: false, alwaysShow: false), .hidden)
        XCTAssertEqual(b.mode(at: t0, hovering: true, alwaysShow: false), .hidden)
        XCTAssertEqual(b.mode(at: t0, hovering: false, alwaysShow: true), .collapsed)
        XCTAssertEqual(b.mode(at: t0, hovering: true, alwaysShow: true), .expanded)
        XCTAssertEqual(b.status(at: t0), .none)
    }

    func testWorkingCollapsedHoverExpands() {
        var b = IslandBoard()
        b.upsert(item("a", .working), at: t0)
        b.upsert(item("b", .working), at: t0)
        XCTAssertEqual(b.mode(at: t0, hovering: false, alwaysShow: false), .collapsed)
        XCTAssertEqual(b.mode(at: t0, hovering: true, alwaysShow: false), .expanded)
        XCTAssertEqual(b.status(at: t0), .working(2))
        XCTAssertEqual(b.leadSource, .ai)
    }

    func testFinishPulsesThenLingersThenGoes() {
        var b = IslandBoard()
        b.upsert(item("a", .working), at: t0)
        b.finish("a", success: true, detail: "完成", pulse: "✓ 完成 · 12s", at: at(12))
        guard case .pulse(let p) = b.mode(at: at(12.5), hovering: false, alwaysShow: false) else {
            return XCTFail("expected pulse")
        }
        XCTAssertEqual(p.text, "✓ 完成 · 12s")
        XCTAssertEqual(b.status(at: at(13)), .success)
        let afterPulse = at(12 + b.pulseLength + 0.1)
        b.prune(at: afterPulse)
        XCTAssertEqual(b.mode(at: afterPulse, hovering: false, alwaysShow: false), .collapsed)
        XCTAssertEqual(b.nextDeadline(after: afterPulse), at(12 + b.linger))
        b.prune(at: at(12 + b.linger))
        XCTAssertTrue(b.items.isEmpty)
        XCTAssertEqual(b.mode(at: at(12 + b.linger), hovering: false, alwaysShow: false), .hidden)
    }

    func testConfirmationForcesOpenUntilDismissedOrAnswered() {
        var b = IslandBoard()
        let c = IslandConfirmation(kind: .dangerousCommand, subject: "rm -rf /tmp/x")
        b.upsert(item("ai", .working), at: t0)
        b.upsert(item("ai", .attention, confirmation: c), at: at(1))
        XCTAssertEqual(b.mode(at: at(100), hovering: false, alwaysShow: false), .expanded)
        XCTAssertEqual(b.status(at: at(1)), .attention(1))
        XCTAssertEqual(b.ordered.first?.id, "ai")
        b.dismissAttention()
        XCTAssertEqual(b.mode(at: at(100), hovering: false, alwaysShow: false), .collapsed)
        // A different question re-opens it.
        b.upsert(item("ai", .attention, confirmation: IslandConfirmation(kind: .toolCall, subject: "x.y")), at: at(101))
        XCTAssertEqual(b.mode(at: at(102), hovering: false, alwaysShow: false), .expanded)
        // Answered elsewhere: back to working, no longer forced.
        b.upsert(item("ai", .working), at: at(103))
        XCTAssertEqual(b.mode(at: at(103), hovering: false, alwaysShow: false), .collapsed)
        XCTAssertEqual(b.item("ai")?.startedAt, t0)          // same row throughout
    }

    func testAttentionWithoutConfirmationPeeksThenFolds() {
        var b = IslandBoard()
        b.upsert(item("agent", .attention, persistent: true), at: t0)
        XCTAssertEqual(b.mode(at: at(1), hovering: false, alwaysShow: false), .expanded)
        XCTAssertEqual(b.nextDeadline(after: at(1)), at(b.attentionPeek))
        XCTAssertEqual(b.mode(at: at(b.attentionPeek), hovering: false, alwaysShow: false), .collapsed)
    }

    func testQuietPersistentRowsLeaveIslandDormant() {
        var b = IslandBoard()
        b.upsert(item("agent", .working, persistent: true), at: t0)
        b.finish("agent", success: true, detail: "done", pulse: nil, at: at(5))
        b.prune(at: at(500))
        XCTAssertEqual(b.items.count, 1)                     // still listed while the process runs
        XCTAssertEqual(b.mode(at: at(500), hovering: false, alwaysShow: false), .dormant)
        XCTAssertEqual(b.mode(at: at(500), hovering: true, alwaysShow: false), .expanded)
        XCTAssertEqual(b.status(at: at(500)), .none)
        XCTAssertNil(b.nextDeadline(after: at(500)))
    }

    func testOrderingAndFailureStatus() {
        var b = IslandBoard()
        b.upsert(item("ok", .working), at: t0)
        b.upsert(item("bad", .working), at: t0)
        b.upsert(item("run", .working), at: t0)
        b.finish("ok", success: true, detail: "", pulse: nil, at: at(1))
        b.finish("bad", success: false, detail: "exit 1", pulse: nil, at: at(2))
        XCTAssertEqual(b.ordered.map(\.id), ["run", "bad", "ok"])
        XCTAssertEqual(b.status(at: at(3)), .working(1))
        b.remove("run")
        XCTAssertEqual(b.status(at: at(3)), .failure)
    }

    func testDurations() {
        XCTAssertEqual(islandDuration(12.4), "12s")
        XCTAssertEqual(islandDuration(185), "3m 05s")
        XCTAssertEqual(islandDuration(3720), "1h 02m")
    }
}

final class NotchGeometryTests: XCTestCase {
    // A 14" MacBook Pro: 1512×982 points, 32pt menu bar / notch.
    let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let visible = CGRect(x: 0, y: 0, width: 1512, height: 950)

    func testHardwareNotch() {
        let g = NotchGeometry.resolve(frame: frame, visibleFrame: visible, safeAreaTop: 32,
                                      auxiliaryLeft: CGRect(x: 0, y: 950, width: 661, height: 32),
                                      auxiliaryRight: CGRect(x: 846, y: 950, width: 666, height: 32))
        XCTAssertTrue(g.hasNotch)
        XCTAssertEqual(g.anchor, CGRect(x: 661, y: 950, width: 185, height: 32))
        let panel = g.panelFrame(cardSize: CGSize(width: 420, height: 300), in: frame)
        XCTAssertEqual(panel.maxY, frame.maxY)
        XCTAssertEqual(panel.midX, g.anchor.midX, accuracy: 1)
        XCTAssertEqual(panel.height, 300)
    }

    func testNoNotchFallsBackToPillUnderMenuBar() {
        // An external display at an offset, no safe area.
        let ext = CGRect(x: 1512, y: -200, width: 2560, height: 1440)
        let extVisible = CGRect(x: 1512, y: -200, width: 2560, height: 1415)
        let g = NotchGeometry.resolve(frame: ext, visibleFrame: extVisible, safeAreaTop: 0,
                                      auxiliaryLeft: nil, auxiliaryRight: nil)
        XCTAssertFalse(g.hasNotch)
        XCTAssertEqual(g.anchor.size, NotchGeometry.pillSize)
        XCTAssertEqual(g.anchor.midX, ext.midX, accuracy: 1)
        XCTAssertEqual(g.anchor.maxY, ext.maxY - 25 - NotchGeometry.pillGap)
    }

    func testHiddenMenuBarAndBogusAuxiliaryAreas() {
        // Menu bar auto-hidden: visible frame reaches the top.
        let g = NotchGeometry.resolve(frame: frame, visibleFrame: frame, safeAreaTop: 0,
                                      auxiliaryLeft: nil, auxiliaryRight: nil)
        XCTAssertEqual(g.anchor.maxY, frame.maxY - NotchGeometry.pillGap)
        // A safe area but auxiliary strips that don't leave a plausible notch.
        let bogus = NotchGeometry.resolve(frame: frame, visibleFrame: visible, safeAreaTop: 32,
                                          auxiliaryLeft: CGRect(x: 0, y: 950, width: 100, height: 32),
                                          auxiliaryRight: CGRect(x: 1400, y: 950, width: 112, height: 32))
        XCTAssertFalse(bogus.hasNotch)
    }

    func testPanelStaysOnScreen() {
        let g = NotchGeometry(anchor: CGRect(x: 10, y: 950, width: 100, height: 32), hasNotch: true)
        let panel = g.panelFrame(cardSize: CGSize(width: 420, height: 200), in: frame)
        XCTAssertEqual(panel.minX, 0)
    }
}
