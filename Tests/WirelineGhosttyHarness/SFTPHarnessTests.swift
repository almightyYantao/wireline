import Foundation
import XCTest
@testable import Wireline

/// Chunked SFTP transfers (the file browser's queue) end to end against the
/// xrdp test container's sshd (`wl-xrdp`: 127.0.0.1:12222, test / Test1234):
/// pipelined upload and download, stopping halfway and resuming from the
/// offset, and walking a folder tree.
///
///   WIRELINE_SFTP_HARNESS=1 swift test --filter SFTPHarnessTests
final class SFTPHarnessTests: XCTestCase {
    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["WIRELINE_SFTP_HARNESS"] == "1" else {
            throw XCTSkip("set WIRELINE_SFTP_HARNESS=1 to run against the wl-xrdp container")
        }
    }

    private func connect() async throws -> SFTPConnection {
        let c = SFTPConnection()
        _ = try await c.connectAndList(hostname: "127.0.0.1", port: 12222, user: "test", credential: .password("Test1234"))
        return c
    }

    /// Counts bytes and stops once `stopAfter` have landed (nil: never).
    private final class Meter: @unchecked Sendable {
        private let lock = NSLock()
        private var count: UInt64 = 0
        let stopAfter: UInt64?
        init(stopAfter: UInt64? = nil) { self.stopAfter = stopAfter }
        var total: UInt64 { lock.withLock { count } }
        func step(_ n: UInt64) -> Bool {
            lock.withLock {
                count += n
                return stopAfter.map { count < $0 } ?? true
            }
        }
    }

    func testUploadDownloadWithResume() async throws {
        let c = try await connect()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wl-sftp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Not a multiple of any chunk size, so the tail is a short piece.
        var bytes = [UInt8](repeating: 0, count: 3_217_123)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        let source = dir.appendingPathComponent("src.bin")
        try Data(bytes).write(to: source)
        let remote = "/tmp/wl-sftp-\(UUID().uuidString).bin"

        // Upload: stop after ~1 MB, then resume from what landed.
        let up1 = Meter(stopAfter: 1_000_000)
        let doneEarly = try await c.upload(source, to: remote, from: 0) { up1.step($0) }
        XCTAssertFalse(doneEarly)
        XCTAssertGreaterThan(up1.total, 0)
        let up2 = Meter()
        let doneUp = try await c.upload(source, to: remote, from: up1.total) { up2.step($0) }
        XCTAssertTrue(doneUp)
        XCTAssertEqual(up1.total + up2.total, UInt64(bytes.count))
        let st = await c.stat(remote)
        XCTAssertEqual(st?.size, UInt64(bytes.count))
        XCTAssertEqual(st?.isDir, false)

        // Download the same way.
        let target = dir.appendingPathComponent("dst.bin")
        let down1 = Meter(stopAfter: 1_500_000)
        let partial = try await c.download(remote, to: target, from: 0) { down1.step($0) }
        XCTAssertFalse(partial)
        let down2 = Meter()
        let doneDown = try await c.download(remote, to: target, from: down1.total) { down2.step($0) }
        XCTAssertTrue(doneDown)
        XCTAssertEqual(try Data(contentsOf: target), Data(bytes))

        // A fresh download (offset 0) over an existing file replaces it.
        try Data(repeating: 7, count: 5_000_000).write(to: target)
        _ = try await c.download(remote, to: target, from: 0) { _ in true }
        XCTAssertEqual(try Data(contentsOf: target), Data(bytes))

        try await c.remove(remote, isDir: false)
        await c.close()
    }

    func testWalkAndMakeDirectory() async throws {
        let c = try await connect()
        let root = "/tmp/wl-walk-\(UUID().uuidString)"
        try await c.makeDirectoryIfMissing(root)
        try await c.makeDirectoryIfMissing(root)          // already there: fine
        try await c.makeDirectoryIfMissing("\(root)/a")
        try await c.makeDirectoryIfMissing("\(root)/a/b")
        try await c.upload(root + "/a/b/f.txt", data: Data("hi".utf8))
        try await c.upload(root + "/top.txt", data: Data("x".utf8))
        let tree = try await c.walk(root)
        XCTAssertEqual(Set(tree.map(\.relative)), ["a", "a/b", "a/b/f.txt", "top.txt"])
        XCTAssertEqual(tree.first { $0.relative == "a/b/f.txt" }?.size, 2)
        // Parents come before their children (the queue creates folders first).
        let order = tree.map(\.relative)
        XCTAssertLessThan(order.firstIndex(of: "a")!, order.firstIndex(of: "a/b")!)
        try await c.remove(root + "/a/b/f.txt", isDir: false)
        try await c.remove(root + "/a/b", isDir: true)
        try await c.remove(root + "/a", isDir: true)
        try await c.remove(root + "/top.txt", isDir: false)
        try await c.remove(root, isDir: true)
        await c.close()
    }
}
