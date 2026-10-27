import Foundation

/// A coding-agent conversation that can be picked up again in a fresh pane:
/// `claude --resume <id>` / `codex resume <id>`, run in `directory`.
public struct AIResume: Codable, Equatable, Sendable {
    public enum Agent: String, Codable, Sendable { case claude, codex }
    public var agent: Agent
    public var sessionID: String
    public var directory: String?

    public init(agent: Agent, sessionID: String, directory: String? = nil) {
        self.agent = agent
        self.sessionID = sessionID
        self.directory = directory
    }

    /// Ids are UUID-like; anything else (shell metacharacters …) is refused
    /// so the line typed into the shell can't be more than the resume itself.
    public static func isSafeID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && id.unicodeScalars.allSatisfy {
            ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "-" || $0 == "_"
        }
    }

    /// The line to type at the shell prompt (without Return); nil for an unsafe id.
    public var command: String? {
        guard Self.isSafeID(sessionID) else { return nil }
        switch agent {
        case .claude: return "claude --resume \(sessionID)"
        case .codex: return "codex resume \(sessionID)"
        }
    }
}

/// One pane of a saved workspace: what to open there.
public struct WorkspacePane: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case local, ssh, sftp, rdp }
    public var kind: Kind
    /// Host alias (empty for a local shell).
    public var alias: String
    public var title: String
    public var manuallyRenamed: Bool
    /// A local shell's working directory.
    public var directory: String?
    public var aiResume: AIResume?

    public init(kind: Kind, alias: String = "", title: String, manuallyRenamed: Bool = false,
                directory: String? = nil, aiResume: AIResume? = nil) {
        self.kind = kind
        self.alias = alias
        self.title = title
        self.manuallyRenamed = manuallyRenamed
        self.directory = directory
        self.aiResume = aiResume
    }

    enum CodingKeys: String, CodingKey { case kind, alias, title, manuallyRenamed, directory, aiResume }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        alias = try c.decodeIfPresent(String.self, forKey: .alias) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        manuallyRenamed = try c.decodeIfPresent(Bool.self, forKey: .manuallyRenamed) ?? false
        directory = try c.decodeIfPresent(String.self, forKey: .directory)
        aiResume = try? c.decodeIfPresent(AIResume.self, forKey: .aiResume)
    }
}

/// A tab's split tree.
public indirect enum WorkspaceNode: Codable, Equatable, Sendable {
    case pane(WorkspacePane)
    case split(vertical: Bool, ratio: Double, first: WorkspaceNode, second: WorkspaceNode)

    public var panes: [WorkspacePane] {
        switch self {
        case .pane(let p): [p]
        case .split(_, _, let a, let b): a.panes + b.panes
        }
    }

    /// Drop panes `keep` rejects; a split losing a side collapses to the other.
    public func filtered(_ keep: (WorkspacePane) -> Bool) -> WorkspaceNode? {
        switch self {
        case .pane(let p):
            return keep(p) ? self : nil
        case .split(let v, let r, let a, let b):
            switch (a.filtered(keep), b.filtered(keep)) {
            case (let x?, let y?): return .split(vertical: v, ratio: r, first: x, second: y)
            case (let x?, nil): return x
            case (nil, let y?): return y
            case (nil, nil): return nil
            }
        }
    }

    private enum CodingKeys: String, CodingKey { case pane, vertical, ratio, first, second }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let p = try c.decodeIfPresent(WorkspacePane.self, forKey: .pane) {
            self = .pane(p)
            return
        }
        let ratio = try c.decodeIfPresent(Double.self, forKey: .ratio) ?? 0.5
        self = .split(vertical: try c.decodeIfPresent(Bool.self, forKey: .vertical) ?? true,
                      ratio: ratio.isFinite ? min(max(ratio, 0.12), 0.88) : 0.5,
                      first: try c.decode(WorkspaceNode.self, forKey: .first),
                      second: try c.decode(WorkspaceNode.self, forKey: .second))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pane(let p):
            try c.encode(p, forKey: .pane)
        case .split(let v, let r, let a, let b):
            try c.encode(v, forKey: .vertical)
            try c.encode(r, forKey: .ratio)
            try c.encode(a, forKey: .first)
            try c.encode(b, forKey: .second)
        }
    }
}

public struct WorkspaceTab: Codable, Equatable, Sendable {
    /// A split tab's name.
    public var name: String?
    public var root: WorkspaceNode
    /// Index (in `root.panes` order) of the pane that had focus.
    public var focusedPane: Int?

    public init(name: String? = nil, root: WorkspaceNode, focusedPane: Int? = nil) {
        self.name = name
        self.root = root
        self.focusedPane = focusedPane
    }
}

/// A named window arrangement: its tabs, their splits and what runs in each pane.
public struct Workspace: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var tabs: [WorkspaceTab]
    public var activeTab: Int?
    public var created: Date
    public var updated: Date

    public init(id: UUID = UUID(), name: String, tabs: [WorkspaceTab], activeTab: Int? = nil,
                created: Date = Date(), updated: Date? = nil) {
        self.id = id
        self.name = name
        self.tabs = tabs
        self.activeTab = activeTab
        self.created = created
        self.updated = updated ?? created
    }

    public var paneCount: Int { tabs.reduce(0) { $0 + $1.root.panes.count } }
}

/// The saved workspaces, as stored on disk (`workspaces.json`).
public struct WorkspaceLibrary: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version: Int
    public var workspaces: [Workspace]

    public init(workspaces: [Workspace] = []) {
        self.version = Self.currentVersion
        self.workspaces = workspaces
    }

    public enum LoadError: Error { case newerVersion(Int) }

    /// Decode, migrating older shapes: version 0 was a bare array.
    public static func decode(_ data: Data) throws -> WorkspaceLibrary {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let bare = try? dec.decode([Workspace].self, from: data) {
            return WorkspaceLibrary(workspaces: bare)
        }
        let lib = try dec.decode(WorkspaceLibrary.self, from: data)
        guard lib.version <= currentVersion else { throw LoadError.newerVersion(lib.version) }
        return WorkspaceLibrary(workspaces: lib.workspaces)
    }

    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(self)
    }

    public static func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func workspace(named name: String) -> Workspace? {
        let n = Self.normalizedName(name).lowercased()
        return workspaces.first { $0.name.lowercased() == n }
    }

    /// Save under `name`: a workspace already called that is replaced (keeping
    /// its id and creation date), else a new one is added. Returns it.
    @discardableResult
    public mutating func save(name: String, tabs: [WorkspaceTab], activeTab: Int?, at now: Date = Date()) -> Workspace? {
        let n = Self.normalizedName(name)
        guard !n.isEmpty, !tabs.isEmpty else { return nil }
        if let i = workspaces.firstIndex(where: { $0.name.lowercased() == n.lowercased() }) {
            workspaces[i].name = n
            workspaces[i].tabs = tabs
            workspaces[i].activeTab = activeTab
            workspaces[i].updated = now
            return workspaces[i]
        }
        let w = Workspace(name: n, tabs: tabs, activeTab: activeTab, created: now)
        workspaces.append(w)
        return w
    }

    /// False when the name is empty or taken by another workspace.
    @discardableResult
    public mutating func rename(_ id: UUID, to name: String, at now: Date = Date()) -> Bool {
        let n = Self.normalizedName(name)
        guard !n.isEmpty, let i = workspaces.firstIndex(where: { $0.id == id }) else { return false }
        if workspaces.contains(where: { $0.id != id && $0.name.lowercased() == n.lowercased() }) { return false }
        workspaces[i].name = n
        workspaces[i].updated = now
        return true
    }

    public mutating func delete(_ id: UUID) {
        workspaces.removeAll { $0.id == id }
    }

    /// Most recently saved first.
    public var sorted: [Workspace] { workspaces.sorted { $0.updated > $1.updated } }
}

// MARK: - Coding-agent session ids

public enum CodingAgentSessions {
    /// Claude Code's own session id (and cwd) from a hook's JSON payload.
    public static func claude(hookPayload json: String) -> AIResume? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["session_id"] as? String, AIResume.isSafeID(id) else { return nil }
        return AIResume(agent: .claude, sessionID: id, directory: obj["cwd"] as? String)
    }

    /// The `session_meta` first line of a Codex rollout file.
    public static func codexMeta(line: String) -> (id: String, cwd: String?, started: Date?)? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["type"] as? String == "session_meta",
              let payload = obj["payload"] as? [String: Any],
              let id = (payload["id"] ?? payload["session_id"]) as? String, AIResume.isSafeID(id)
        else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let started = (payload["timestamp"] as? String).flatMap { f.date(from: $0) }
        return (id, payload["cwd"] as? String, started)
    }

    public static var codexRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    /// The newest Codex session (read-only scan of `root/YYYY/MM/DD/rollout-*.jsonl`)
    /// whose cwd is `cwd` and that was written to at or after `since`. A recent
    /// `since` only looks in the day folders it covers.
    public static func latestCodex(cwd: String, since: Date, now: Date = Date(), root: URL = codexRoot) -> AIResume? {
        let fm = FileManager.default
        var files: [URL] = []
        if now.timeIntervalSince(since) < 7 * 86400 {
            let cal = Calendar.current
            var day = cal.startOfDay(for: since.addingTimeInterval(-86400))
            while day <= now {
                let c = cal.dateComponents([.year, .month, .day], from: day)
                let dir = root.appendingPathComponent(String(format: "%04d/%02d/%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0))
                files += (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
                day = cal.date(byAdding: .day, value: 1, to: day) ?? now.addingTimeInterval(1)
            }
        } else if let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            files = walker.compactMap { $0 as? URL }
        }
        var candidates: [(URL, Date)] = []
        for url in files where url.pathExtension == "jsonl" && url.lastPathComponent.hasPrefix("rollout-") {
            guard let m = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  m >= since else { continue }
            candidates.append((url, m))
        }
        let want = (cwd as NSString).standardizingPath
        for (url, _) in candidates.sorted(by: { $0.1 > $1.1 }) {
            guard let line = firstLine(of: url), let meta = codexMeta(line: line),
                  let c = meta.cwd, (c as NSString).standardizingPath == want else { continue }
            return AIResume(agent: .codex, sessionID: meta.id, directory: c)
        }
        return nil
    }

    private static func firstLine(of url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var buf = Data()
        while buf.count < 1 << 20, let chunk = try? h.read(upToCount: 64 * 1024), !chunk.isEmpty {
            if let nl = chunk.firstIndex(of: 0x0A) {
                buf.append(chunk[chunk.startIndex..<nl])
                return String(decoding: buf, as: UTF8.self)
            }
            buf.append(chunk)
        }
        return buf.isEmpty ? nil : String(decoding: buf, as: UTF8.self)
    }
}
