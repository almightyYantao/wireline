import AppKit
import XCTest
import WirelineCore
@testable import Wireline

/// RDP panes end to end against the xrdp test container (`wl-xrdp`: RDP on
/// 127.0.0.1:13389, SSH on :12222, user test / Test1234; its session is an
/// xterm whose input is appended to /tmp/typed.txt). Drives `RDPSession` the
/// way a pane does, with no window: certificate trust on first use, logon,
/// frames into the IOSurface ring, dynamic resolution, scancode and Unicode
/// input, clipboard both ways, the SSH jump tunnel and readable failures.
/// Known hosts and the pasteboard are private to the test.
///
///   WIRELINE_RDP_HARNESS=1 swift test --filter RDPHarnessTests
///
/// Snapshots go to /tmp/wireline-rdp-harness/.
@MainActor
final class RDPHarnessTests: XCTestCase {
    private let outDir = URL(fileURLWithPath: "/tmp/wireline-rdp-harness", isDirectory: true)

    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["WIRELINE_RDP_HARNESS"] == "1" else {
            throw XCTSkip("set WIRELINE_RDP_HARNESS=1 to run against the wl-xrdp container")
        }
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        RDPSession.knownHosts = RDPKnownHosts(url: outDir.appendingPathComponent("known-hosts-\(UUID().uuidString).json"))
        // Never play the remote's sound on this Mac.
        UserDefaults.standard.set(false, forKey: "rdpAudio")
    }

    private func log(_ s: String) { print("[rdp-harness] \(s)") }

    @discardableResult
    private func wait(_ timeout: TimeInterval, until done: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if done() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return done()
    }

    private func pump(_ seconds: TimeInterval) { _ = wait(seconds) { false } }

    /// `docker exec` in the container, as the session's user, run off the main
    /// thread while the run loop keeps turning (the RDP side may need it).
    private func container(_ script: String, timeout: TimeInterval = 10) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/local/bin/docker")
        p.arguments = ["exec", "-u", "test", "-e", "DISPLAY=:10", "wl-xrdp", "sh", "-c", script]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        guard (try? p.run()) != nil else { return "(docker failed)" }
        wait(timeout) { !p.isRunning }
        if p.isRunning { p.terminate() }
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    private func host(port: Int = 13389) -> WirelineCore.Host {
        WirelineCore.Host(alias: "xrdp-test", hostname: "127.0.0.1", user: "test", port: port, hostProtocol: .rdp)
    }

    private func isDialing(_ s: RDPSession) -> Bool {
        if case .running = s.status { return true }
        return false
    }

    private func makeSession(_ target: RDPTarget) -> RDPSession {
        let s = RDPSession(target: target)
        s.pasteboard = NSPasteboard(name: NSPasteboard.Name("wl-rdp-harness-\(UUID().uuidString)"))
        return s
    }

    /// Accept the TOFU prompt (checking it's our container's certificate) and
    /// wait for the desktop.
    private func connect(_ s: RDPSession, file: StaticString = #filePath, line: UInt = #line) {
        s.start()
        XCTAssertTrue(wait(30) { s.certificatePrompt != nil || !self.isDialing(s) },
                      "no certificate question", file: file, line: line)
        if let prompt = s.certificatePrompt {
            log("certificate: \(prompt.info.subject) · \(prompt.info.fingerprint.prefix(23))…")
            XCTAssertFalse(prompt.info.subject.isEmpty, file: file, line: line)
            XCTAssertEqual(prompt.info.fingerprint.count, 32 * 3 - 1, file: file, line: line)
            XCTAssertNil(prompt.previous, file: file, line: line)
            s.answerCertificate(trust: true)
        }
        XCTAssertTrue(wait(30) { !self.isDialing(s) }, "never established", file: file, line: line)
        for entry in s.log { log(String(format: "  %.2fs %@", entry.t, entry.text)) }
        XCTAssertEqual(s.status, .established, file: file, line: line)
    }

    private func save(_ s: RDPSession, _ name: String) -> CGImage? {
        guard let img = s.view.snapshotImage() else { return nil }
        let url = outDir.appendingPathComponent("\(name).png")
        if let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, img, nil)
            CGImageDestinationFinalize(dest)
        }
        log("snapshot \(img.width)×\(img.height) → \(url.path)")
        return img
    }

    /// How many distinct colours a coarse grid over the image has (a real
    /// desktop has several; a blank or failed frame has one).
    private func colourCount(_ img: CGImage) -> Int {
        guard let data = img.dataProvider?.data, let p = CFDataGetBytePtr(data) else { return 0 }
        var seen = Set<UInt32>()
        for gy in 0..<24 {
            for gx in 0..<24 {
                let x = gx * img.width / 24, y = gy * img.height / 24
                let o = y * img.bytesPerRow + x * 4
                seen.insert(UInt32(p[o]) | UInt32(p[o + 1]) << 8 | UInt32(p[o + 2]) << 16)
            }
        }
        return seen.count
    }

    func testDesktopResizeInputAndClipboard() throws {
        let s = makeSession(RDPTarget(host: host(), password: "Test1234", viaPassword: nil))
        s.pasteboard.clearContents()
        s.pasteboard.setString("剪贴板 from Mac", forType: .string)
        s.view.setFrameSize(NSSize(width: 800, height: 500))
        connect(s)
        guard s.status == .established else { return }
        let scale = s.view.backingScale
        let expected = RDPDisplay.desktopSize(points: CGSize(width: 800, height: 500), backingScale: scale)

        XCTAssertTrue(wait(10) { s.view.framesShown > 3 }, "frames: \(s.view.framesShown)")
        pump(1.5)
        XCTAssertEqual(s.view.desktop.width, expected.width)
        XCTAssertEqual(s.view.desktop.height, expected.height)
        let first = try XCTUnwrap(save(s, "1-connected"))
        XCTAssertEqual(first.width, Int(expected.width))
        XCTAssertGreaterThan(colourCount(first), 2, "the frame looks blank")
        log("frames shown: \(s.view.framesShown)")

        // Dynamic resolution: the pane grows, the desktop follows.
        let grown = RDPDisplay.desktopSize(points: CGSize(width: 1000, height: 640), backingScale: scale)
        s.view.setFrameSize(NSSize(width: 1000, height: 640))
        XCTAssertTrue(wait(15) { s.view.desktop.width == grown.width && s.view.desktop.height == grown.height },
                      "desktop stayed \(s.view.desktop) (wanted \(grown))")
        pump(1.5)
        if let img = save(s, "2-resized") { XCTAssertEqual(img.width, Int(grown.width)) }
        for entry in s.log.suffix(3) { log(String(format: "  %.2fs %@", entry.t, entry.text)) }

        // Input: scancodes, then text the way an input method delivers it.
        _ = container(": > /tmp/typed.txt")
        let c = try XCTUnwrap(s.view.connection)
        for code: UInt8 in [0x23, 0x17, 0x39] {   // h i space
            c.sendKey(code, extended: false, down: true)
            c.sendKey(code, extended: false, down: false)
        }
        c.sendKey(0x2A, extended: false, down: true)   // ⇧ + 1 → "!"
        c.sendKey(0x02, extended: false, down: true)
        c.sendKey(0x02, extended: false, down: false)
        c.sendKey(0x2A, extended: false, down: false)
        s.view.insertText("你好", replacementRange: NSRange(location: NSNotFound, length: 0))
        c.sendKey(0x1C, extended: false, down: true)   // ⏎
        c.sendKey(0x1C, extended: false, down: false)
        var typed = ""
        wait(8) { typed = self.container("cat /tmp/typed.txt"); return typed.contains("\n") }
        log("typed: \(typed.debugDescription)")
        XCTAssertTrue(typed.hasPrefix("hi !"), "scancodes: \(typed.debugDescription)")
        // xrdp 0.10 drops Unicode keyboard events unless its IBus bridge runs
        // (not in this container), so input-method text is checked on Windows only.
        if !typed.contains("你好") { log("Unicode input not delivered (expected on xrdp without IBus)") }

        // Clipboard, Mac → Windows: offered when the channel came up.
        let remote = container("timeout 5 xclip -o -selection clipboard")
        log("remote clipboard: \(remote.debugDescription)")
        XCTAssertEqual(remote, "剪贴板 from Mac")

        // Windows → Mac.
        _ = container("printf '来自远端 %s' $$ | xclip -i -selection clipboard -loops 3 >/dev/null 2>&1 &")
        XCTAssertTrue(wait(8) { s.pasteboard.string(forType: .string)?.hasPrefix("来自远端") == true },
                      "local clipboard: \(s.pasteboard.string(forType: .string) ?? "nil")")

        s.close()
        XCTAssertEqual(s.status, .closed)
        pump(1)
    }

    func testThroughSSHJumpHost() {
        // The tunnel ends inside the container, where xrdp listens on 3389.
        var h = host(port: 3389)
        h.rdpVia = "test@127.0.0.1"
        let s = makeSession(RDPTarget(host: h, password: "Test1234", viaPassword: "Test1234",
                                      viaArgs: ["-p", "12222", "-o", "UserKnownHostsFile=/dev/null",
                                                "-o", "LogLevel=ERROR", "-F", "/dev/null"]))
        connect(s)
        XCTAssertTrue(s.log.contains { $0.text.contains("127.0.0.1:") && $0.text.lowercased().contains("tunnel") || $0.text.contains("隧道就绪") })
        XCTAssertTrue(wait(10) { s.view.framesShown > 0 })
        _ = save(s, "3-tunnel")
        s.close()
        pump(1)
    }

    func testRefusedPortIsReadable() {
        let s = makeSession(RDPTarget(host: host(port: 1), password: "x", viaPassword: nil))
        s.start()
        XCTAssertTrue(wait(20) { if case .failed = s.status { true } else { false } })
        log("refused: \(s.status)")
        if case .failed(let stage, let message) = s.status {
            XCTAssertEqual(stage, .connect)
            XCTAssertTrue(message.contains("无法连接") || message.contains("Couldn't connect"), message)
        }
    }

    func testWrongPasswordIsReadable() {
        let s = makeSession(RDPTarget(host: host(), password: "wrong-password", viaPassword: nil))
        RDPSession.knownHosts.trust(host: "127.0.0.1", port: 13389,
                                    info: RDPCertificateInfo(fingerprint: "", subject: "", issuer: ""))
        s.start()
        // A changed certificate (the entry above is bogus) must be flagged as such.
        XCTAssertTrue(wait(20) { s.certificatePrompt != nil })
        XCTAssertNotNil(s.certificatePrompt?.previous, "a changed certificate wasn't flagged")
        s.answerCertificate(trust: true)
        let ended = wait(30) { if case .failed = s.status { true } else { s.status == .established } }
        for entry in s.log { log(String(format: "  %.2fs %@", entry.t, entry.text)) }
        log("wrong password → \(s.status) ended=\(ended)")
        if s.status == .established {
            // xrdp (no NLA) logs on after the TLS handshake and shows its own
            // login screen on failure: nothing to report client-side.
            pump(2)
            _ = save(s, "4-wrong-password")
        }
        s.close()
        pump(1)
    }
}
