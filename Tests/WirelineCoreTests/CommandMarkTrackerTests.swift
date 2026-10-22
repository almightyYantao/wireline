import XCTest
@testable import WirelineCore

final class CommandMarkTrackerTests: XCTestCase {
    func testInactiveUntilAMark() {
        var t = CommandMarkTracker()
        XCTAssertFalse(t.isActive)
        _ = t.started()
        XCTAssertTrue(t.isActive)
        var u = CommandMarkTracker()
        _ = u.finished()                 // D alone (first prompt's precmd) also counts
        XCTAssertTrue(u.isActive)
    }

    func testLongCommandGoesBusyThenIdle() {
        var t = CommandMarkTracker()
        let token = t.started()
        XCTAssertTrue(t.confirmBusy(token))
        XCTAssertTrue(t.isBusy)
        XCTAssertFalse(t.confirmBusy(token), "only once")
        XCTAssertTrue(t.finished(), "badge was on: turn it off")
        XCTAssertFalse(t.isBusy)
        XCTAssertFalse(t.isRunning)
    }

    func testShortCommandNeverGoesBusy() {
        var t = CommandMarkTracker()
        let token = t.started()
        XCTAssertFalse(t.finished())
        XCTAssertFalse(t.confirmBusy(token), "the delay fired after D")
        XCTAssertFalse(t.isBusy)
    }

    func testStaleTokenFromAnEarlierCommand() {
        var t = CommandMarkTracker()
        let first = t.started()
        _ = t.finished()
        let second = t.started()
        XCTAssertFalse(t.confirmBusy(first))
        XCTAssertTrue(t.confirmBusy(second))
    }

    func testResetMidCommand() {
        var t = CommandMarkTracker()
        let token = t.started()
        XCTAssertTrue(t.confirmBusy(token))
        t.reset()
        XCTAssertFalse(t.isBusy)
        XCTAssertFalse(t.isRunning)
        XCTAssertTrue(t.isActive, "marks stay trusted across a reconnect")
        XCTAssertFalse(t.finished())
    }
}
