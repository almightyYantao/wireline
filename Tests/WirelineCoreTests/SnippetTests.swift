import XCTest
@testable import WirelineCore

final class SnippetTests: XCTestCase {

    // MARK: Placeholders

    func testBraceAndGuillemetParameters() {
        let cmd = "scp {{file}} {{user:root}}@«host» && echo «host» {{file}}"
        XCTAssertEqual(Snippet.parameters(in: cmd), [
            SnippetParameter(name: "file"),
            SnippetParameter(name: "user", defaultValue: "root"),
            SnippetParameter(name: "host"),
        ])
    }

    func testDefaultOnLaterOccurrenceCounts() {
        let params = Snippet.parameters(in: "echo {{n}} {{n:3}}")
        XCTAssertEqual(params, [SnippetParameter(name: "n", defaultValue: "3")])
    }

    func testNonASCIIName() {
        XCTAssertEqual(Snippet.parameters(in: "systemctl restart {{服务名:nginx}}").first,
                       SnippetParameter(name: "服务名", defaultValue: "nginx"))
        XCTAssertEqual(Snippet.parameters(in: "tail -f «日志路径»").map(\.name), ["日志路径"])
    }

    func testGoTemplatesAreNotParameters() {
        let cmds = [
            "docker ps --format '{{.Names}}'",
            "docker inspect -f '{{range .Mounts}}{{.Source}}{{end}}' x",
            "docker inspect --format '{{json .Config}}' x",
            "kubectl get po -o go-template='{{ .metadata.name }}'",
            "helm template {{- if .Values.x }}",
        ]
        for c in cmds { XCTAssertEqual(Snippet.parameters(in: c), [], c) }
        // …while a real blank next to a template still counts.
        XCTAssertEqual(Snippet.parameters(in: "docker ps --format '{{.Names}}' | grep {{name}}").map(\.name),
                       ["name"])
    }

    func testFillUsesValueThenDefaultThenEmpty() {
        let cmd = "ssh {{user:root}}@{{host}} -p {{port:22}}"
        XCTAssertEqual(Snippet.fill(cmd, with: ["host": "web1", "port": ""]), "ssh root@web1 -p 22")
        XCTAssertEqual(Snippet.fill(cmd, with: ["user": "deploy", "host": "h", "port": "2222"]),
                       "ssh deploy@h -p 2222")
        XCTAssertEqual(Snippet.fill("echo «x» {{y}}", with: [:]), "echo  ")
        // Templates survive filling untouched.
        XCTAssertEqual(Snippet.fill("docker ps --format '{{.Names}}' | grep {{k}}", with: ["k": "api"]),
                       "docker ps --format '{{.Names}}' | grep api")
    }

    func testInitialValuesPreferLastTyped() {
        var s = Snippet(titleZh: "", titleEn: "t", command: "tail -n {{n:50}} {{file}}")
        XCTAssertEqual(s.initialValues(), ["n": "50", "file": ""])
        s.lastValues = ["file": "/var/log/x"]
        XCTAssertEqual(s.initialValues(), ["n": "50", "file": "/var/log/x"])
    }

    // MARK: Danger

    func testDangerDetection() {
        for c in ["sudo apt upgrade", "rm -rf /tmp/x", "rm -fr build", "dd if=a of=b",
                  "mkfs.ext4 /dev/sdb1", "sudo reboot", "shutdown -h now", "echo x > /dev/sda",
                  "ls; sudo -i", "git reset --hard"] {
            XCTAssertTrue(SnippetSafety.isDangerous(c), c)
        }
        for c in ["df -h", "ls -la", "cmd 2>/dev/null", "echo hi > /dev/stderr", "grep sudoers x",
                  "pseudo thing", "add file", "rm file.txt", "systemctl status nginx"] {
            XCTAssertFalse(SnippetSafety.isDangerous(c), c)
        }
        XCTAssertEqual(SnippetSafety.dangerReasons("sudo rm -rf /x"), ["sudo", "rm -rf"])
    }

    // MARK: Platform

    func testPlatformMatching() {
        let any = Snippet(titleZh: "", titleEn: "a", command: "uptime")
        let linux = Snippet(titleZh: "", titleEn: "l", command: "free -h", platform: .linux)
        let mac = Snippet(titleZh: "", titleEn: "m", command: "vm_stat", platform: .macos)
        XCTAssertTrue(any.matches(platform: .macos, hostGroup: nil))
        XCTAssertTrue(linux.matches(platform: .linux, hostGroup: nil))
        XCTAssertTrue(linux.matches(platform: .unknown, hostGroup: nil), "unprobed SSH counts as Linux")
        XCTAssertFalse(linux.matches(platform: .macos, hostGroup: nil))
        XCTAssertFalse(linux.matches(platform: .otherUnix, hostGroup: nil))
        XCTAssertTrue(mac.matches(platform: .macos, hostGroup: nil))
        XCTAssertFalse(mac.matches(platform: .unknown, hostGroup: nil))

        var bound = any; bound.hostGroup = "prod"
        XCTAssertTrue(bound.matches(platform: .linux, hostGroup: "prod"))
        XCTAssertFalse(bound.matches(platform: .linux, hostGroup: "dev"))
        XCTAssertFalse(bound.matches(platform: .macos, hostGroup: nil))
    }

    func testUnameParsing() {
        XCTAssertEqual(PanePlatform.fromUname("Darwin\n"), .macos)
        XCTAssertEqual(PanePlatform.fromUname("Linux"), .linux)
        XCTAssertEqual(PanePlatform.fromUname("FreeBSD"), .otherUnix)
        XCTAssertEqual(PanePlatform.fromUname("(无输出，退出码 255)"), .unknown)
        XCTAssertEqual(PanePlatform.fromUname("ssh: connect to host x port 22: Connection refused"), .unknown)
    }

    func testRankingPutsNonMatchingLastAndFrequentFirst() {
        let now = Date()
        let mac = Snippet(titleZh: "", titleEn: "mac", command: "vm_stat", platform: .macos, useCount: 50, lastUsed: now)
        let a = Snippet(titleZh: "", titleEn: "a", command: "uptime")
        let b = Snippet(titleZh: "", titleEn: "b", command: "df -h", useCount: 3, lastUsed: now)
        let ranked = Snippet.ranked([mac, a, b], platform: .linux, hostGroup: nil, now: now)
        XCTAssertEqual(ranked.map(\.titleEn), ["b", "a", "mac"])
    }

    // MARK: Categories

    func testCategoryInference() {
        let cases: [(String, SnippetCategory)] = [
            ("df -h", .disk), ("free -h", .memory), ("vm_stat", .memory), ("uptime", .cpu),
            ("top -l 1 -o cpu -n 10", .cpu), ("ss -tlnp", .network), ("lsof -nP -iTCP -sTCP:LISTEN", .network),
            ("ps aux | grep x", .process), ("tail -f /var/log/syslog", .logs), ("journalctl -u nginx", .logs),
            ("docker ps -a", .docker), ("sudo systemctl restart nginx", .systemd), ("git status", .git),
            ("sudo apt update", .package), ("brew upgrade", .package),
            ("cd /opt/app\n./deploy.sh", .script), ("echo hi", .generic),
        ]
        for (cmd, cat) in cases { XCTAssertEqual(SnippetCategory.infer(from: cmd), cat, cmd) }
    }

    // MARK: Titles & migration

    func testSplitTitle() {
        XCTAssertTrue(Snippet.splitTitle("磁盘占用 / Disk usage") == ("磁盘占用", "Disk usage"))
        XCTAssertTrue(Snippet.splitTitle("Disk usage / 磁盘占用") == ("磁盘占用", "Disk usage"))
        XCTAssertTrue(Snippet.splitTitle("AI 脚本") == ("AI 脚本", ""))
        XCTAssertTrue(Snippet.splitTitle("deploy") == ("", "deploy"))
        XCTAssertTrue(Snippet.splitTitle("in / out") == ("", "in / out"))
        let s = Snippet(titleZh: "磁盘", titleEn: "", command: "df")
        XCTAssertEqual(s.title(chinese: false), "磁盘", "falls back to the other language")
    }

    func testMigratesOldFormat() throws {
        let id = UUID()
        let legacy = """
        [{"id":"\(id.uuidString)","name":"磁盘占用 / Disk usage","command":"df -h"},
         {"id":"\(UUID().uuidString)","name":"内存 / Memory","command":"free -h"},
         {"id":"\(UUID().uuidString)","name":"My deploy","command":"cd /srv && ./deploy «env»"}]
        """.data(using: .utf8)!
        let (snippets, migrated) = try SnippetMigration.load(legacy)
        XCTAssertTrue(migrated)
        XCTAssertEqual(snippets[0].id, id)
        XCTAssertEqual(snippets[0].titleZh, "磁盘占用")
        XCTAssertEqual(snippets[0].titleEn, "Disk usage")
        XCTAssertEqual(snippets[0].platform, .any)
        XCTAssertEqual(snippets[1].platform, .linux, "old built-in gets its real platform")
        XCTAssertEqual(snippets[2].titleEn, "My deploy")
        XCTAssertEqual(snippets[2].placeholders, ["env"])
        XCTAssertTrue(snippets.contains { $0.command == "vm_stat" && $0.platform == .macos })

        // Written back, it reloads as the new format — and an old build can still read `name`.
        let data = try JSONEncoder().encode(snippets)
        let (again, migratedAgain) = try SnippetMigration.load(data)
        XCTAssertFalse(migratedAgain)
        XCTAssertEqual(again, snippets)
        let raw = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        XCTAssertEqual(raw?[0]["name"] as? String, "磁盘占用 / Disk usage")
    }

    func testRoundTripKeepsAllFields() throws {
        let s = Snippet(titleZh: "重启", titleEn: "Restart", command: "sudo systemctl restart {{svc}}",
                        platform: .linux, hostGroup: "prod", categoryOverride: .systemd,
                        lastValues: ["svc": "nginx"], useCount: 4, lastUsed: Date(timeIntervalSince1970: 1000))
        let back = try JSONDecoder().decode([Snippet].self, from: JSONEncoder().encode([s]))
        XCTAssertEqual(back, [s])
    }
}

private func == (a: (zh: String, en: String), b: (String, String)) -> Bool { a.zh == b.0 && a.en == b.1 }
