import Foundation
import CGhosttyVt

/// One session's authoritative screen state in the agent: a headless
/// libghostty-vt terminal fed every byte the PTY produces. It answers the
/// program's queries (device attributes, cursor and color reports) through
/// `onReply`, and encodes a snapshot for a client that attaches.
///
/// Not thread-safe: the owning session calls it from its own queue.
final class VTTerminal {
    private var terminal: GhosttyTerminal?
    /// Bytes the terminal writes back to the program (query replies).
    var onReply: (([UInt8]) -> Void)?

    /// Unfinished escape sequences at a snapshot cut are carried in the
    /// snapshot (its CONTINUATION); tracking must be on before the bytes.
    private static let continuationLimit = 1 << 20
    static let defaultScrollbackBytes = 50_000_000

    init?(cols: UInt16, rows: UInt16) {
        var t: GhosttyTerminal?
        guard ghostty_terminal_new(nil, &t, max(cols, 1), max(rows, 1)) == GHOSTTY_SUCCESS, let t else { return nil }
        terminal = t
        var limit = Self.continuationLimit
        _ = ghostty_terminal_set(t, GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES, &limit)
        // libghostty-vt keeps only 10 KB of scrollback by default; match
        // Ghostty's `scrollback-limit-bytes` default until the app says otherwise.
        var scrollback = Self.defaultScrollbackBytes
        _ = ghostty_terminal_set(t, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &scrollback)
        _ = ghostty_terminal_set(t, GHOSTTY_TERMINAL_OPT_USERDATA, Unmanaged.passUnretained(self).toOpaque())
        let write: GhosttyTerminalWritePtyFn = { _, userdata, data, len in
            guard let userdata, let data, len > 0 else { return }
            let me = Unmanaged<VTTerminal>.fromOpaque(userdata).takeUnretainedValue()
            me.onReply?(Array(UnsafeBufferPointer(start: data, count: len)))
        }
        _ = ghostty_terminal_set(t, GHOSTTY_TERMINAL_OPT_WRITE_PTY, unsafeBitCast(write, to: UnsafeRawPointer.self))
    }

    deinit { ghostty_terminal_free(terminal) }

    func write(_ bytes: UnsafeBufferPointer<UInt8>) {
        guard let terminal, let base = bytes.baseAddress, !bytes.isEmpty else { return }
        ghostty_terminal_vt_write(terminal, base, bytes.count)
    }

    func write(_ bytes: [UInt8]) { bytes.withUnsafeBufferPointer { write($0) } }

    func resize(cols: UInt16, rows: UInt16, cellWidth: UInt32 = 0, cellHeight: UInt32 = 0) {
        guard let terminal else { return }
        _ = ghostty_terminal_resize(terminal, max(cols, 1), max(rows, 1), cellWidth, cellHeight)
    }

    /// The complete state as a snapshot (`snapshot.h`), nil on failure.
    func snapshot() -> [UInt8]? {
        guard let terminal else { return nil }
        var ptr: UnsafeMutablePointer<UInt8>?
        var len = 0
        guard ghostty_snapshot_encode_alloc(terminal, nil, &ptr, &len) == GHOSTTY_SUCCESS, let ptr else { return nil }
        defer { ghostty_free(nil, ptr, len) }
        return Array(UnsafeBufferPointer(start: ptr, count: len))
    }
}
