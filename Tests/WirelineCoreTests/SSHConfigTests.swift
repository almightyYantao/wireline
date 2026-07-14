import XCTest
@testable import WirelineCore

final class SSHConfigTests: XCTestCase {

    func testParseBasicHost() {
        let text = """
        Host web1
            HostName 10.0.0.1
            User deploy
            Port 2222
            IdentityFile ~/.ssh/id_rsa
        """
        let doc = SSHConfig.parse(text)
        XCTAssertEqual(doc.hosts.count, 1)
        let h = doc.hosts[0]
        XCTAssertEqual(h.alias, "web1")
        XCTAssertEqual(h.hostname, "10.0.0.1")
        XCTAssertEqual(h.user, "deploy")
        XCTAssertEqual(h.port, 2222)
        XCTAssertEqual(h.identityFile, "~/.ssh/id_rsa")
        XCTAssertEqual(h.resolvedAuthMethod, .key)
    }

    func testParseMetadata() {
        let text = """
        Host db-hk
            # wireline: group=Hong Kong; desc=Primary DB; auth=password; autosudo=true
            HostName 192.168.1.5
            User root
        """
        let h = SSHConfig.parse(text).hosts[0]
        XCTAssertEqual(h.group, "Hong Kong")
        XCTAssertEqual(h.descriptionText, "Primary DB")
        XCTAssertEqual(h.authMethod, .password)
        XCTAssertTrue(h.autoSudo)
    }

    func testMetadataWithEscapedSemicolon() {
        var host = Host(alias: "x")
        host.descriptionText = "runs a; b; c"
        host.group = "grp"
        let line = SSHConfig.metadataLine(for: host)!
        // Re-parse a block containing this metadata line.
        let block = "Host x\n    \(line)\n    HostName h\n"
        let parsed = SSHConfig.parse(block).hosts[0]
        XCTAssertEqual(parsed.descriptionText, "runs a; b; c")
        XCTAssertEqual(parsed.group, "grp")
    }

    func testPreservesGlobalBlockAndComments() {
        let text = """
        # my ssh config
        Host *
            ServerAliveInterval 60

        Host bastion
            HostName jump.example.com
            User admin
        """
        let doc = SSHConfig.parse(text)
        XCTAssertEqual(doc.hosts.count, 1)
        XCTAssertEqual(doc.hosts[0].alias, "bastion")
        let out = SSHConfig.serialize(doc)
        XCTAssertTrue(out.contains("Host *"))
        XCTAssertTrue(out.contains("ServerAliveInterval 60"))
        XCTAssertTrue(out.contains("# my ssh config"))
    }

    func testRoundTripPreservesExtraOptions() {
        let text = """
        Host app
            HostName 1.2.3.4
            User ubuntu
            ForwardAgent yes
            ProxyJump bastion
        """
        let doc = SSHConfig.parse(text)
        let h = doc.hosts[0]
        XCTAssertEqual(h.proxyJump, "bastion")
        XCTAssertTrue(h.extraOptions.contains { $0.keyword == "ForwardAgent" && $0.value == "yes" })
        let out = SSHConfig.serialize(doc)
        XCTAssertTrue(out.contains("ForwardAgent yes"))
        XCTAssertTrue(out.contains("ProxyJump bastion"))
    }

    func testEqualsSyntax() {
        let h = SSHConfig.parse("Host x\n    Port=2200\n    HostName=example.com").hosts[0]
        XCTAssertEqual(h.port, 2200)
        XCTAssertEqual(h.hostname, "example.com")
    }

    func testAddedHostSerializesMetadataFirst() {
        var host = Host(alias: "new", hostname: "h", user: "u", authMethod: .password)
        host.group = "G"
        let rendered = SSHConfig.render(host)
        let lines = rendered.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "Host new")
        XCTAssertTrue(lines[1].contains("# wireline:"))
    }
}
