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

    /// A terminal restored from a complete snapshot (tests, debugging).
    init?(snapshot: [UInt8]) {
        var decoder: GhosttySnapshotDecoder?
        let made = snapshot.withUnsafeBufferPointer { ghostty_snapshot_decoder_new_buf(nil, &decoder, $0.baseAddress, $0.count) }
        guard made == GHOSTTY_SUCCESS, let decoder else { return nil }
        defer { ghostty_snapshot_decoder_free(decoder) }
        var t: GhosttyTerminal?
        guard ghostty_snapshot_decoder_decode(decoder, &t) == GHOSTTY_SUCCESS, let t else { return nil }
        terminal = t
    }

    deinit { ghostty_terminal_free(terminal) }

    /// The active screen as plain text, scrollback included.
    func plainText() -> String {
        guard let terminal else { return "" }
        var opts = GhosttyFormatterTerminalOptions()
        opts.size = MemoryLayout<GhosttyFormatterTerminalOptions>.size
        opts.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN
        opts.trim = true
        opts.extra.size = MemoryLayout<GhosttyFormatterTerminalExtra>.size
        opts.extra.screen.size = MemoryLayout<GhosttyFormatterScreenExtra>.size
        var f: GhosttyFormatter?
        guard ghostty_formatter_terminal_new(nil, &f, terminal, opts) == GHOSTTY_SUCCESS, let f else { return "" }
        defer { ghostty_formatter_free(f) }
        var ptr: UnsafeMutablePointer<UInt8>?
        var len = 0
        guard ghostty_formatter_format_alloc(f, nil, &ptr, &len) == GHOSTTY_SUCCESS, let ptr else { return "" }
        defer { ghostty_free(nil, ptr, len) }
        return String(decoding: UnsafeBufferPointer(start: ptr, count: len), as: UTF8.self)
    }

    func write(_ bytes: UnsafeBufferPointer<UInt8>) {
        guard let terminal, let base = bytes.baseAddress, !bytes.isEmpty else { return }
        ghostty_terminal_vt_write(terminal, base, bytes.count)
    }

    func write(_ bytes: [UInt8]) { bytes.withUnsafeBufferPointer { write($0) } }

    func resize(cols: UInt16, rows: UInt16, cellWidth: UInt32 = 0, cellHeight: UInt32 = 0) {
        guard let terminal else { return }
        _ = ghostty_terminal_resize(terminal, max(cols, 1), max(rows, 1), cellWidth, cellHeight)
    }

    /// Scrollback kept (the app's `scrollback-limit`).
    func setScrollback(bytes: Int) {
        guard let terminal else { return }
        var b = bytes
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &b)
    }

    /// The colors the attached app draws with, for OSC 10/11/12 replies.
    func setColors(foreground: (UInt8, UInt8, UInt8), background: (UInt8, UInt8, UInt8),
                   cursor: (UInt8, UInt8, UInt8)?) {
        guard let terminal else { return }
        var fg = GhosttyColorRgb(r: foreground.0, g: foreground.1, b: foreground.2)
        var bg = GhosttyColorRgb(r: background.0, g: background.1, b: background.2)
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &fg)
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &bg)
        if let cursor {
            var c = GhosttyColorRgb(r: cursor.0, g: cursor.1, b: cursor.2)
            _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, &c)
        } else {
            _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, nil)
        }
    }

    /// OSC 0/2 title, nil when unset.
    var title: String? { string(GHOSTTY_TERMINAL_DATA_TITLE) }
    /// OSC 7 (or 9 / 1337) working directory as reported — raw, often a file:// URI.
    var reportedDirectory: String? { string(GHOSTTY_TERMINAL_DATA_PWD) }

    private func string(_ data: GhosttyTerminalData) -> String? {
        guard let terminal else { return nil }
        var s = GhosttyString(ptr: nil, len: 0)
        guard ghostty_terminal_get(terminal, data, &s) == GHOSTTY_SUCCESS, let ptr = s.ptr, s.len > 0 else { return nil }
        return String(decoding: UnsafeBufferPointer(start: ptr, count: s.len), as: UTF8.self)
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
