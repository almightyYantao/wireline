import SwiftUI
import WirelineCore

/// Settings → General: Wireline's hooks for each coding agent that has a
/// hook mechanism, one row per agent.
struct AgentHooksList: View {
    @Environment(Localizer.self) private var loc

    var body: some View {
        ForEach(Array(AgentHookTarget.all.enumerated()), id: \.offset) { i, target in
            if i > 0 { WLFormDivider() }
            AgentHookRow(target: target)
        }
    }
}

private struct AgentHookRow: View {
    @Environment(Localizer.self) private var loc
    let target: AgentHookTarget
    @State private var installed = false
    @State private var detected = false
    @State private var error: String?

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    var body: some View {
        WLFormRow(loc("\(target.agent.displayName) 精确状态", "\(target.agent.displayName) exact status"),
                  detail: error ?? detail) {
            HStack(spacing: 8) {
                if installed {
                    Label(loc("已安装", "Installed"), systemImage: "checkmark.circle.fill")
                        .font(WL.small).foregroundStyle(WL.green)
                    Button(loc("卸载", "Remove")) { run { try target.uninstall(home: Self.home) } }
                        .buttonStyle(.wlSecondary)
                } else {
                    Button(loc("安装 hooks", "Install hooks")) { run { try target.install(home: Self.home) } }
                        .buttonStyle(.wlSecondary)
                }
            }
        }
        .onAppear(perform: refresh)
    }

    private var detail: String {
        let found = detected ? loc("已检测到", "Detected") : loc("未检测到", "Not detected")
        var d = "\(found) · ~/\(target.path)"
        switch target.agent {
        case .codex:
            d += loc("。首次需在 Codex 里用 /hooks 信任。", ". Trust them once with /hooks in Codex.")
        case .cursor:
            d += loc("。只报告开始 / 完成，等你确认仍靠猜测。", ". Reports start / done only; waiting is still guessed.")
        case .amp:
            d += loc("。插件只报告开始 / 完成。", ". The plugin reports start / done only.")
        case .aider:
            d += loc("。只在等待输入时报告完成。", ". Reports done when it waits for input only.")
        default: break
        }
        return d
    }

    private func run(_ action: () throws -> Void) {
        do {
            try action()
            error = nil
        } catch AgentHookTarget.Failure.conflict(let what) {
            error = loc("已有你自己的 \(what)，没有改动。", "You already have your own \(what); nothing changed.")
        } catch AgentHookTarget.Failure.unreadable {
            error = loc("配置文件不是合法 JSON，没有改动。", "The config file isn't valid JSON; nothing changed.")
        } catch {
            self.error = loc("失败：", "Failed: ") + error.localizedDescription
        }
        refresh()
    }

    private func refresh() {
        installed = target.isInstalled(home: Self.home)
        detected = Self.isDetected(target)
    }

    /// The agent's binary in a usual place, or its config already there.
    private static func isDetected(_ target: AgentHookTarget) -> Bool {
        let fm = FileManager.default
        let dirs = ["/opt/homebrew/bin", "/usr/local/bin", "\(home.path)/.local/bin", "\(home.path)/.bun/bin",
                    "\(home.path)/.npm-global/bin", "\(home.path)/.opencode/bin", "\(home.path)/.amp/bin"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        if dirs.contains(where: { fm.isExecutableFile(atPath: "\($0)/\(target.agent.rawValue)") }) { return true }
        let configDir = target.url(home: home).deletingLastPathComponent()
        return target.path.contains("/") && fm.fileExists(atPath: configDir.path)
    }
}
