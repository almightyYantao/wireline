import Foundation
import WirelineCore

/// A scripted tour of the island with fake activities, for reviewing its
/// look and motion without real AI turns or agents: Debug → Preview Notch
/// Island (debug builds), or launch with `WIRELINE_ISLAND_PREVIEW=1`.
///
/// About a minute: an AI turn that runs a command and then asks to run a
/// risky one (Allow / Deny work), a fleet run with failures, Claude Code
/// working then done, Codex asking for you, a long command failing in a
/// background tab. Every row is removed at the end.
@MainActor
enum IslandPreview {
    static func runIfRequested() {
        guard ProcessInfo.processInfo.environment["WIRELINE_ISLAND_PREVIEW"] == "1" else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { run() }
    }

    private static var generation = 0

    static func run() {
        generation += 1
        let gen = generation
        let c = IslandCenter.shared
        let loc = Localizer.shared
        let ids = ["preview:ai", "preview:fleet", "preview:claude", "preview:codex", "preview:cmd"]
        ids.forEach(c.remove)

        func at(_ s: Double, _ body: @escaping @MainActor () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + s) {
                MainActor.assumeIsolated { if gen == generation { body() } }
            }
        }
        func item(_ id: String, _ source: IslandSource, _ title: String, _ detail: String, _ tone: IslandTone,
                  progress: IslandProgress? = nil, confirmation: IslandConfirmation? = nil,
                  persistent: Bool = false) -> IslandItem {
            IslandItem(id: id, source: source, title: title, detail: detail, tone: tone, progress: progress,
                       confirmation: confirmation, persistent: persistent, at: Date())
        }

        // AI agent turn on a host.
        at(0) { c.upsert(item("preview:ai", .ai, "prod-web-01", loc.t("思考中…", "Thinking…"), .working)) }
        at(1.6) { c.upsert(item("preview:ai", .ai, "prod-web-01", loc.t("执行 df -h @ prod-web-01", "Running df -h @ prod-web-01"), .working)) }

        // A coding agent in a pane.
        at(0.8) {
            c.upsert(item("preview:claude", .codingAgent("claude"), "Claude Code · ~/src/wireline",
                          loc.t("工作中…", "Working…"), .working, persistent: true))
        }

        // Fleet run: 12 hosts, two fail.
        at(1.2) {
            c.upsert(item("preview:fleet", .fleet, loc.t("批量执行", "Fleet run"), "systemctl is-active nginx", .working,
                          progress: IslandProgress(done: 0, total: 12)))
        }
        for n in 1...12 {
            at(1.2 + Double(n) * 0.55) {
                guard var row = c.board.item("preview:fleet") else { return }
                row.progress = IslandProgress(done: n, total: 12, failed: n >= 9 ? 2 : n >= 5 ? 1 : 0)
                c.upsert(row)
            }
        }
        at(8.4) {
            c.finish("preview:fleet", success: false, detail: loc.t("2/12 台失败", "2/12 hosts failed"),
                     pulse: "✕ " + loc.t("2/12 台失败", "2/12 hosts failed") + " · 7s")
        }

        // The AI wants to run something risky: the card opens with Allow / Deny.
        at(4) {
            let question = IslandConfirmation(kind: .dangerousCommand, subject: "rm -rf /var/log/nginx/*.gz",
                                              note: loc.t("删除 nginx 的历史压缩日志，约 2.1 GB；不影响当前日志。",
                                                          "Deletes nginx's rotated, compressed logs (~2.1 GB); current logs untouched."))
            c.upsert(item("preview:ai", .ai, "prod-web-01", loc.t("等你确认", "Needs your OK"), .attention,
                          confirmation: question))
            c.setDecision("preview:ai") { decision in
                guard gen == generation else { return }
                if decision == .deny {
                    c.finish("preview:ai", success: true, detail: loc.t("已取消", "Cancelled"), pulse: nil)
                    return
                }
                c.upsert(item("preview:ai", .ai, "prod-web-01",
                              loc.t("执行 rm -rf /var/log/nginx/*.gz", "Running rm -rf /var/log/nginx/*.gz"), .working))
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    MainActor.assumeIsolated {
                        guard gen == generation else { return }
                        c.finish("preview:ai", success: true, detail: loc.t("完成", "Done"),
                                 pulse: "✓ " + loc.t("完成", "Done") + " · 14s")
                    }
                }
            }
        }

        // Codex waiting for you (a notification it sent).
        at(12) {
            c.upsert(item("preview:codex", .codingAgent("codex"), "Codex · ~/src/api",
                          loc.t("需要你批准：写入 package.json", "Needs approval: write package.json"), .attention,
                          persistent: true))
        }

        // A long build failing in a background tab.
        at(22) {
            let detail = loc.t("退出码 2 · ", "exit 2 · ") + "2m 05s"
            c.upsert(item("preview:cmd", .command, "make release", detail, .working))
            c.finish("preview:cmd", success: false, detail: detail, pulse: "✕ make release · 2m 05s")
        }

        // Claude Code finishes its turn.
        at(27) {
            c.upsert(item("preview:claude", .codingAgent("claude"), "Claude Code · ~/src/wireline",
                          loc.t("完成，等你下一步", "Done — your turn"), .success, persistent: true))
            c.finish("preview:claude", success: true, detail: loc.t("完成，等你下一步", "Done — your turn"),
                     pulse: "✓ Claude Code · 26s")
        }

        at(70) { ids.forEach(c.remove) }
    }
}
