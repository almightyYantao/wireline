import XCTest
@testable import WirelineCore

/// `isReadOnly` lets a command run without asking (the agent's read-only
/// sandbox, the MCP server's confirm / trust modes). Every "writes" case here
/// used to pass as read-only.
final class AICommandSafetyTests: XCTestCase {

    func testReaders() {
        for c in ["ls -la /etc", "df -h", "ps aux | grep nginx | head -5", "cat /etc/os-release",
                  "docker ps -a", "docker image ls", "kubectl get pods -A", "kubectl config current-context",
                  "git status", "git log --oneline -5", "git branch -a", "git remote -v", "git config --get user.name",
                  "systemctl status nginx", "journalctl -u nginx -n 50", "curl -s https://example.com/health",
                  "curl -sI -X HEAD https://example.com", "wget -qO- https://example.com", "ip addr show",
                  "ip route", "free -m && uptime", "LANG=C df -h", "find /var/log -name '*.gz' -mtime +7",
                  "echo hi | tee", "sort -n -k2 file", "mount", "hostname -f", "date +%s", "dmesg -T | tail"] {
            XCTAssertTrue(AICommandSafety.isReadOnly(c), "should be read-only: \(c)")
        }
    }

    func testWriters() {
        for c in [
            // Substitution runs anything.
            "echo $(rm -rf /tmp/x)", "echo `rm /tmp/x`", "cat <(rm /tmp/x)",
            "env rm -rf /tmp/x", "echo x | tee /etc/motd", "ls > /tmp/out", "sudo cat /etc/shadow",
            "curl -X POST https://api.example.com/deploy", "curl -XDELETE https://x", "curl --request=PUT https://x",
            "curl -d a=b https://x", "curl --data-raw '{}' https://x", "curl -F f=@x https://x",
            "curl -o /tmp/f https://x", "curl -sSO https://x/file", "curl -T f https://x",
            "wget https://example.com/file.tar.gz", "wget -O - https://x -o log",
            "find /tmp -name '*.log' -delete", "find . -exec rm {} \\;", "awk 'BEGIN{system(\"rm x\")}'",
            "sort -o file file", "sed -i s/a/b/ f", "ip link set eth0 down", "ip addr add 10.0.0.2/24 dev eth0",
            "ifconfig eth0 down", "mount /dev/sdb1 /mnt", "hostname newname", "date -s '2020-01-01'",
            "dmesg -c", "journalctl --vacuum-size=100M", "docker image rm nginx", "docker image prune -a",
            "kubectl config use-context prod", "git branch -D main", "git branch feature", "git remote add x url",
            "git config user.name x", "rm -f /tmp/x", "systemctl restart nginx", "docker rm -f web"
        ] {
            XCTAssertFalse(AICommandSafety.isReadOnly(c), "should not be read-only: \(c)")
        }
    }
}
