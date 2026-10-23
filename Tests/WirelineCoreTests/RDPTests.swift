import XCTest
@testable import WirelineCore

final class RDPTests: XCTestCase {

    // MARK: Key map

    func testLettersDigitsAndControlKeys() {
        XCTAssertEqual(RDPKeyMap.scancode(forKeyCode: 0x00), .init(0x1E))          // A
        XCTAssertEqual(RDPKeyMap.scancode(forKeyCode: 0x06), .init(0x2C))          // Z
        XCTAssertEqual(RDPKeyMap.scancode(forKeyCode: 0x12), .init(0x02))          // 1
        XCTAssertEqual(RDPKeyMap.scancode(forKeyCode: 0x1D), .init(0x0B))          // 0
        XCTAssertEqual(RDPKeyMap.scancode(forKeyCode: 0x24), .init(0x1C))          // Return
        XCTAssertEqual(RDPKeyMap.scancode(forKeyCode: 0x33), .init(0x0E))          // Backspace
        XCTAssertEqual(RDPKeyMap.scancode(forKeyCode: 0x35), .init(0x01))          // Esc
        XCTAssertEqual(RDPKeyMap.scancode(forKeyCode: 0x31), .init(0x39))          // Space
    }

    func testExtendedKeys() {
        XCTAssertEqual(RDPKeyMap.scancode(forKeyCode: 0x7B), .init(0x4B, extended: true))  // ←
        XCTAssertEqual(RDPKeyMap.scancode(forKeyCode: 0x7E), .init(0x48, extended: true))  // ↑
        XCTAssertEqual(RDPKeyMap.scancode(forKeyCode: 0x75), .init(0x53, extended: true))  // ⌦
        XCTAssertEqual(RDPKeyMap.scancode(forKeyCode: 0x4C), .init(0x1C, extended: true))  // keypad Enter
        XCTAssertEqual(RDPKeyMap.scancode(forKeyCode: 0x37), RDPKeyMap.leftWindows)        // ⌘
        XCTAssertEqual(RDPKeyMap.scancode(forKeyCode: 0x3D), .init(0x38, extended: true))  // right ⌥ = AltGr
    }

    func testFunctionKeysAreComplete() {
        let fKeys: [UInt16] = [0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F]
        let codes = fKeys.compactMap { RDPKeyMap.scancode(forKeyCode: $0)?.code }
        XCTAssertEqual(codes, [0x3B, 0x3C, 0x3D, 0x3E, 0x3F, 0x40, 0x41, 0x42, 0x43, 0x44, 0x57, 0x58])
    }

    func testISOKeyboardSwapsSectionAndGrave() {
        // ANSI: ` (left of 1) is OEM_3.
        XCTAssertEqual(RDPKeyMap.scancode(forKeyCode: 0x32), .init(0x29))
        // ISO: the key left of 1 reports kVK_ISO_Section, left of Z kVK_ANSI_Grave.
        XCTAssertEqual(RDPKeyMap.scancode(forKeyCode: 0x0A, iso: true), .init(0x29))
        XCTAssertEqual(RDPKeyMap.scancode(forKeyCode: 0x32, iso: true), .init(0x56))
    }

    func testUnmappedKeyIsNil() {
        XCTAssertNil(RDPKeyMap.scancode(forKeyCode: 0x3F))   // fn
        XCTAssertNil(RDPKeyMap.scancode(forKeyCode: 0xFF))
        XCTAssertEqual(RDPKeyMap.modifier(forKeyCode: 0x3F), .function)
        XCTAssertEqual(RDPKeyMap.modifier(forKeyCode: 0x36), .command)
    }

    func testNoDuplicateNonModifierScancodes() {
        // Two Mac keys sending the same scancode would make one of them a ghost.
        var seen: [RDPKeyMap.Scancode: UInt16] = [:]
        for kc in UInt16(0)..<0x80 where RDPKeyMap.modifier(forKeyCode: kc) == nil {
            guard let sc = RDPKeyMap.scancode(forKeyCode: kc) else { continue }
            XCTAssertNil(seen[sc], "keyCode \(kc) and \(seen[sc] ?? 0) both map to \(sc)")
            seen[sc] = kc
        }
    }

    // MARK: Display

    func testDesktopSizeIsEvenClampedAndInPixels() {
        let s = RDPDisplay.desktopSize(points: CGSize(width: 801.5, height: 600), backingScale: 2)
        XCTAssertEqual(s.width, 1602)
        XCTAssertEqual(s.height, 1200)
        let odd = RDPDisplay.desktopSize(points: CGSize(width: 1001, height: 500), backingScale: 1)
        XCTAssertEqual(odd.width, 1000)
        let tiny = RDPDisplay.desktopSize(points: CGSize(width: 50, height: 20), backingScale: 1)
        XCTAssertEqual(tiny.width, 200)
        XCTAssertEqual(tiny.height, 200)
        let huge = RDPDisplay.desktopSize(points: CGSize(width: 6000, height: 5000), backingScale: 2)
        XCTAssertEqual(huge.width, 8192)
        XCTAssertEqual(huge.height, 8192)
    }

    func testScaleFactors() {
        XCTAssertEqual(RDPDisplay.desktopScaleFactor(backingScale: 2), 200)
        XCTAssertEqual(RDPDisplay.desktopScaleFactor(backingScale: 1), 100)
        XCTAssertEqual(RDPDisplay.deviceScaleFactor(desktopScale: 200), 180)
        XCTAssertEqual(RDPDisplay.deviceScaleFactor(desktopScale: 150), 140)
        XCTAssertEqual(RDPDisplay.deviceScaleFactor(desktopScale: 100), 100)
    }

    func testRemotePointScalesAndClamps() {
        let d = (width: UInt32(2000), height: UInt32(1000))
        let p = RDPDisplay.remotePoint(CGPoint(x: 500, y: 250), viewSize: CGSize(width: 1000, height: 500), desktop: d)
        XCTAssertEqual(p.x, 1000)
        XCTAssertEqual(p.y, 500)
        let out = RDPDisplay.remotePoint(CGPoint(x: -5, y: 9999), viewSize: CGSize(width: 1000, height: 500), desktop: d)
        XCTAssertEqual(out.x, 0)
        XCTAssertEqual(out.y, 999)
    }

    func testWheelAccumulator() {
        var w = RDPWheelAccumulator()
        XCTAssertEqual(w.feed(delta: 1, precise: false), [120])          // one notch up
        XCTAssertEqual(w.feed(delta: -3, precise: false), [-255, -105])  // split at 255
        XCTAssertEqual(w.feed(delta: 0.05, precise: true), [])           // too small yet
        let more = w.feed(delta: 0.1, precise: true)                     // 0.15 * 12 = 1.8 → 1
        XCTAssertEqual(more, [1])
        w.reset()
        XCTAssertEqual(w.feed(delta: 0.05, precise: true), [])
    }

    // MARK: Errors

    func testErrorWording() {
        let auth = RDPErrorText.message(errorName: "ERRCONNECT_LOGON_FAILURE", errinfoName: "")
        XCTAssertEqual(auth?.isAuthFailure, true)
        XCTAssertTrue(auth?.zh.contains("密码") ?? false)
        // A server-side reason wins over the generic transport error it causes.
        let logoff = RDPErrorText.message(errorName: "ERRCONNECT_CONNECT_TRANSPORT_FAILED",
                                          errinfoName: "ERRINFO_LOGOFF_BY_USER")
        XCTAssertEqual(logoff?.en, "Logged off from Windows")
        XCTAssertNil(RDPErrorText.message(errorName: "ERRCONNECT_CONNECT_CANCELLED", errinfoName: ""))
        XCTAssertNil(RDPErrorText.message(errorName: "", errinfoName: ""))
        let unknown = RDPErrorText.message(errorName: "ERRCONNECT_SOMETHING_NEW", errinfoName: "")
        XCTAssertTrue(unknown?.en.contains("ERRCONNECT_SOMETHING_NEW") ?? false)
    }

    // MARK: Certificates

    private let pem = """
    -----BEGIN CERTIFICATE-----
    MIIBszCCAVmgAwIBAgIUQk1x0ZbLqk5pWzE0e3cG5vLrVdQwCgYIKoZIzj0EAwIw
    LzEtMCsGA1UEAwwkd2lyZWxpbmUtdGVzdC5leGFtcGxlLmludmFsaWQwHhcNMjYw
    MTAxMDAwMDAwWhcNMzYwMTAxMDAwMDAwWjAvMS0wKwYDVQQDDCR3aXJlbGluZS10
    ZXN0LmV4YW1wbGUuaW52YWxpZDBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABN2o
    -----END CERTIFICATE-----
    """

    func testPEMToDERAndFingerprint() throws {
        let der = try XCTUnwrap(RDPCertificateInfo.der(from: Data(pem.utf8)))
        XCTAssertEqual(der.first, 0x30)
        let fp = RDPCertificateInfo.fingerprint(der: der)
        XCTAssertEqual(fp.split(separator: ":").count, 32)
        // Raw DER passes through.
        XCTAssertEqual(RDPCertificateInfo.der(from: der), der)
        XCTAssertNil(RDPCertificateInfo.der(from: Data("garbage".utf8)))
    }

    func testKnownHostsTrustOnFirstUse() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rdp-kh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("known.json")
        let store = RDPKnownHosts(url: url)
        let a = RDPCertificateInfo(fingerprint: "AA:BB", subject: "CN=win", issuer: "CN=win")
        XCTAssertEqual(store.verdict(host: "Win.Example", port: 3389, fingerprint: "AA:BB"), .unknown)
        store.trust(host: "Win.Example", port: 3389, info: a)
        XCTAssertEqual(store.verdict(host: "win.example", port: 3389, fingerprint: "AA:BB"), .trusted)
        // Different port: a different server.
        XCTAssertEqual(store.verdict(host: "win.example", port: 3390, fingerprint: "AA:BB"), .unknown)
        guard case .changed(let old) = store.verdict(host: "win.example", port: 3389, fingerprint: "CC:DD") else {
            return XCTFail("expected a changed-certificate verdict")
        }
        XCTAssertEqual(old.fingerprint, "AA:BB")
        // Persisted, and reloads.
        let reloaded = RDPKnownHosts(url: url)
        XCTAssertEqual(reloaded.verdict(host: "win.example", port: 3389, fingerprint: "AA:BB"), .trusted)
        reloaded.forget(host: "win.example", port: 3389)
        XCTAssertEqual(RDPKnownHosts(url: url).verdict(host: "win.example", port: 3389, fingerprint: "AA:BB"), .unknown)
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
    }

    // MARK: Host storage

    func testRDPMetadataRoundTrip() {
        let text = """
        Host winbox
            # wireline: protocol=rdp; group=Office; domain=CORP; via=bastion
            HostName 10.1.2.3
            User alice
        """
        let h = SSHConfig.parse(text).hosts[0]
        XCTAssertTrue(h.isRDP)
        XCTAssertEqual(h.rdpDomain, "CORP")
        XCTAssertEqual(h.rdpVia, "bastion")
        XCTAssertEqual(h.group, "Office")
        XCTAssertEqual(h.effectivePort, 3389)
        let again = SSHConfig.parse(SSHConfig.render(h)).hosts[0]
        XCTAssertEqual(again, h)
        XCTAssertTrue(SSHConfig.render(h).contains("# wireline: protocol=rdp;"))
    }

    func testSSHHostsDontGetRDPKeys() {
        var h = Host(alias: "web", hostname: "1.2.3.4")
        h.rdpDomain = "LEFTOVER"   // e.g. switched from RDP back to SSH in the editor
        XCTAssertFalse(SSHConfig.render(h).contains("domain="))
        XCTAssertFalse(SSHConfig.render(h).contains("protocol="))
        XCTAssertEqual(h.effectivePort, 22)
    }

    func testRDPFileForcesProtocolAndHeader() {
        let raw = SSHConfig.parse("Host plain\n    HostName 10.0.0.9\n")
        let normalized = RDPHostsFile.normalize(raw)
        XCTAssertTrue(normalized.hosts[0].isRDP)
        let doc = RDPHostsFile.document(for: [Host(alias: "w1", hostname: "h", hostProtocol: .rdp)],
                                        from: SSHConfig.Document(items: []))
        let text = SSHConfig.serialize(doc)
        XCTAssertTrue(text.hasPrefix("# Wireline — Remote Desktop"))
        XCTAssertTrue(text.contains("NOT an ssh config"))
        XCTAssertTrue(text.contains("Host w1"))
    }

    func testReplacingHostsKeepsRawBlocksAndOrder() {
        let doc = SSHConfig.parse("""
        # preamble
        Host a
            HostName 1
        Host *
            ServerAliveInterval 30
        Host b
            HostName 2
        """)
        let out = doc.replacingHosts(with: [Host(alias: "b", hostname: "22"), Host(alias: "c", hostname: "3")])
        let text = SSHConfig.serialize(out)
        XCTAssertFalse(text.contains("Host a"))
        XCTAssertTrue(text.contains("Host *"))
        XCTAssertTrue(text.contains("# preamble"))
        XCTAssertLessThan(text.range(of: "Host b")!.lowerBound, text.range(of: "Host c")!.lowerBound)
        XCTAssertEqual(out.hosts.map(\.hostname), ["22", "3"])
    }

    func testHostCodableKeepsRDPFields() throws {
        let h = Host(alias: "w", hostname: "x", user: "u", hostProtocol: .rdp, rdpDomain: "D", rdpVia: "j")
        let back = try JSONDecoder().decode(Host.self, from: JSONEncoder().encode(h))
        XCTAssertEqual(back, h)
        // Old backups (no protocol key) decode as SSH.
        let legacy = try JSONDecoder().decode(Host.self, from: Data(#"{"alias":"old","extraOptions":[],"authMethod":"key","autoSudo":false}"#.utf8))
        XCTAssertEqual(legacy.hostProtocol, .ssh)
    }
}
