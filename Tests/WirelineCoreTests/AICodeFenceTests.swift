import XCTest
@testable import WirelineCore

/// Agent mode executes whatever a reply proposes, so these rules decide what
/// reaches a real shell. The regression they guard against: the agent used to
/// take the first fence of *any* kind, so a reply that quoted `ls` output, a log
/// line or a JSON sample got run as a command.
final class AICodeFenceTests: XCTestCase {

    private func assertRuns(_ reply: String, _ expected: String, _ label: String) {
        guard case let .runnable(cmd) = AICodeFence.proposal(in: reply) else {
            return XCTFail("\(label): expected a runnable command, got \(AICodeFence.proposal(in: reply))")
        }
        XCTAssertEqual(cmd, expected, label)
    }

    private func assertRejected(_ reply: String, _ label: String) {
        XCTAssertEqual(AICodeFence.proposal(in: reply), .notACommand, label)
    }

    private func assertNothing(_ reply: String, _ label: String) {
        XCTAssertEqual(AICodeFence.proposal(in: reply), AICodeFence.Proposal.none, label)
    }

    func testRunsRealCommands() {
        assertRuns("先看容器状态：\n```bash\ndocker ps -a\n```", "docker ps -a", "tagged bash")
        assertRuns("```\nuptime\n```", "uptime", "untagged")
        // A one-word command must not be mistaken for the fence's language tag.
        assertRuns("```\nls\n```", "ls", "one-word untagged")
        assertRuns("```sh\nls\n```", "ls", "one-word, sh-tagged")
        assertRuns("```bash\ndocker inspect nginx --format '{{range .Mounts}}{{.Source}}{{end}}'\n```",
                   "docker inspect nginx --format '{{range .Mounts}}{{.Source}}{{end}}'", "go template")
        assertRuns("```bash\nfor f in /var/log/*.log; do\n  tail -n 3 \"$f\"\ndone\n```",
                   "for f in /var/log/*.log; do\n  tail -n 3 \"$f\"\ndone", "multi-line script")
        assertRuns("```bash\ncat > /tmp/a.conf <<'EOF'\nkey = value\nEOF\n```",
                   "cat > /tmp/a.conf <<'EOF'\nkey = value\nEOF", "heredoc")
        assertRuns("```bash\ncd /opt/app && git pull && docker compose up -d\n```",
                   "cd /opt/app && git pull && docker compose up -d", "chained")
        assertRuns("```bash\nsudo LC_ALL=C journalctl -u nginx -n 50\n```",
                   "sudo LC_ALL=C journalctl -u nginx -n 50", "sudo + env prefix")
        assertRuns("```bash\n(cd /opt && ls)\n```", "(cd /opt && ls)", "subshell")
        assertRuns("```bash\n# 检查磁盘\ndf -h\n```", "# 检查磁盘\ndf -h", "leading comment")
        // The prompt characters a model sometimes types in front of a command.
        assertRuns("```bash\n$ systemctl status nginx\n```", "systemctl status nginx", "prompt prefix")
        // Skip the quoted output, run the actual command that follows it.
        assertRuns("结果：\n```text\ntotal 12\n```\n再执行：\n```bash\nfree -m\n```", "free -m", "text then bash")
    }

    func testRefusesOutputDressedUpAsACommand() {
        assertRejected("```bash\ntotal 24\ndrwxr-xr-x 4 root root 4096 Jul 27 10:00 conf.d\n```", "ls -l output")
        assertRejected("```bash\nActive: active (running) since Sun 2026-07-26 10:11:12 CST; 1 day ago\n```", "systemctl status")
        assertRejected("```bash\n2026/07/27 10:00:01 [emerg] 1234#0: bind() to 0.0.0.0:80 failed\n```", "nginx error log")
        assertRejected("```bash\nCONTAINER ID   IMAGE   STATUS\nabc123   nginx   Up 3 days\n```", "docker ps table")
        assertRejected("```bash\nFilesystem      Size  Used Avail Use% Mounted on\n/dev/sda1  50G  20G  28G  42% /\n```", "df output")
        assertRejected("```bash\nTraceback (most recent call last):\n  File \"/app/main.py\", line 12, in <module>\n```", "traceback")
        assertRejected("```bash\nreal\t0m2.113s\nuser\t0m0.004s\n```", "time output")
        assertRejected("```bash\n┌────────┬───────┐\n│ name   │ state │\n└────────┴───────┘\n```", "box-drawing table")
        assertRejected("```\n{\n  \"name\": \"web\",\n  \"port\": 8080\n}\n```", "json in an untagged fence")
    }

    func testNonShellBlocksAreNotProposalsAtAll() {
        assertNothing("配置：\n```json\n{\"a\": 1}\n```", "json")
        assertNothing("```text\nnginx: configuration file test is successful\n```", "text")
        assertNothing("```yaml\napiVersion: v1\nkind: Pod\n```", "yaml")
        assertNothing("服务正常，nginx 已经在运行。", "no fence")
    }

    func testEchoedOutputIsNotACommand() {
        let previous = "nginx.conf\nconf.d\nmime.types\ndocker compose up -d\n"
        XCTAssertTrue(AICodeFence.echoesOutput("docker compose up -d", in: previous), "verbatim output line")
        XCTAssertFalse(AICodeFence.echoesOutput("systemctl reload nginx", in: previous), "a genuinely new command")
        // A short command stays runnable even when it also appears in the output —
        // `ls -la` in a listing says nothing about the model's intent.
        XCTAssertFalse(AICodeFence.echoesOutput("ls -la", in: "ls -la\n"), "short command")
        // A container/service name echoed back as if it were a command is caught.
        XCTAssertTrue(AICodeFence.echoesOutput("web-api-prod-1", in: "web-api-prod-1\ndb-primary\n"), "echoed name")
        XCTAssertFalse(AICodeFence.echoesOutput("cat nginx.conf", in: previous), "filename from a listing")
        XCTAssertFalse(AICodeFence.echoesOutput("docker compose up -d", in: ""), "no previous output")
    }

    func testBlockParsingKeepsLanguageTags() {
        let blocks = AICodeFence.blocks(in: "a\n```bash\nls\n```\nb\n```JSON\n{}\n```")
        XCTAssertEqual(blocks.map(\.lang), ["bash", "json"])
        XCTAssertEqual(blocks.map(\.body), ["ls", "{}"])
        XCTAssertTrue(blocks[0].isShell)
        XCTAssertFalse(blocks[1].isShell)
        // A fence still streaming in has no closing marker yet.
        XCTAssertEqual(AICodeFence.blocks(in: "```bash\nls -l").map(\.body), ["ls -l"])
    }
}

/// The placeholder guard has to tell "a blank the user must fill" apart from
/// Go-template syntax, which is ordinary command syntax in docker/kubectl/helm.
final class AICommandSafetyPlaceholderTests: XCTestCase {

    func testGoTemplatesAreNotPlaceholders() {
        // These used to halt agent mode: `{{end}}` matched the old `{{name}}` pattern.
        XCTAssertNil(AICommandSafety.unfilledPlaceholder("docker ps --format 'table {{.Names}}\t{{.Status}}'"))
        XCTAssertNil(AICommandSafety.unfilledPlaceholder("docker inspect x --format '{{range .Mounts}}{{.Source}}{{end}}'"))
        XCTAssertNil(AICommandSafety.unfilledPlaceholder("kubectl get pods -o go-template='{{range .items}}{{.metadata.name}}{{end}}'"))
        XCTAssertNil(AICommandSafety.unfilledPlaceholder("systemctl restart nginx"))
    }

    func testGuillemetPlaceholdersAreCaught() {
        XCTAssertEqual(AICommandSafety.unfilledPlaceholder("tail -f «日志路径»"), "«日志路径»")
        XCTAssertEqual(AICommandSafety.unfilledPlaceholder("systemctl restart «service»"), "«service»")
    }

    func testLegacyBracePlaceholdersStillCaught() {
        XCTAssertEqual(AICommandSafety.unfilledPlaceholder("tail -f {{path}}"), "{{path}}")
        // A non-ASCII name — which the old ASCII-only pattern silently missed.
        XCTAssertEqual(AICommandSafety.unfilledPlaceholder("tail -f {{参数名}}"), "{{参数名}}")
    }
}
