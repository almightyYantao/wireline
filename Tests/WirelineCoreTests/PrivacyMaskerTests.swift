import XCTest
@testable import WirelineCore

/// Everything sent to the model goes through `mask`, and every reply through
/// `restore` before it is parsed for commands. A miss here either leaks a secret
/// or runs a command with a placeholder in it.
final class PrivacyMaskerTests: XCTestCase {

    private func masker(_ level: PrivacyPolicy.Level = .secrets, hosts: [String] = [], secrets: [String] = []) -> PrivacyMasker {
        PrivacyMasker(policy: PrivacyPolicy(level: level, knownHosts: hosts, knownSecrets: secrets), nonce: "t3st")
    }

    func testOffLeavesTextAlone() {
        let text = "password=hunter22 on 10.0.0.5"
        XCTAssertEqual(masker(.off).mask(text), text)
    }

    func testKeyValueMasksOnlyTheValue() {
        let m = masker()
        XCTAssertEqual(m.mask("db_password=hunter22"), "db_password=[WLt3st_SECRET_1]")
        XCTAssertEqual(m.mask(#"{"token": "abc.def-123"}"#), #"{"token": "[WLt3st_SECRET_2]"}"#)
        XCTAssertEqual(m.mask("API_KEY: zzz999"), "API_KEY: [WLt3st_SECRET_3]")
        // A prompt with nothing after it must not swallow the next line.
        XCTAssertEqual(m.mask("Password:\nls -la"), "Password:\nls -la")
        XCTAssertEqual(m.mask("[sudo] password for color:"), "[sudo] password for color:")
    }

    func testSameValueSamePlaceholder() {
        let m = masker()
        let a = m.mask("password=hunter22")
        let b = m.mask("DB_PASSWORD='hunter22'")
        XCTAssertEqual(a, "password=[WLt3st_SECRET_1]")
        XCTAssertEqual(b, "DB_PASSWORD='[WLt3st_SECRET_1]'")
    }

    func testRoundTrip() {
        let m = masker(.all, hosts: ["db.internal.example.com"], secrets: ["s3cretPass!"])
        let original = """
        host db.internal.example.com (10.1.2.3) password=s3cretPass!
        export TOKEN=ghp_abcdefghijklmnopqrstuvwxyz0123456789AB
        postgres://app:pa55word@10.1.2.3:5432/app
        """
        let masked = m.mask(original)
        for leaked in ["db.internal.example.com", "10.1.2.3", "s3cretPass!", "ghp_", "pa55word"] {
            XCTAssertFalse(masked.contains(leaked), "\(leaked) leaked: \(masked)")
        }
        XCTAssertEqual(m.restore(masked), original)
        XCTAssertFalse(PrivacyMasker.containsPlaceholder(m.restore(masked)))
    }

    func testPrivateKeyIsOneValue() {
        let m = masker()
        let key = "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQ\nAAAA\n-----END OPENSSH PRIVATE KEY-----"
        XCTAssertEqual(m.mask("key:\n" + key), "key:\n[WLt3st_SECRET_1]")
        XCTAssertEqual(m.restore("[WLt3st_SECRET_1]"), key)
    }

    func testWellKnownFormats() {
        let m = masker()
        for s in ["AKIAIOSFODNN7EXAMPLE",
                  "Authorization: Bearer abcdefghijkl",
                  "eyJhbGciOi.eyJzdWIiOi.SflKxwRJSM",
                  "sk-proj-abcdefghijklmnopqrstu",
                  "xoxb-1234567890-abc",
                  "d41d8cd98f00b204e9800998ecf8427e"] {
            XCTAssertTrue(m.mask(s).contains("[WLt3st_SECRET_"), "not masked: \(s)")
        }
    }

    func testPlainTextIsNotASecret() {
        let m = masker()
        for s in ["/home/color/projects/someapplication/src/components/views",
                  "docker ps -a",
                  "Filesystem      Size  Used Avail Use% Mounted on",
                  "commit message: fix the thing"] {
            XCTAssertEqual(m.mask(s), s)
        }
    }

    func testAddressesOnlyAtAll() {
        let text = "ssh root@10.0.0.5 via 203.0.113.9"
        XCTAssertEqual(masker(.secrets).mask(text), text)
        XCTAssertEqual(masker(.all).mask(text), "ssh root@[WLt3st_IP_1] via [WLt3st_IP_2]")
    }

    func testAddressesThatCarryNothingStay() {
        let m = masker(.all)
        let text = "127.0.0.1 0.0.0.0 255.255.255.0 ::1 12:30:45 aa:bb:cc:dd:ee:ff version 1.2.3"
        XCTAssertEqual(m.mask(text), text)
    }

    func testIPv6() {
        let m = masker(.all)
        XCTAssertEqual(m.mask("inet6 fe80::1c2a:3bff:fe4d:5e6f"), "inet6 [WLt3st_IP_1]")
        XCTAssertEqual(m.mask("2001:0db8:85a3:0000:0000:8a2e:0370:7334"), "[WLt3st_IP_2]")
    }

    func testKnownHostsWordBounded() {
        let m = masker(.all, hosts: ["web1.example.com", "example.com"])
        XCTAssertEqual(m.mask("ping web1.example.com"), "ping [WLt3st_HOST_1]")
        XCTAssertEqual(m.mask("see example.com."), "see [WLt3st_HOST_2].")
        XCTAssertEqual(m.mask("api.example.com.cn"), "api.example.com.cn")
    }

    func testExistingPlaceholdersUntouched() {
        let m = masker()
        // A placeholder echoed back, and a stale one from an earlier run.
        let text = "password=[WLt3st_SECRET_1] old [WLzzzz_SECRET_9]"
        XCTAssertEqual(m.mask(text), text)
    }

    func testUnknownPlaceholdersSurviveRestore() {
        let m = masker()
        _ = m.mask("password=hunter22")
        let reply = "echo [WLt3st_SECRET_1] [WLabcd_SECRET_1] [WLt3st_SECRET_7]"
        let restored = m.restore(reply)
        XCTAssertEqual(restored, "echo hunter22 [WLabcd_SECRET_1] [WLt3st_SECRET_7]")
        XCTAssertTrue(PrivacyMasker.containsPlaceholder(restored))
        XCTAssertEqual(PrivacyMasker.placeholders(in: restored), ["[WLabcd_SECRET_1]", "[WLt3st_SECRET_7]"])
    }

    /// The danger check runs on the restored command, so a destructive target
    /// can't hide behind a placeholder.
    func testSafetyRunsOnRestoredCommand() {
        let m = masker(secrets: ["/srv/data-prod"])
        let masked = m.mask("rm -rf /srv/data-prod")
        XCTAssertEqual(masked, "rm -rf [WLt3st_SECRET_1]")
        XCTAssertTrue(AICommandSafety.isDangerous(m.restore(masked)))
        XCTAssertNil(AICommandSafety.unfilledPlaceholder(masked))
    }

    func testStreamRestorerAcrossChunks() {
        let m = masker()
        _ = m.mask("password=hunter22")
        let r = m.streamRestorer()
        var out = ""
        for chunk in ["echo [W", "Lt3", "st_SEC", "RET_1] done [", "not a token]"] { out += r.feed(chunk) }
        out += r.finish()
        XCTAssertEqual(out, "echo hunter22 done [not a token]")
    }

    func testStreamRestorerFlushesUnfinishedTail() {
        let m = masker()
        let r = m.streamRestorer()
        XCTAssertEqual(r.feed("array[WLt"), "array")
        XCTAssertEqual(r.finish(), "[WLt")
    }

    func testOverLimitSecretsAreRedactedOneWay() {
        let m = masker()
        for i in 0..<PrivacyMasker.maxEntries { _ = m.mask("token=v\(i)x") }
        XCTAssertEqual(m.mask("token=onemore"), "token=\(PrivacyMasker.irreversible)")
    }

    func testOverLimitAddressesAreNotSentInTheClear() {
        let m = masker(.all)
        for i in 0..<PrivacyMasker.maxEntries { _ = m.mask("token=v\(i)x") }
        XCTAssertEqual(m.mask("ping 203.0.113.9"), "ping \(PrivacyMasker.irreversible)")
    }
}
