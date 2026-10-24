import XCTest
@testable import WirelineCore

final class SnapshotFramingTests: XCTestCase {
    private func record(_ tag: SnapshotFraming.Tag, _ payload: [UInt8] = []) -> [UInt8] {
        let len = UInt32(payload.count)
        var r: [UInt8] = [UInt8(tag.rawValue & 0xff), UInt8(tag.rawValue >> 8)]
        r += [UInt8(len & 0xff), UInt8(len >> 8 & 0xff), UInt8(len >> 16 & 0xff), UInt8(len >> 24)]
        r += [0, 0, 0, 0]                          // CRC: not checked by the framing
        return r + payload
    }

    private var envelope: [UInt8] { SnapshotFraming.magic + [1, 0] }

    func testSplitsReadyAndHistoryAfterPages() throws {
        let prefix = envelope + record(.terminal, [1, 2]) + record(.screen, [3]) + record(.page, [4, 4])
            + record(.continuation) + record(.ready)
        let h1 = record(.history, [9]) + record(.page, Array(repeating: 5, count: 40))
        let h2 = record(.page, Array(repeating: 6, count: 40))
        let tail = record(.history, [8]) + record(.finish)   // a screen with no history pages
        let parts = try SnapshotFraming.split(prefix + h1 + h2 + tail, chunkBytes: 30)
        XCTAssertEqual(parts.ready, prefix)
        XCTAssertEqual(parts.history, [h1, h2, tail])
        XCTAssertEqual(SnapshotFraming.version(of: prefix), 1)
    }

    func testSmallHistoryIsOneChunk() throws {
        let prefix = envelope + record(.terminal) + record(.ready)
        let rest = record(.history) + record(.page, [1]) + record(.page, [2]) + record(.finish)
        XCTAssertEqual(try SnapshotFraming.split(prefix + rest).history, [rest])
    }

    func testRejectsBadInput() {
        XCTAssertThrowsError(try SnapshotFraming.split(Array("NOTASNAP..".utf8))) {
            XCTAssertEqual($0 as? SnapshotFraming.Failure, .badEnvelope)
        }
        let noFinish = envelope + record(.terminal) + record(.ready) + record(.history)
        XCTAssertThrowsError(try SnapshotFraming.split(noFinish)) {
            XCTAssertEqual($0 as? SnapshotFraming.Failure, .noFinish)
        }
        let cut = envelope + Array(record(.terminal, [1, 2, 3]).dropLast())
        XCTAssertThrowsError(try SnapshotFraming.split(cut)) {
            XCTAssertEqual($0 as? SnapshotFraming.Failure, .truncated)
        }
    }
}
