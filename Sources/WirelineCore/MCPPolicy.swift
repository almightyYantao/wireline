import Foundation

/// How much an external AI client may do through Wireline's MCP server
/// without asking (Settings → AI → MCP server; config `mcp-mode`).
public enum MCPAccessMode: String, Codable, CaseIterable, Sendable {
    /// Reads and read-only commands only; everything else is refused.
    case readOnly = "read-only"
    /// Reads run; anything that may change something asks first.
    case confirm
    /// Runs without asking, except dangerous commands and wide fleet writes.
    case trust
}

/// What happens to one request.
public enum MCPVerdict: Equatable, Sendable {
    case allow
    case ask(dangerous: Bool)
    case deny(String)
}

/// The approval rules (docs/design/mcp-server.md §3.1), kept pure so they can
/// be tested and read in one place. Commands are judged as restored: a
/// placeholder never hides what really runs.
public enum MCPPolicy {
    /// A write to more hosts than this always asks, whatever the mode.
    public static let wideFleet = 5

    public static func command(_ command: String, mode: MCPAccessMode, hostCount: Int = 1) -> MCPVerdict {
        if let ph = AICommandSafety.unfilledPlaceholder(command) {
            return .deny("The command still has an unfilled placeholder \(ph); fill in a real value.")
        }
        if AICommandSafety.isReadOnly(command) { return .allow }
        if mode == .readOnly {
            return .deny("Wireline only allows read-only commands for MCP clients right now (Settings → AI → MCP server). Use a read-only command, or ask the user to run this one.")
        }
        if AICommandSafety.isDangerous(command) { return .ask(dangerous: true) }
        if mode == .confirm || hostCount > wideFleet { return .ask(dangerous: false) }
        return .allow
    }

    static let readOnlyRefusal = "Wireline only allows reads for MCP clients right now (Settings → AI → MCP server)."

    /// An ordinary change: writing a file, making a directory, a tunnel.
    public static func change(mode: MCPAccessMode) -> MCPVerdict {
        switch mode {
        case .readOnly: return .deny(readOnlyRefusal)
        case .confirm: return .ask(dangerous: false)
        case .trust: return .allow
        }
    }

    public static func fileWrite(mode: MCPAccessMode) -> MCPVerdict { change(mode: mode) }

    /// Asks in every mode: deleting files, moving data on or off this Mac,
    /// editing ~/.ssh/config.
    public static func alwaysAsk(mode: MCPAccessMode, dangerous: Bool = false) -> MCPVerdict {
        mode == .readOnly ? .deny(readOnlyRefusal) : .ask(dangerous: dangerous)
    }

    /// Wireline's own bookkeeping (host notes): no question, but not in read-only.
    public static func minor(mode: MCPAccessMode) -> MCPVerdict {
        mode == .readOnly ? .deny(readOnlyRefusal) : .allow
    }
}

/// A line diff for showing a file change before it is written.
public enum LineDiff {
    public enum Kind: Equatable, Sendable { case same, added, removed }

    public struct Line: Equatable, Sendable {
        public var kind: Kind
        public var text: String
    }

    /// Common prefix and suffix are cut first; the changed middle is diffed
    /// line by line when small enough, else shown as removed-then-added.
    public static func lines(old: String, new: String) -> [Line] {
        let a = old.components(separatedBy: "\n"), b = new.components(separatedBy: "\n")
        var p = 0
        while p < a.count, p < b.count, a[p] == b[p] { p += 1 }
        var s = 0
        while s < a.count - p, s < b.count - p, a[a.count - 1 - s] == b[b.count - 1 - s] { s += 1 }
        let midA = Array(a[p..<(a.count - s)]), midB = Array(b[p..<(b.count - s)])
        var out = a[..<p].map { Line(kind: .same, text: $0) }
        if midA.count * midB.count <= 4_000_000 {
            out += lcs(midA, midB)
        } else {
            out += midA.map { Line(kind: .removed, text: $0) } + midB.map { Line(kind: .added, text: $0) }
        }
        out += a[(a.count - s)...].map { Line(kind: .same, text: $0) }
        return out
    }

    private static func lcs(_ a: [String], _ b: [String]) -> [Line] {
        let n = a.count, m = b.count
        guard n > 0 || m > 0 else { return [] }
        // table[i][j] = LCS length of a[i...] and b[j...]
        var table = [[Int32]](repeating: [Int32](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var out: [Line] = []
        var i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, a[i] == b[j] {
                out.append(Line(kind: .same, text: a[i])); i += 1; j += 1
            } else if i < n, j == m || table[i + 1][j] >= table[i][j + 1] {
                out.append(Line(kind: .removed, text: a[i])); i += 1   // removals read first
            } else {
                out.append(Line(kind: .added, text: b[j])); j += 1
            }
        }
        return out
    }

    /// Unified-style text: changed lines with `context` unchanged lines around
    /// them, `…` where unchanged runs were skipped.
    public static func unified(old: String, new: String, context: Int = 3) -> String {
        let all = lines(old: old, new: new)
        let changed = all.indices.filter { all[$0].kind != .same }
        guard !changed.isEmpty else { return "" }
        var keep = Set<Int>()
        for c in changed { for k in max(0, c - context)...min(all.count - 1, c + context) { keep.insert(k) } }
        var out: [String] = []
        var last = -1
        for k in keep.sorted() {
            if last >= 0, k > last + 1 { out.append("…") }
            let l = all[k]
            out.append((l.kind == .added ? "+ " : l.kind == .removed ? "- " : "  ") + l.text)
            last = k
        }
        return out.joined(separator: "\n")
    }

    /// "+3 −1".
    public static func summary(old: String, new: String) -> String {
        let all = lines(old: old, new: new)
        return "+\(all.filter { $0.kind == .added }.count) −\(all.filter { $0.kind == .removed }.count)"
    }
}
