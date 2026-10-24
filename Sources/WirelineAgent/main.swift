import Foundation

/// wireline-agent — the session agent (docs/design/wireline-agent.md).
///
///   wireline-agent snapshot COLS ROWS < bytes > snapshot
///       Feed stdin to a headless terminal and print its snapshot (tests,
///       debugging a restore).
let args = CommandLine.arguments.dropFirst()

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("wireline-agent: \(message)\n".utf8))
    exit(64)
}

switch args.first {
case "snapshot":
    let rest = Array(args.dropFirst())
    guard rest.count == 2, let cols = UInt16(rest[0]), let rows = UInt16(rest[1]) else {
        fail("usage: wireline-agent snapshot COLS ROWS < bytes > snapshot")
    }
    guard let vt = VTTerminal(cols: cols, rows: rows) else { fail("couldn't create a terminal") }
    vt.write([UInt8](FileHandle.standardInput.readDataToEndOfFile()))
    guard let snap = vt.snapshot() else { fail("couldn't encode a snapshot") }
    FileHandle.standardOutput.write(Data(snap))
default:
    fail("usage: wireline-agent snapshot COLS ROWS")
}
