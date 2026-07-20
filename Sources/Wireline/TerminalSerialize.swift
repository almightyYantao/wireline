import Foundation
import SwiftTerm

/// Color-preserving buffer serialization for cross-launch scrollback restore.
///
/// `Terminal.getBufferAsData()` flattens the grid to plain text and drops every
/// color / style, so a restored tab comes back monochrome. This walks the full
/// buffer (scrollback + visible screen) cell by cell and re-emits the content as
/// a byte stream carrying SGR escapes — the same idea as xterm.js's SerializeAddon.
///
/// The output is deliberately "inert": it contains **only** SGR color/style
/// sequences, printable text, and CRLF line breaks. No cursor movement, no
/// screen clears, no alt-screen toggles. That makes it safe to `feed()` straight
/// back into a fresh terminal on relaunch without corrupting the live session.
extension Terminal {
    /// Serialize the whole buffer to a replayable, colored byte stream.
    /// - Parameter maxLines: keep only the last N lines (bounded history).
    func serializeColored(maxLines: Int = 4000) -> Data {
        // Serializing the alternate screen (e.g. quitting while inside vim/htop)
        // would capture a transient full-screen UI, not the shell history. Skip it;
        // the caller keeps the previous snapshot instead.
        guard !isCurrentBufferAlternate else { return Data() }

        // `getScrollInvariantLine` is valid for rows in
        // `totalLinesTrimmed ..< totalLinesTrimmed + lines.count` and returns nil
        // past the end, so we can discover the range through public API alone.
        var lines: [BufferLine] = []
        var row = buffer.totalLinesTrimmed
        while let line = getScrollInvariantLine(row: row) {
            lines.append(line)
            row += 1
        }

        // Stop at the cursor's line — i.e. drop the current (idle or half-typed)
        // prompt and every blank screen row below it. Persisting those would (a)
        // leave a big empty gap on restore and (b) accumulate one dead prompt line
        // on every relaunch, since each launch's fresh prompt would be re-saved as
        // history. The cursor's index into `lines` equals its buffer index,
        // `buffer.y + buffer.yDisp` (yDisp == yBase when scrolled to the bottom,
        // which is the normal state at quit). A fresh prompt is drawn on relaunch.
        let cursorIndex = buffer.y + buffer.yDisp
        if cursorIndex >= 0 && cursorIndex < lines.count {
            lines.removeLast(lines.count - cursorIndex)
        }
        // Drop any trailing blank lines (e.g. prompt spacing) left above the cut.
        while let last = lines.last, last.getTrimmedLength() == 0 { lines.removeLast() }

        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }

        var out: [UInt8] = []
        out.reserveCapacity(lines.count * 128)
        let crlf: [UInt8] = [0x0d, 0x0a]

        for line in lines {
            // Reset at the start of every line so each line is self-contained — a
            // truncated tail can never leak a stale color into the restored view.
            out.append(contentsOf: sgrReset)
            var prev = Attribute.empty
            let trimmed = line.getTrimmedLength()
            var col = 0
            while col < trimmed {
                // Width-0 cells are the trailing half of a wide (CJK) glyph; the
                // character lives in the preceding cell, so skip them.
                if line.getWidth(index: col) == 0 { col += 1; continue }
                let cell = line[col]
                let attr = cell.attribute
                if attr != prev {
                    out.append(contentsOf: sgr(for: attr))
                    prev = attr
                }
                appendUTF8(cell.getCharacter(), to: &out)
                col += 1
            }
            out.append(contentsOf: sgrReset)
            out.append(contentsOf: crlf)
        }
        return Data(out)
    }
}

// MARK: - SGR encoding

private let sgrReset: [UInt8] = Array("\u{1b}[0m".utf8)

/// Build a full "reset + reapply" SGR sequence for an attribute. Emitting the
/// leading `0` means we never have to compute a diff against the previous state —
/// each sequence fully defines the run that follows it.
private func sgr(for a: Attribute) -> [UInt8] {
    var params = [0]
    params.append(contentsOf: styleParams(a.style))
    params.append(contentsOf: foregroundParams(a.fg))
    params.append(contentsOf: backgroundParams(a.bg))
    let body = params.map(String.init).joined(separator: ";")
    return Array("\u{1b}[\(body)m".utf8)
}

private func styleParams(_ style: CharacterStyle) -> [Int] {
    var p: [Int] = []
    if style.contains(.bold)       { p.append(1) }
    if style.contains(.dim)        { p.append(2) }
    if style.contains(.italic)     { p.append(3) }
    if style.contains(.underline)  { p.append(4) }
    if style.contains(.blink)      { p.append(5) }
    if style.contains(.inverse)    { p.append(7) }
    if style.contains(.invisible)  { p.append(8) }
    if style.contains(.crossedOut) { p.append(9) }
    return p
}

private func foregroundParams(_ c: Attribute.Color) -> [Int] {
    switch c {
    case .defaultColor, .defaultInvertedColor:
        return [39]
    case .ansi256(let code):
        if code < 8  { return [30 + Int(code)] }
        if code < 16 { return [90 + Int(code) - 8] }
        return [38, 5, Int(code)]
    case .trueColor(let r, let g, let b):
        return [38, 2, Int(r), Int(g), Int(b)]
    }
}

private func backgroundParams(_ c: Attribute.Color) -> [Int] {
    switch c {
    case .defaultColor, .defaultInvertedColor:
        return [49]
    case .ansi256(let code):
        if code < 8  { return [40 + Int(code)] }
        if code < 16 { return [100 + Int(code) - 8] }
        return [48, 5, Int(code)]
    case .trueColor(let r, let g, let b):
        return [48, 2, Int(r), Int(g), Int(b)]
    }
}

private func appendUTF8(_ ch: Character, to out: inout [UInt8]) {
    for scalar in ch.unicodeScalars {
        out.append(contentsOf: Array(String(scalar).utf8))
    }
}
