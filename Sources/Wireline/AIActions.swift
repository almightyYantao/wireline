import SwiftUI
import WirelineCore

/// An action the AI can ask Wireline to perform on itself (not on the shell).
/// The model emits a ```wl-action fenced JSON block; the user confirms before
/// anything happens.
enum WLAction: Equatable {
    case portForward(host: String, localPort: Int, remoteHost: String, remotePort: Int)
    case addHost(alias: String, hostname: String, user: String?, port: Int?, group: String?)
    case connect(host: String)
    case openFiles(host: String)
    case runSnippet(name: String)
    case remember(note: String)
    /// Call a tool on a configured MCP server. `argsJSON` keeps the arguments as a
    /// JSON string so the case stays `Equatable`.
    case mcpCall(server: String, tool: String, argsJSON: String)

    @MainActor
    func summary(_ loc: Localizer) -> String {
        switch self {
        case let .mcpCall(server, tool, argsJSON):
            let args = argsJSON == "{}" ? "" : "（\(argsJSON.prefix(120))）"
            return loc.t("调用 MCP 工具：\(server).\(tool)\(args)",
                         "Call MCP tool: \(server).\(tool)\(args)")
        case let .portForward(host, lp, rh, rp):
            return loc.t("建立端口转发：本地 \(lp) → \(host):\(rh):\(rp)",
                         "Create tunnel: local \(lp) → \(host):\(rh):\(rp)")
        case let .addHost(alias, hostname, user, port, group):
            let u = user.map { "\($0)@" } ?? ""
            let p = port.map { ":\($0)" } ?? ""
            let g = group.map { loc.t("，分组 \($0)", ", group \($0)") } ?? ""
            return loc.t("新增主机：\(alias) → \(u)\(hostname)\(p)\(g)",
                         "Add host: \(alias) → \(u)\(hostname)\(p)\(g)")
        case let .connect(host):
            return loc.t("连接主机：\(host)", "Connect to host: \(host)")
        case let .openFiles(host):
            return loc.t("打开文件浏览器：\(host)", "Open file browser: \(host)")
        case let .runSnippet(name):
            return loc.t("运行片段：\(name)", "Run snippet: \(name)")
        case let .remember(note):
            return loc.t("记住关于本主机：\(note)", "Remember about this host: \(note)")
        }
    }

    /// Parse the first ```wl-action JSON block out of an assistant message.
    static func parse(from text: String) -> WLAction? {
        let parts = text.components(separatedBy: "```")
        // Odd indices are code blocks; find one tagged `wl-action`.
        for i in stride(from: 1, to: parts.count, by: 2) {
            var body = parts[i]
            guard let nl = body.firstIndex(of: "\n") else { continue }
            let tag = body[body.startIndex..<nl].trimmingCharacters(in: .whitespaces).lowercased()
            guard tag == "wl-action" || tag == "wireline" else { continue }
            body = String(body[body.index(after: nl)...])
            guard let data = body.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let action = obj["action"] as? String else { continue }
            switch action {
            case "port_forward":
                guard let host = obj["host"] as? String,
                      let lp = intVal(obj["localPort"]), let rp = intVal(obj["remotePort"]) else { return nil }
                let rh = (obj["remoteHost"] as? String) ?? "127.0.0.1"
                return .portForward(host: host, localPort: lp, remoteHost: rh, remotePort: rp)
            case "add_host":
                guard let alias = obj["alias"] as? String,
                      let hostname = obj["hostname"] as? String else { return nil }
                return .addHost(alias: alias, hostname: hostname,
                                user: obj["user"] as? String, port: intVal(obj["port"]),
                                group: obj["group"] as? String)
            case "connect":
                guard let host = obj["host"] as? String else { return nil }
                return .connect(host: host)
            case "open_files":
                guard let host = obj["host"] as? String else { return nil }
                return .openFiles(host: host)
            case "run_snippet":
                guard let name = obj["name"] as? String else { return nil }
                return .runSnippet(name: name)
            case "remember":
                guard let note = obj["note"] as? String else { return nil }
                return .remember(note: note)
            case "mcp_call":
                guard let server = obj["server"] as? String,
                      let tool = obj["tool"] as? String else { return nil }
                let argsObj = obj["args"] ?? [String: Any]()
                let argsJSON = (try? JSONSerialization.data(withJSONObject: argsObj))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                return .mcpCall(server: server, tool: tool, argsJSON: argsJSON)
            default: return nil
            }
        }
        return nil
    }

    private static func intVal(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String { return Int(s) }
        return nil
    }
}

/// Inline confirmation card for a proposed `WLAction`.
struct ActionCardView: View {
    let action: WLAction
    let loc: Localizer
    var onConfirm: (WLAction) -> Void

    @State private var status = 0   // 0 pending · 1 done · 2 cancelled

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars").font(.system(size: 11)).foregroundStyle(WL.purple)
                Text(loc.t("操作确认", "Confirm action")).font(WL.small.weight(.semibold)).foregroundStyle(WL.purple)
            }
            Text(action.summary(loc)).font(WL.small).foregroundStyle(WL.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if status == 0 {
                HStack {
                    Spacer()
                    BracketButton(loc.t("取消", "Cancel")) { status = 2 }
                    BracketButton(loc.t("确认执行", "Confirm")) { onConfirm(action); status = 1 }
                }
            } else {
                Text(status == 1 ? loc.t("✓ 已执行", "✓ Done") : loc.t("已取消", "Cancelled"))
                    .font(WL.caption).foregroundStyle(status == 1 ? WL.green : WL.textDim)
            }
        }
        .padding(10)
        .background(WL.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: WL.radius(8)))
        .overlay(RoundedRectangle(cornerRadius: WL.radius(8)).stroke(WL.purple.opacity(0.5), lineWidth: 1))
    }
}
