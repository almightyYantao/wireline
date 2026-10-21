import XCTest
import Security
@testable import WirelineCore

final class SSHAgentTests: XCTestCase {

    // MARK: - Wire format

    func testWireRoundTrip() throws {
        var w = SSHWireWriter()
        w.writeByte(13)
        w.writeUInt32(0xDEADBEEF)
        w.writeString("ssh-ed25519")
        w.writeString(Data([1, 2, 3]))
        w.writeMPInt(Data([0x80, 0x01]))      // high bit → needs a sign byte
        w.writeMPInt(Data([0x00, 0x00, 0x7f])) // leading zeros stripped
        w.writeMPInt(Data())                   // zero → empty string

        var r = SSHWireReader(w.data)
        XCTAssertEqual(try r.readByte(), 13)
        XCTAssertEqual(try r.readUInt32(), 0xDEADBEEF)
        XCTAssertEqual(try r.readStringUTF8(), "ssh-ed25519")
        XCTAssertEqual(try r.readString(), Data([1, 2, 3]))
        XCTAssertEqual(try r.readString(), Data([0x00, 0x80, 0x01]))
        XCTAssertEqual(try r.readString(), Data([0x7f]))
        XCTAssertEqual(try r.readMPInt(), Data())
        XCTAssertTrue(r.isAtEnd)
        XCTAssertThrowsError(try r.readByte())

        var mp = SSHWireReader(Data([0, 0, 0, 3, 0x00, 0x80, 0x01]))
        XCTAssertEqual(try mp.readMPInt(), Data([0x80, 0x01]))

        var truncated = SSHWireReader(Data([0, 0, 0, 9, 1]))
        XCTAssertThrowsError(try truncated.readString())
    }

    func testBigModMatchesUInt64() {
        func data(_ v: UInt64) -> Data { BigMod.bytes([UInt32(v & 0xffffffff), UInt32(v >> 32)]) }
        for (a, m) in [(UInt64(256), UInt64(7)), (0xFFFF_FFFF_FFFF_FFFF, 0x1_0000_0001),
                       (123_456_789_012_345, 97), (5, 9), (0x8000_0000_0000_0000, 0xFFFF_FFFF)] {
            XCTAssertEqual(BigMod.mod(data(a), data(m)), data(a % m), "\(a) mod \(m)")
            XCTAssertEqual(BigMod.decrement(data(a)), data(a - 1))
        }
    }

    // MARK: - Key parsing

    func testParsesGeneratedKeys() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for (type, bits) in [("ed25519", nil), ("ecdsa", "256"), ("ecdsa", "384"), ("ecdsa", "521"), ("rsa", "2048")] {
            let path = try generateKey(type: type, bits: bits, in: dir)
            let key = try SSHPrivateKey(openSSH: String(contentsOfFile: path, encoding: .utf8))
            let pub = try String(contentsOfFile: path + ".pub", encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertEqual(key.publicKeyLine, pub, type)
            XCTAssertEqual(key.comment, "wireline-test-\(type)")
            let listed = run(["/usr/bin/ssh-keygen", "-l", "-f", path + ".pub"]).output
            XCTAssertTrue(listed.contains(key.fingerprint), "\(type): \(listed)")
            XCTAssertFalse(SSHPrivateKey.isEncrypted(try String(contentsOfFile: path, encoding: .utf8)))
        }
    }

    /// RSA flags pick the algorithm; each signature verifies with the public key.
    func testRSASignatureAlgorithmsFollowFlags() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try generateKey(type: "rsa", bits: "2048", in: dir)
        let key = try SSHPrivateKey(openSSH: String(contentsOfFile: path, encoding: .utf8))
        guard case .rsa(let params) = key.kind else { return XCTFail("not rsa") }
        let pub = try XCTUnwrap(SecKeyCopyPublicKey(try SSHPrivateKey.makeRSAKey(params)))
        let payload = Data("payload".utf8)
        let cases: [(UInt32, String, SecKeyAlgorithm)] = [
            (0, "ssh-rsa", .rsaSignatureMessagePKCS1v15SHA1),
            (SSHAgentMessage.flagRSASHA256, "rsa-sha2-256", .rsaSignatureMessagePKCS1v15SHA256),
            (SSHAgentMessage.flagRSASHA512, "rsa-sha2-512", .rsaSignatureMessagePKCS1v15SHA512)
        ]
        for (flags, name, alg) in cases {
            var r = SSHWireReader(try key.sign(payload, flags: flags))
            XCTAssertEqual(try r.readStringUTF8(), name)
            let sig = try r.readString()
            XCTAssertTrue(SecKeyVerifySignature(pub, alg, payload as CFData, sig as CFData, nil), name)
        }
    }

    func testRejectsEncryptedKey() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("enc").path
        XCTAssertEqual(run(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "secret-pass", "-f", path]).status, 0)
        let text = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(SSHPrivateKey.isEncrypted(text))
        XCTAssertThrowsError(try SSHPrivateKey(openSSH: text)) { error in
            XCTAssertEqual(error as? SSHPrivateKey.ParseError, .encrypted)
        }
        XCTAssertThrowsError(try SSHPrivateKey(openSSH: "not a key"))
    }

    // MARK: - End to end through ssh-keygen

    func testEndToEndSigningAllKeyTypes() throws {
        for (type, bits) in [("ed25519", nil), ("ecdsa", "256"), ("ecdsa", "384"), ("ecdsa", "521"), ("rsa", "3072")] {
            try assertAgentSigns(type: type, bits: bits)
        }
    }

    func testDenyingAuthorizerFailsSigning() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try generateKey(type: "ed25519", bits: nil, in: dir)
        let key = try SSHPrivateKey(openSSH: String(contentsOfFile: path, encoding: .utf8))
        try FileManager.default.removeItem(atPath: path)

        let asked = Counter()
        let server = SSHAgentServer(socketPath: dir.appendingPathComponent("a.sock").path,
                                    upstreamPath: nil) { comment, fingerprint in
            asked.add(comment + " " + fingerprint)
            return false
        }
        server.setIdentities([SSHAgentIdentity(publicKeyBlob: key.publicKeyBlob, comment: key.comment) { key }])
        try server.start()
        defer { server.stop() }

        let msg = dir.appendingPathComponent("msg.txt")
        try Data("hello".utf8).write(to: msg)
        let r = run(["/usr/bin/ssh-keygen", "-Y", "sign", "-n", "test", "-f", path + ".pub", msg.path],
                    env: ["SSH_AUTH_SOCK": server.socketPath])
        XCTAssertNotEqual(r.status, 0, r.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: msg.path + ".sig"))
        XCTAssertEqual(asked.values, ["\(key.comment) \(key.fingerprint)"])
    }

    /// Keys living in the upstream agent stay visible and usable through ours.
    func testForwardsToUpstreamAgent() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ownPath = try generateKey(type: "ed25519", bits: nil, in: dir)
        let upPath = try generateKey(type: "ecdsa", bits: "256", in: dir)
        let own = try SSHPrivateKey(openSSH: String(contentsOfFile: ownPath, encoding: .utf8))
        let up = try SSHPrivateKey(openSSH: String(contentsOfFile: upPath, encoding: .utf8))
        try FileManager.default.removeItem(atPath: ownPath)
        try FileManager.default.removeItem(atPath: upPath)

        let upstream = SSHAgentServer(socketPath: dir.appendingPathComponent("up.sock").path,
                                      upstreamPath: nil) { _, _ in true }
        upstream.setIdentities([SSHAgentIdentity(publicKeyBlob: up.publicKeyBlob, comment: up.comment) { up }])
        try upstream.start()
        defer { upstream.stop() }

        let server = SSHAgentServer(socketPath: dir.appendingPathComponent("a.sock").path,
                                    upstreamPath: upstream.socketPath) { _, _ in false }
        server.setIdentities([SSHAgentIdentity(publicKeyBlob: own.publicKeyBlob, comment: own.comment) { own }])
        try server.start()
        defer { server.stop() }

        let list = run(["/usr/bin/ssh-add", "-L"], env: ["SSH_AUTH_SOCK": server.socketPath])
        XCTAssertEqual(list.status, 0, list.output)
        XCTAssertTrue(list.output.contains(own.publicKeyLine))
        XCTAssertTrue(list.output.contains(up.publicKeyLine))

        // Our own key is denied by the authorizer, but the upstream key signs.
        let msg = dir.appendingPathComponent("msg.txt")
        try Data("via upstream".utf8).write(to: msg)
        let r = run(["/usr/bin/ssh-keygen", "-Y", "sign", "-n", "test", "-f", upPath + ".pub", msg.path],
                    env: ["SSH_AUTH_SOCK": server.socketPath])
        XCTAssertEqual(r.status, 0, r.output)
        let check = run(["/usr/bin/ssh-keygen", "-Y", "check-novalidate", "-n", "test",
                         "-f", upPath + ".pub", "-s", msg.path + ".sig"], stdin: msg)
        XCTAssertEqual(check.status, 0, check.output)
    }

    func testStaleSocketIsReplacedAndLiveOneRefused() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sock = dir.appendingPathComponent("a.sock").path
        FileManager.default.createFile(atPath: sock, contents: Data())   // stale leftover
        let a = SSHAgentServer(socketPath: sock, upstreamPath: nil) { _, _ in true }
        try a.start()
        defer { a.stop() }
        let attrs = try FileManager.default.attributesOfItem(atPath: sock)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let b = SSHAgentServer(socketPath: sock, upstreamPath: nil) { _, _ in true }
        XCTAssertThrowsError(try b.start())
    }

    // MARK: - Helpers

    private func assertAgentSigns(type: String, bits: String?) throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try generateKey(type: type, bits: bits, in: dir)
        let key = try SSHPrivateKey(openSSH: String(contentsOfFile: path, encoding: .utf8))
        // Remove the private file so ssh-keygen can ONLY sign through our agent.
        try FileManager.default.removeItem(atPath: path)

        let server = SSHAgentServer(socketPath: dir.appendingPathComponent("a.sock").path,
                                    upstreamPath: nil) { _, _ in true }
        server.setIdentities([SSHAgentIdentity(publicKeyBlob: key.publicKeyBlob, comment: key.comment) { key }])
        try server.start()
        defer { server.stop() }

        let msg = dir.appendingPathComponent("msg.txt")
        try Data("signed by wireline agent: \(type)".utf8).write(to: msg)
        let sign = run(["/usr/bin/ssh-keygen", "-Y", "sign", "-n", "test", "-f", path + ".pub", msg.path],
                       env: ["SSH_AUTH_SOCK": server.socketPath])
        XCTAssertEqual(sign.status, 0, "\(type) \(bits ?? ""): \(sign.output)")
        let check = run(["/usr/bin/ssh-keygen", "-Y", "check-novalidate", "-n", "test",
                         "-f", path + ".pub", "-s", msg.path + ".sig"], stdin: msg)
        XCTAssertEqual(check.status, 0, "\(type) \(bits ?? ""): \(check.output)")
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
        var values: [String] { lock.lock(); defer { lock.unlock() }; return items }
    }

    /// Short path under /tmp: unix socket paths are capped at 104 bytes.
    private func tempDir() throws -> URL {
        let url = URL(fileURLWithPath: "/tmp/wl-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func generateKey(type: String, bits: String?, in dir: URL) throws -> String {
        let path = dir.appendingPathComponent("id_\(type)\(bits ?? "")").path
        var argv = ["/usr/bin/ssh-keygen", "-q", "-t", type, "-N", "", "-C", "wireline-test-\(type)", "-f", path]
        if let bits { argv += ["-b", bits] }
        let r = run(argv)
        XCTAssertEqual(r.status, 0, r.output)
        return path
    }

    @discardableResult
    private func run(_ argv: [String], env: [String: String] = [:], stdin: URL? = nil) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        var environment = ProcessInfo.processInfo.environment
        environment["SSH_AUTH_SOCK"] = nil
        environment.merge(env) { $1 }
        p.environment = environment
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = stdin.flatMap { try? FileHandle(forReadingFrom: $0) } ?? FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
