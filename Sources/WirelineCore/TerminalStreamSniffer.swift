import Foundation

/// Watches a terminal output stream for the few control sequences the app
/// needs to know about when the emulator itself won't say: the working
/// directory (OSC 7), a command starting (OSC 133;C), focus reporting
/// (DECSET 1004) and the alternate screen (DECSET 1049 / 1047 / 47).
///
/// libghostty parses everything, but only reports OSC 7 from the *local*
/// host — a remote shell's directory over SSH is dropped — it reports a
/// command's end (COMMAND_FINISHED) but not its start, and it has no API
/// for the private modes. This is a tiny escape-sequence state machine (no
/// rendering, no allocation in the common case) that survives sequences split
/// across reads.
public struct TerminalStreamSniffer: Sendable {
    public enum Event: Equatable, Sendable {
        /// The raw OSC 7 payload (`file://host/path`).
        case workingDirectory(String)
        /// OSC 133;C: the shell ran the command line; its output follows.
        case commandStarted
        /// A DEC private mode was set (`true`) or reset (`false`).
        case privateMode(Int, Bool)
    }

    private enum State: Sendable { case ground, escape, csi, osc, oscEscape, oscIgnore, oscIgnoreEscape }

    private var state: State = .ground
    private var buffer: [UInt8] = []
    /// OSC payloads longer than this are skipped (OSC 7 is a path; long OSCs
    /// are images and clipboard data).
    private let oscLimit = 4096
    private let csiLimit = 64

    public init() {}

    /// Feed a chunk; returns the events completed within it, in order.
    public mutating func feed<C: Collection>(_ bytes: C) -> [Event] where C.Element == UInt8 {
        var events: [Event] = []
        for b in bytes {
            switch state {
            case .ground:
                if b == 0x1B { state = .escape }
            case .escape:
                switch b {
                case UInt8(ascii: "["): state = .csi; buffer.removeAll(keepingCapacity: true)
                case UInt8(ascii: "]"): state = .osc; buffer.removeAll(keepingCapacity: true)
                case 0x1B: state = .escape
                default: state = .ground
                }
            case .csi:
                if b == 0x18 || b == 0x1A { state = .ground }
                else if b == 0x1B { state = .escape }
                else if (0x20...0x3F).contains(b) {
                    if buffer.count < csiLimit { buffer.append(b) } else { state = .ground }
                } else if (0x40...0x7E).contains(b) {
                    if b == UInt8(ascii: "h") || b == UInt8(ascii: "l") { privateModes(set: b == UInt8(ascii: "h"), into: &events) }
                    state = .ground
                }
                // Other C0 controls inside a CSI are executed and ignored.
            case .osc:
                if b == 0x07 { finishOSC(into: &events) }
                else if b == 0x1B { state = .oscEscape }
                else if b == 0x18 || b == 0x1A { state = .ground }
                else if buffer.count < oscLimit { buffer.append(b) }
                else { state = .oscIgnore; buffer.removeAll(keepingCapacity: true) }
            case .oscEscape:
                if b == UInt8(ascii: "\\") { finishOSC(into: &events) }
                else { buffer.removeAll(keepingCapacity: true); state = b == UInt8(ascii: "[") ? .csi : b == UInt8(ascii: "]") ? .osc : .ground }
            case .oscIgnore:
                if b == 0x07 || b == 0x18 || b == 0x1A { state = .ground }
                else if b == 0x1B { state = .oscIgnoreEscape }
            case .oscIgnoreEscape:
                state = b == UInt8(ascii: "\\") ? .ground : .oscIgnore
            }
        }
        return events
    }

    private mutating func finishOSC(into events: inout [Event]) {
        state = .ground
        // "133;C", optionally with ";options".
        if buffer.starts(with: Self.commandStart), buffer.count == Self.commandStart.count
            || buffer[Self.commandStart.count] == UInt8(ascii: ";") {
            events.append(.commandStarted)
            return
        }
        // "7;" then the URL.
        guard buffer.count >= 2, buffer[0] == UInt8(ascii: "7"), buffer[1] == UInt8(ascii: ";") else { return }
        events.append(.workingDirectory(String(decoding: buffer[2...], as: UTF8.self)))
    }

    private static let commandStart = Array("133;C".utf8)

    /// `CSI ? Pm h|l` — every numeric parameter is a mode.
    private func privateModes(set: Bool, into events: inout [Event]) {
        guard buffer.first == UInt8(ascii: "?") else { return }
        for part in buffer.dropFirst().split(separator: UInt8(ascii: ";")) {
            guard !part.isEmpty, part.allSatisfy({ (0x30...0x39).contains($0) }),
                  let n = Int(String(decoding: part, as: UTF8.self)) else { continue }
            events.append(.privateMode(n, set))
        }
    }
}
