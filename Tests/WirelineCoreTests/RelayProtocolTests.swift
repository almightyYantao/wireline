import XCTest
import CryptoKit
@testable import WirelineCore

final class RelayProtocolTests: XCTestCase {
    private typealias Key = Curve25519.KeyAgreement.PrivateKey
    private let mac = Key(), phone = Key()

    private func transcript(_ me: Key, _ pe: Key, macStatic: Key? = nil, phoneStatic: Key? = nil,
                            macNonce: Data = Data(repeating: 2, count: 16)) -> RelayTranscript {
        RelayTranscript(macStatic: (macStatic ?? mac).publicKey.rawRepresentation,
                        phoneStatic: (phoneStatic ?? phone).publicKey.rawRepresentation,
                        macEphemeral: me.publicKey.rawRepresentation, phoneEphemeral: pe.publicKey.rawRepresentation,
                        phoneNonce: Data(repeating: 1, count: 16), macNonce: macNonce)
    }

    private func raw(_ k: SymmetricKey) -> Data { k.withUnsafeBytes { Data($0) } }

    private func keys() throws -> (SymmetricKey, SymmetricKey) {
        let me = Key(), pe = Key(), t = transcript(me, pe)
        return (try RelayCrypto.sessionKey(staticKey: mac, ephemeralKey: me, transcript: t, side: .mac),
                try RelayCrypto.sessionKey(staticKey: phone, ephemeralKey: pe, transcript: t, side: .phone))
    }

    func testBothSidesDeriveTheSameKey() throws {
        let (a, b) = try keys()
        XCTAssertEqual(raw(a), raw(b))
        let (c, _) = try keys()
        XCTAssertNotEqual(raw(a), raw(c), "fresh ephemerals, fresh key")
    }

    /// Someone without the phone's static key (e.g. the relay, holding only
    /// public values) can't land on the Mac's key even with its own ephemeral.
    func testStaticKeysAuthenticate() throws {
        let me = Key(), pe = Key(), impostor = Key()
        let t = transcript(me, pe, phoneStatic: phone)
        let macKey = try RelayCrypto.sessionKey(staticKey: mac, ephemeralKey: me, transcript: t, side: .mac)
        let fake = try RelayCrypto.sessionKey(staticKey: impostor, ephemeralKey: pe, transcript: t, side: .phone)
        XCTAssertNotEqual(raw(macKey), raw(fake))
    }

    func testHelloParts() {
        let h = RelayHandshake.hello(publicKey: Data(repeating: 1, count: 32), ephemeralKey: Data(repeating: 2, count: 32),
                                     nonce: Data(repeating: 3, count: 16))
        XCTAssertEqual(h.helloParts?.epub, Data(repeating: 2, count: 32))
        var v1 = h; v1.v = 1
        XCTAssertNil(v1.helloParts, "v1 has no forward secrecy: refused")
        var short = h; short.epub = Data(repeating: 2, count: 8).base64EncodedString()
        XCTAssertNil(short.helloParts)
    }

    func testSealOpenBothDirections() throws {
        let (a, b) = try keys()
        var m = RelayChannel(key: a, side: .mac), p = RelayChannel(key: b, side: .phone)
        XCTAssertEqual(try p.open(m.seal(Data("hi".utf8))), Data("hi".utf8))
        XCTAssertEqual(try m.open(p.seal(Data("yo".utf8))), Data("yo".utf8))
        XCTAssertEqual(try p.open(m.seal(Data())), Data())
    }

    func testRejectsReplayTamperAndReflection() throws {
        let (a, b) = try keys()
        var m = RelayChannel(key: a, side: .mac), p = RelayChannel(key: b, side: .phone)
        let f1 = try m.seal(Data("one".utf8))
        let f2 = try m.seal(Data("two".utf8))
        XCTAssertEqual(try p.open(f2), Data("two".utf8))
        XCTAssertThrowsError(try p.open(f1)) { XCTAssertEqual($0 as? RelayError, .replay) }
        XCTAssertThrowsError(try p.open(f2))
        var bad = try m.seal(Data("three".utf8))
        bad[bad.count - 1] ^= 1
        XCTAssertThrowsError(try p.open(bad))
        // A Mac frame bounced back to the Mac doesn't open (direction is in the IV).
        var m2 = RelayChannel(key: a, side: .mac)
        XCTAssertThrowsError(try m2.open(try m.seal(Data("x".utf8))))
        XCTAssertThrowsError(try p.open(Data([1, 2, 3])))
    }

    /// Cross-checked against WebCrypto (relay/web/index.html) with these fixed inputs.
    func testKnownAnswerMatchesWebCrypto() throws {
        func k(_ b: UInt8) throws -> Key { try Key(rawRepresentation: Data(repeating: b, count: 32)) }
        let ms = try k(0x11), ps = try k(0x22), me = try k(0x33), pe = try k(0x44)
        let t = RelayTranscript(macStatic: ms.publicKey.rawRepresentation, phoneStatic: ps.publicKey.rawRepresentation,
                                macEphemeral: me.publicKey.rawRepresentation, phoneEphemeral: pe.publicKey.rawRepresentation,
                                phoneNonce: Data(repeating: 0xaa, count: 16), macNonce: Data(repeating: 0xbb, count: 16))
        let key = try RelayCrypto.sessionKey(staticKey: ms, ephemeralKey: me, transcript: t, side: .mac)
        var ch = RelayChannel(key: key, side: .mac)
        let frame = try ch.seal(Data("hello phone".utf8))
        XCTAssertEqual(frame.base64EncodedString(), Self.webCryptoFrame)
    }
    static let webCryptoFrame = "AAAAAAAAAAFH5jaDM/UfRgDhKYA5wdmVyZCpF531GaP+zIk="  // node relay/test/vector.mjs

    func testPayloadAndMessageRoundTrip() throws {
        let hello = RelayPayload.handshake(.hello(publicKey: Data(repeating: 7, count: 32), ephemeralKey: Data(repeating: 6, count: 32),
                                                  nonce: Data(repeating: 8, count: 16)))
        XCTAssertEqual(try RelayPayload(encoded: hello.encoded), hello)
        let sealed = RelayPayload.sealed(Data([9, 9]))
        XCTAssertEqual(try RelayPayload(encoded: sealed.encoded), sealed)
        XCTAssertThrowsError(try RelayPayload(encoded: Data([5]).base64EncodedString()))
        XCTAssertThrowsError(try RelayPayload(encoded: "%%%"))

        let msg = RelayMessage(t: "sessions", list: [RelaySessionInfo(id: "a", title: "prod", agent: "claude", state: "needsYou", note: "Allow?")])
        XCTAssertEqual(try RelayMessage.decode(msg.encoded()), msg)
        let input = try RelayMessage.decode(Data(#"{"t":"input","sid":"a","data":"y\r"}"#.utf8))
        XCTAssertEqual(input.data, "y\r")
    }

    func testPairingCode() {
        let t0 = Date(timeIntervalSince1970: 1000)
        var c = PairingCode(code: "AB12CD34", now: t0)
        XCTAssertFalse(c.redeem("nope", at: t0))
        XCTAssertTrue(c.redeem("ab12cd34", at: t0))
        XCTAssertFalse(c.redeem("AB12CD34", at: t0), "single use")

        var expired = PairingCode(code: "AB12CD34", now: t0)
        XCTAssertFalse(expired.redeem("AB12CD34", at: t0.addingTimeInterval(301)))

        var guessed = PairingCode(code: "AB12CD34", now: t0)
        for _ in 0 ..< PairingCode.maxFailures { _ = guessed.redeem("ZZZZZZZZ", at: t0) }
        XCTAssertFalse(guessed.redeem("AB12CD34", at: t0), "void after too many failures")

        XCTAssertEqual(PairingCode().code.count, 8)
    }

    func testPairingLinkRoundTrip() throws {
        let link = PairingLink(relay: URL(string: "https://relay.example.com")!, macPublicKey: Data((0 ..< 32).map { UInt8($0 * 7 % 256) }),
                               code: "AB12CD34", name: "Tao's Mac + 1")
        let url = link.url
        XCTAssertTrue(url.absoluteString.hasPrefix("https://relay.example.com/#v=1&k="))
        XCTAssertEqual(PairingLink(url: url), PairingLink(relay: URL(string: "https://relay.example.com/")!,
                                                          macPublicKey: link.macPublicKey, code: "AB12CD34", name: "Tao's Mac + 1"))
        XCTAssertNil(PairingLink(url: URL(string: "https://relay.example.com/#v=1&k=abc&c=X")!))
    }

    func testSocketURLAndRoom() {
        let u = PairingLink.socketURL(relay: URL(string: "https://r.example.com/base/")!, room: "R", role: "mac", token: "t")
        XCTAssertEqual(u?.absoluteString, "wss://r.example.com/base/ws?room=R&role=mac&token=t")
        XCTAssertEqual(PairingLink.socketURL(relay: URL(string: "http://127.0.0.1:8080")!, room: "R", role: "phone")?.absoluteString,
                       "ws://127.0.0.1:8080/ws?room=R&role=phone")
        XCTAssertEqual(RelayCrypto.roomID(macPublicKey: Data(repeating: 0, count: 32)).count, 22)
    }

    func testRateLimiter() {
        let t0 = Date(timeIntervalSince1970: 0)
        var r = RelayRateLimiter(rate: 3, now: t0)
        XCTAssertEqual((0 ..< 5).filter { _ in r.allow(at: t0) }.count, 3)
        XCTAssertTrue(r.allow(at: t0.addingTimeInterval(0.4)))
        XCTAssertFalse(r.allow(at: t0.addingTimeInterval(0.4)))
    }
}
