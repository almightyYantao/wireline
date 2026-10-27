import XCTest
@testable import WirelineCore

final class NotificationCardsTests: XCTestCase {
    private func card(_ l: CardLinger = .s5) -> NotificationCard {
        NotificationCard(title: "t", body: "b", session: nil, linger: l)
    }

    func testLingerCoding() {
        XCTAssertEqual(CardLinger(stored: nil), .standard)
        XCTAssertEqual(CardLinger(stored: "bogus"), .standard)
        for l in CardLinger.allCases { XCTAssertEqual(CardLinger(stored: l.rawValue), l) }
        XCTAssertEqual(CardLinger.standard.seconds, 5)
        XCTAssertEqual(CardLinger.s90.seconds, 90)
        XCTAssertNil(CardLinger.untilClosed.seconds)
    }

    func testQueueLimitsVisibleAndPromotes() {
        var q = CardQueue(maxVisible: 2)
        let a = card(), b = card(.s10), c = card()
        q.push(a); q.push(b); q.push(c)
        XCTAssertEqual(q.visible.map(\.id), [a.id, b.id])
        XCTAssertEqual(q.pending.map(\.id), [c.id])
        q.close(a.id)
        XCTAssertEqual(q.visible.map(\.id), [b.id, c.id])
        XCTAssertTrue(q.pending.isEmpty)
    }

    func testExpiryAndPause() {
        var q = CardQueue(maxVisible: 3)
        let a = card(.s5), b = card(.s10), c = card(.untilClosed)
        q.push(a); q.push(b); q.push(c)
        XCTAssertEqual(q.nextExpiry, 5)
        q.paused = true
        q.tick(100)
        XCTAssertEqual(q.visible.count, 3)
        XCTAssertNil(q.nextExpiry)
        q.paused = false
        q.tick(5)
        XCTAssertEqual(q.visible.map(\.id), [b.id, c.id])
        XCTAssertEqual(q.nextExpiry, 5)
        q.tick(6)
        XCTAssertEqual(q.visible.map(\.id), [c.id])
        XCTAssertNil(q.nextExpiry)
        q.tick(1000)
        XCTAssertEqual(q.visible.count, 1)
    }

    func testPendingDoesNotCountDown() {
        var q = CardQueue(maxVisible: 1)
        let a = card(.s5), b = card(.s5)
        q.push(a); q.push(b)
        q.tick(4)
        XCTAssertEqual(q.pending.first?.remaining, 5)
        q.tick(1)
        XCTAssertEqual(q.visible.map(\.id), [b.id])
        XCTAssertEqual(q.visible.first?.remaining, 5)
    }
}
