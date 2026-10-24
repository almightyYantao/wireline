import Foundation

/// Cuts a libghostty-vt terminal snapshot (`snapshot.h`) at record
/// boundaries for the session agent's attach: the renderable prefix through
/// READY goes first, then history in chunks that each end right after a PAGE
/// record (or with FINISH) — the unit `ghostty_surface_io_restore_history`
/// takes.
///
/// Format: a 10-byte envelope ("GHOSTSNP" + u16 version), then records of
/// `u16 tag | u32 payload length | u32 CRC32C | payload`, little-endian.
public enum SnapshotFraming {
    public static let magic = Array("GHOSTSNP".utf8)
    public static let envelopeSize = 10
    public static let recordHeaderSize = 10

    public enum Tag: UInt16 {
        case terminal = 1, screen, page, history, ready, finish, continuation
    }

    public enum Failure: Error, Equatable {
        case badEnvelope, truncated, noReady, noFinish
    }

    public struct Parts: Equatable {
        /// Envelope through the READY record.
        public var ready: [UInt8]
        /// The rest through FINISH, each chunk ending after a PAGE record
        /// (the last one with FINISH).
        public var history: [[UInt8]]
    }

    /// The snapshot format version, if `bytes` starts with an envelope.
    public static func version(of bytes: [UInt8]) -> UInt16? {
        guard bytes.count >= envelopeSize, Array(bytes[0..<8]) == magic else { return nil }
        return UInt16(bytes[8]) | UInt16(bytes[9]) << 8
    }

    /// Split a complete snapshot. History chunks gather pages until at least
    /// `chunkBytes`, so a long scrollback isn't thousands of messages.
    public static func split(_ bytes: [UInt8], chunkBytes: Int = 256 * 1024) throws -> Parts {
        guard version(of: bytes) != nil else { throw Failure.badEnvelope }
        var pos = envelopeSize
        var readyEnd: Int?
        var history: [[UInt8]] = []
        var chunkStart = 0
        while pos < bytes.count {
            guard pos + recordHeaderSize <= bytes.count else { throw Failure.truncated }
            let tag = UInt16(bytes[pos]) | UInt16(bytes[pos + 1]) << 8
            let len = Int(bytes[pos + 2]) | Int(bytes[pos + 3]) << 8 | Int(bytes[pos + 4]) << 16 | Int(bytes[pos + 5]) << 24
            let end = pos + recordHeaderSize + len
            guard end <= bytes.count else { throw Failure.truncated }
            pos = end
            if readyEnd == nil {
                if tag == Tag.ready.rawValue { readyEnd = end; chunkStart = end }
                continue
            }
            if tag == Tag.finish.rawValue || (tag == Tag.page.rawValue && end - chunkStart >= chunkBytes) {
                history.append(Array(bytes[chunkStart..<end]))
                chunkStart = end
                if tag == Tag.finish.rawValue {
                    return Parts(ready: Array(bytes[0..<readyEnd!]), history: history)
                }
            }
        }
        throw readyEnd == nil ? Failure.noReady : Failure.noFinish
    }
}
