import XCTest
@testable import WirelineCore

final class CoreServiceTests: XCTestCase {

    func testConfigRepositoryRoundTrip() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("wireline-test-\(UUID().uuidString)")
            .appendingPathComponent("config")
        let repo = ConfigRepository(url: tmp)

        var host = Host(alias: "test-host", hostname: "10.0.0.9", user: "deploy",
                        port: 22, authMethod: .password)
        host.group = "Testing"
        host.descriptionText = "unit test host"
        try repo.save(SSHConfig.Document(items: [.host(host)]))

        let reloaded = try repo.loadHosts()
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(reloaded[0].alias, "test-host")
        XCTAssertEqual(reloaded[0].group, "Testing")
        XCTAssertEqual(reloaded[0].authMethod, .password)

        // Permissions should be locked down to 0600.
        let attrs = try FileManager.default.attributesOfItem(atPath: tmp.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent())
    }

    func testSSHCommandArguments() {
        let host = Host(alias: "web1", hostname: "1.1.1.1", user: "u")
        let interactive = SSHCommand.interactiveArguments(for: host)
        XCTAssertEqual(interactive.last, "web1")
        XCTAssertTrue(interactive.contains("StrictHostKeyChecking=accept-new"))

        let runArgs = SSHCommand.runArguments(for: host, command: "uptime")
        XCTAssertTrue(runArgs.contains("uptime"))
        XCTAssertTrue(runArgs.contains("web1"))
        XCTAssertTrue(runArgs.contains("ConnectTimeout=10"))
    }

    func testForwardArguments() {
        let host = Host(alias: "bastion")
        let fwd = PortForward(hostAlias: "bastion", localPort: 5432,
                              remoteHost: "db.internal", remotePort: 5432)
        let args = SSHCommand.forwardArguments(for: host, forward: fwd)
        XCTAssertEqual(args, ["-N", "-L", "127.0.0.1:5432:db.internal:5432", "bastion"])
    }

    func testShellQuoting() {
        XCTAssertEqual(shellQuote("simple"), "simple")
        XCTAssertEqual(shellQuote("has space"), "'has space'")
        XCTAssertEqual(shellQuote("it's"), "'it'\\''s'")
    }

    func testBackupRoundTrip() throws {
        let service = BackupService(iterations: 10_000) // faster for tests
        let bundle = BackupBundle(
            hosts: [Host(alias: "h1", hostname: "1.1.1.1", authMethod: .password)],
            passwords: ["h1": "s3cr3t!"]
        )
        let data = try service.export(bundle, passphrase: "correct horse")
        let restored = try service.import(data, passphrase: "correct horse")
        XCTAssertEqual(restored.hosts.count, 1)
        XCTAssertEqual(restored.hosts[0].alias, "h1")
        XCTAssertEqual(restored.passwords["h1"], "s3cr3t!")
    }

    func testBackupWrongPassphraseFails() throws {
        let service = BackupService(iterations: 10_000)
        let data = try service.export(BackupBundle(hosts: [], passwords: [:]),
                                      passphrase: "right")
        XCTAssertThrowsError(try service.import(data, passphrase: "wrong"))
    }

    func testBackupBadFormatFails() {
        let service = BackupService(iterations: 10_000)
        XCTAssertThrowsError(try service.import(Data("not json".utf8), passphrase: "x"))
    }
}
