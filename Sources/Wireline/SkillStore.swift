import Foundation
import Observation

/// A curated ops playbook the AI can pull on demand. Unlike a snippet (one
/// command), a skill is a set of instructions + judgement the model follows,
/// typically a read-only investigation it runs step by step via the agent loop.
struct WLSkill: Identifiable, Codable, Sendable, Equatable {
    var id: String            // stable slug, e.g. "diagnose-load"
    var name: String          // display name
    var description: String   // one-line trigger, shown to the model for disclosure
    var body: String          // full instructions, injected only when invoked
    var builtin: Bool = false
    var enabled: Bool = true
}

/// Holds built-in ops skills plus any user-defined ones. Built-ins live in code;
/// only the user's enable/disable choices and custom skills are persisted.
@Observable
@MainActor
final class SkillStore {
    static let shared = SkillStore()

    private(set) var skills: [WLSkill]
    private let fileURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wireline", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("skills.json")

        // Start from the built-ins, then fold in persisted state (enable flags +
        // custom skills), so new built-ins appear automatically on upgrade.
        var merged = Self.builtins
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([WLSkill].self, from: data) {
            for s in saved {
                if let i = merged.firstIndex(where: { $0.id == s.id }) {
                    // Built-in: keep code's name/description/body, honor saved `enabled`.
                    merged[i].enabled = s.enabled
                    if !merged[i].builtin { merged[i] = s }
                } else {
                    merged.append(s)   // custom skill
                }
            }
        }
        skills = merged
    }

    var enabledSkills: [WLSkill] { skills.filter(\.enabled) }
    func skill(id: String) -> WLSkill? { skills.first { $0.id == id } }

    func setEnabled(_ enabled: Bool, id: String) {
        guard let i = skills.firstIndex(where: { $0.id == id }) else { return }
        skills[i].enabled = enabled
        persist()
    }

    func upsert(_ s: WLSkill) {
        if let i = skills.firstIndex(where: { $0.id == s.id }) { skills[i] = s } else { skills.append(s) }
        persist()
    }

    func remove(_ s: WLSkill) {
        guard !s.builtin else { return }   // built-ins can be disabled, not deleted
        skills.removeAll { $0.id == s.id }
        persist()
    }

    private func persist() {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted]
        if let data = try? enc.encode(skills) { try? data.write(to: fileURL, options: .atomic) }
    }

    // MARK: built-in ops skills (read-only-first; mutations always go through the
    // normal danger-confirmation / sandbox path).

    static let builtins: [WLSkill] = [
        WLSkill(id: "diagnose-load", name: "负载 / CPU 诊断",
                description: "排查 CPU、负载、内存异常升高的根因",
                body: """
                目标：定位这台机器负载/CPU/内存偏高的根因。全程只用只读命令，逐条执行、看结果再决定下一步。
                建议顺序：
                1. `uptime` 看 1/5/15 分钟负载，和 CPU 核数（`nproc`）对比判断是否真的过载。
                2. `top -b -n1 | head -n 20` 或 `ps aux --sort=-%cpu | head` 找吃 CPU 的进程；`ps aux --sort=-%rss | head` 找吃内存的进程。
                3. `vmstat 1 3` 看 r 队列、us/sy/wa/si-so；`wa` 高说明是 IO 等待，`si/so` 非零说明在换页。
                4. 内存：`free -h`；若疑似 OOM，`dmesg -T 2>/dev/null | grep -i -E 'oom|killed process' | tail`。
                5. 若指向某服务/容器，再针对性看它的日志（只读）。
                最后用中文给结论：谁在占资源、是 CPU/内存/IO 哪一类、下一步建议（涉及重启/kill 只给建议，交由用户确认执行）。
                """),
        WLSkill(id: "disk-triage", name: "磁盘空间排查",
                description: "定位磁盘占满的分区、目录与常见元凶",
                body: """
                目标：找出磁盘被谁占满。只读排查，删除类操作一律只给建议、由用户确认。
                建议顺序：
                1. `df -h` 看哪个分区吃紧；`df -i` 顺带看 inode 是否耗尽。
                2. 对告急挂载点，从根往下逐层定位：`du -x -h -d1 <mount> 2>/dev/null | sort -rh | head`，命中大目录后继续下钻。
                3. 常见元凶：日志 `du -sh /var/log/* 2>/dev/null | sort -rh | head`；容器 `docker system df`（若有 docker）；journal `journalctl --disk-usage`；已删除但被占用的文件 `lsof -nP 2>/dev/null | grep -i deleted | head`。
                4. 找大文件：`find <dir> -xdev -type f -size +200M -exec ls -lh {} \\; 2>/dev/null | head`。
                结论用中文：哪个分区、被什么占用、可安全清理的候选（给具体命令但不代执行），以及是否是“已删除仍占用”需重启进程的情况。
                """),
        WLSkill(id: "service-health", name: "服务健康检查",
                description: "检查失败的 systemd 单元、监听端口与关键服务状态",
                body: """
                目标：快速判断这台机器上的服务是否健康。只读。
                建议顺序：
                1. `systemctl --failed --no-legend` 列出失败单元；对可疑单元 `systemctl status <unit> --no-pager` 与 `journalctl -u <unit> -n 50 --no-pager`（只读）。
                2. 监听端口：`ss -tlnp`（或 `ss -tlnp | sort`），核对预期服务是否在监听、是否意外绑定到 0.0.0.0。
                3. 若是 web/反代机：`nginx -t` 只做语法校验（只读，不 reload）。
                4. 负载与时间：`uptime`、`date`（时钟漂移也会引发一堆问题）。
                中文结论：哪些服务异常、端口是否符合预期、最可能的问题点与下一步（重启/修复只给建议）。
                """),
        WLSkill(id: "docker-audit", name: "容器巡检",
                description: "排查容器重启、资源占用与不健康容器",
                body: """
                目标：巡检本机 Docker 容器状态。只读命令。
                建议顺序：
                1. `docker ps -a --format 'table {{.Names}}\\t{{.Status}}\\t{{.Image}}'` 看有没有 Restarting / Exited / unhealthy。
                2. 资源：`docker stats --no-stream`。
                3. 对异常容器：`docker logs --tail 80 <name>`（只读）、`docker inspect <name> --format '{{.State.Health.Status}} {{.RestartCount}}'`。
                4. 空间：`docker system df`。
                中文结论：哪些容器异常、疑似原因（崩溃重启 / OOM / 健康检查失败 / 镜像问题）、下一步建议（重启/清理只给命令，不代执行）。
                """),
        WLSkill(id: "security-baseline", name: "安全基线快检",
                description: "快速核查登录失败、开放端口与可疑监听",
                body: """
                目标：对这台机器做一次轻量安全快检。**严格只读**，不做任何更改。
                建议顺序：
                1. 对外监听面：`ss -tlnp` 找绑定在 0.0.0.0/:: 的端口，判断是否有本不该暴露的服务。
                2. 登录失败：`journalctl -u ssh -u sshd --since '24 hours ago' 2>/dev/null | grep -i 'failed\\|invalid' | tail` 或 `grep -i 'failed password' /var/log/auth.log 2>/dev/null | tail`。
                3. 当前登录与最近登录：`who`、`last -n 15`。
                4. 提权相关（只读查看）：`getent group sudo wheel 2>/dev/null`；`ls -l /etc/sudoers.d 2>/dev/null`。
                中文结论：暴露面是否合理、是否有明显的暴力破解迹象、可疑登录/账号，给出需要人工进一步核实的点。**只给建议，不改配置。**
                """)
    ]
}
