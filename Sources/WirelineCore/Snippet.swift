import Foundation

// The command-snippet model ("快捷指令") and the pure logic around it:
// placeholders, danger detection, platform scope, category inference, ranking,
// and decoding of the old `{id, name, command}` format. The UI lives in the
// app target (SnippetStore / SnippetPicker); everything here is testable.

/// Which systems a snippet is meant for.
public enum SnippetPlatform: String, Codable, Sendable, CaseIterable {
    /// Works anywhere (`uptime`, `df -h`, `tail -f`).
    case any
    case linux
    case macos
}

/// What we know about the system a pane is talking to.
public enum PanePlatform: String, Codable, Sendable {
    case macos
    case linux
    /// Some other Unix (`uname -s` said FreeBSD, …).
    case otherUnix
    /// Not probed yet — an SSH host is assumed to be Linux until we know better.
    case unknown

    /// Map `uname -s` output to a platform.
    public static func fromUname(_ output: String) -> PanePlatform {
        let s = output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasPrefix("darwin") { return .macos }
        if s.hasPrefix("linux") { return .linux }
        if s.isEmpty || s.contains(" ") || s.hasPrefix("(") { return .unknown }   // error text, not a kernel name
        return .otherUnix
    }
}

/// Icon category, derived from the command unless the user overrides it.
public enum SnippetCategory: String, Codable, Sendable, CaseIterable {
    case disk, memory, cpu, network, process, logs, docker, git, package, systemd, script, generic

    /// SF Symbol for the category.
    public var symbol: String {
        switch self {
        case .disk: "internaldrive"
        case .memory: "memorychip"
        case .cpu: "gauge.with.dots.needle.50percent"
        case .network: "network"
        case .process: "list.bullet.rectangle"
        case .logs: "doc.text.magnifyingglass"
        case .docker: "shippingbox"
        case .git: "arrow.triangle.branch"
        case .package: "archivebox"
        case .systemd: "gearshape.2"
        case .script: "scroll"
        case .generic: "terminal"
        }
    }

    /// First match wins, so the more specific tools come first.
    private static let rules: [(SnippetCategory, [String])] = [
        (.docker, ["docker", "podman", "kubectl", "k9s", "helm", "nerdctl", "crictl"]),
        (.git, ["git", "gh"]),
        (.systemd, ["systemctl", "service", "launchctl"]),
        (.logs, ["journalctl", "tail", "dmesg", "less", "log"]),
        (.package, ["apt", "apt-get", "yum", "dnf", "brew", "pacman", "apk", "zypper", "pip", "pip3",
                    "npm", "pnpm", "yarn", "snap", "port", "dpkg", "rpm"]),
        (.disk, ["df", "du", "lsblk", "fdisk", "ncdu", "mount", "diskutil", "iostat", "findmnt"]),
        (.memory, ["free", "vm_stat", "vmstat", "memory_pressure", "smem"]),
        (.network, ["ss", "netstat", "lsof", "ip", "ifconfig", "ping", "curl", "wget", "dig", "nslookup",
                    "traceroute", "mtr", "nc", "tcpdump", "iptables", "nft", "ufw", "route", "arp", "host"]),
        (.cpu, ["uptime", "top", "htop", "btop", "mpstat", "sar", "nproc", "lscpu", "sysctl"]),
        (.process, ["ps", "pgrep", "pkill", "kill", "killall", "pstree"]),
    ]

    /// Guess a category from the command text.
    public static func infer(from command: String) -> SnippetCategory {
        let lines = Snippet.commandLines(command)
        // `tail -f /var/log/…` is logs whatever the tool; `/var/log` alone is enough.
        if command.contains("/var/log") { return .logs }
        // The tools actually invoked: the first word of every pipeline / chain
        // segment, skipping `sudo`, env assignments and the like.
        var tools: [String] = []
        for line in lines {
            for seg in line.split(whereSeparator: { "|;&".contains($0) }) {
                let words = seg.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                if let w = words.first(where: { !["sudo", "env", "nohup", "time", "watch", "-n"].contains($0)
                                                  && !$0.contains("=") && Int($0) == nil }) {
                    tools.append(((w as NSString).lastPathComponent).lowercased())
                }
            }
        }
        // Rank by the first tool's category (ps … | grep → process, not logs).
        for tool in tools {
            for (cat, names) in rules where names.contains(tool) { return cat }
        }
        return lines.count > 1 ? .script : .generic
    }
}

/// One `{{name}}` / `{{name:default}}` / `«name»` blank in a command.
public struct SnippetParameter: Equatable, Sendable {
    public var name: String
    public var defaultValue: String?
    public init(name: String, defaultValue: String? = nil) {
        self.name = name; self.defaultValue = defaultValue
    }
}

/// A reusable command snippet.
public struct Snippet: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    /// Chinese title (may be empty).
    public var titleZh: String
    /// English title (may be empty).
    public var titleEn: String
    public var command: String
    public var platform: SnippetPlatform
    /// Only meant for hosts in this group (nil = any host).
    public var hostGroup: String?
    /// Icon override; nil = derived from the command.
    public var categoryOverride: SnippetCategory?
    /// The values typed into each parameter last time, pre-filled next time.
    public var lastValues: [String: String]
    public var useCount: Int
    public var lastUsed: Date?
    /// Folder path, at most two levels: "Docker" or "Ops/Docker" (nil = top level).
    public var folder: String?
    /// Set on the shipped templates, so "restore built-ins" knows what's missing.
    public var builtinID: String?

    public init(id: UUID = UUID(), titleZh: String, titleEn: String, command: String,
                platform: SnippetPlatform = .any, hostGroup: String? = nil,
                categoryOverride: SnippetCategory? = nil, lastValues: [String: String] = [:],
                useCount: Int = 0, lastUsed: Date? = nil, folder: String? = nil, builtinID: String? = nil) {
        self.id = id; self.titleZh = titleZh; self.titleEn = titleEn; self.command = command
        self.platform = platform; self.hostGroup = hostGroup; self.categoryOverride = categoryOverride
        self.lastValues = lastValues; self.useCount = useCount; self.lastUsed = lastUsed
        self.folder = SnippetFolders.normalize(folder); self.builtinID = builtinID
    }

    /// From a single title in either language (or the old "中文 / English" form).
    public init(title: String, command: String, platform: SnippetPlatform = .any) {
        let (zh, en) = Self.splitTitle(title)
        self.init(titleZh: zh, titleEn: en, command: command, platform: platform)
    }

    // MARK: Titles

    /// The title in the UI language, falling back to the other one.
    public func title(chinese: Bool) -> String {
        let primary = chinese ? titleZh : titleEn, other = chinese ? titleEn : titleZh
        let p = primary.trimmingCharacters(in: .whitespaces)
        return p.isEmpty ? other : primary
    }

    /// Both titles, for search: the other language is a keyword only.
    public var allTitles: String { titleZh + " " + titleEn }

    /// Split an old-format "磁盘占用 / Disk usage" title. A title with no " / "
    /// (or two halves in the same script) goes to the language it's written in.
    public static func splitTitle(_ title: String) -> (zh: String, en: String) {
        let t = title.trimmingCharacters(in: .whitespaces)
        let parts = t.components(separatedBy: " / ")
        if parts.count == 2 {
            let a = parts[0].trimmingCharacters(in: .whitespaces), b = parts[1].trimmingCharacters(in: .whitespaces)
            if hasCJK(a) && !hasCJK(b) { return (a, b) }
            if hasCJK(b) && !hasCJK(a) { return (b, a) }
        }
        return hasCJK(t) ? (t, "") : ("", t)
    }

    static func hasCJK(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value) }
    }

    // MARK: Shape

    /// Non-empty lines of the command.
    public static func commandLines(_ command: String) -> [String] {
        command.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    public var lineCount: Int { Self.commandLines(command).count }
    public var isMultiLine: Bool { lineCount > 1 }
    public var category: SnippetCategory { categoryOverride ?? SnippetCategory.infer(from: command) }

    // MARK: Placeholders

    /// `«name»` / `«name:default»`, and `{{name}}` / `{{name:default}}`.
    /// The brace form only takes a plain identifier name, so Go templates in the
    /// commands people save here (`docker ps --format '{{.Names}}'`,
    /// `{{range .Mounts}}…{{end}}`, `{{json .}}`) are left alone.
    private static let placeholderRE = try? NSRegularExpression(
        pattern: #"«\s*([^«»:\n]{1,60}?)\s*(?::([^«»\n]*))?»|\{\{\s*([\p{L}_][\p{L}\p{N}_-]{0,59})\s*(?::([^{}\n]*))?\}\}"#)

    /// Go template actions that look like a bare identifier.
    private static let templateKeywords: Set<String> = [
        "end", "else", "range", "if", "with", "define", "template", "block", "break", "continue", "nil",
    ]

    private struct Match { let range: NSRange; let name: String; let defaultValue: String? }

    private static func matches(in command: String) -> [Match] {
        guard let re = placeholderRE else { return [] }
        let ns = command as NSString
        return re.matches(in: command, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            for (nameGroup, defGroup) in [(1, 2), (3, 4)] where m.range(at: nameGroup).location != NSNotFound {
                let name = ns.substring(with: m.range(at: nameGroup)).trimmingCharacters(in: .whitespaces)
                if nameGroup == 3, templateKeywords.contains(name) { return nil }
                let def = m.range(at: defGroup).location != NSNotFound
                    ? ns.substring(with: m.range(at: defGroup)).trimmingCharacters(in: .whitespaces) : nil
                return Match(range: m.range, name: name, defaultValue: def)
            }
            return nil
        }
    }

    /// The parameters in a command, unique by name, in first-appearance order.
    /// A default given on any occurrence counts.
    public static func parameters(in command: String) -> [SnippetParameter] {
        var out: [SnippetParameter] = []
        for m in matches(in: command) {
            if let i = out.firstIndex(where: { $0.name == m.name }) {
                if out[i].defaultValue == nil { out[i].defaultValue = m.defaultValue }
            } else {
                out.append(SnippetParameter(name: m.name, defaultValue: m.defaultValue))
            }
        }
        return out
    }

    public var parameters: [SnippetParameter] { Self.parameters(in: command) }
    /// Parameter names, in order (kept for callers that only need names).
    public var placeholders: [String] { parameters.map(\.name) }

    /// Replace every placeholder: the supplied value, else its default, else "".
    public static func fill(_ command: String, with values: [String: String]) -> String {
        let params = parameters(in: command)
        var out = command
        for m in matches(in: command).reversed() {
            let typed = values[m.name] ?? ""
            let def = params.first { $0.name == m.name }?.defaultValue ?? ""
            out = (out as NSString).replacingCharacters(in: m.range, with: typed.isEmpty ? def : typed)
        }
        return out
    }

    public func filled(with values: [String: String]) -> String { Self.fill(command, with: values) }

    /// Starting values for the fill-in form: last time's, else the default.
    public func initialValues() -> [String: String] {
        var v: [String: String] = [:]
        for p in parameters { v[p.name] = lastValues[p.name] ?? p.defaultValue ?? "" }
        return v
    }

    // MARK: Scope

    /// Whether the snippet suits a pane. An unprobed SSH host counts as Linux;
    /// a host-group binding must match the pane's host's group.
    public func matches(platform pane: PanePlatform, hostGroup group: String?) -> Bool {
        if let bound = hostGroup, !bound.isEmpty, bound != group { return false }
        switch platform {
        case .any: return true
        case .linux: return pane == .linux || pane == .unknown
        case .macos: return pane == .macos
        }
    }

    /// Recency-weighted use count: frequent *and* recent snippets float up.
    public func frecency(now: Date = Date()) -> Double {
        guard useCount > 0 else { return 0 }
        let days = lastUsed.map { max(0, now.timeIntervalSince($0) / 86_400) } ?? 365
        let recency = days < 1 ? 4.0 : days < 7 ? 2.0 : days < 30 ? 1.0 : 0.5
        return log2(Double(useCount) + 1) * recency
    }

    /// Matching snippets first (non-matching are dimmed, never hidden), then by
    /// frecency, then the user's own order.
    public static func ranked(_ snippets: [Snippet], platform: PanePlatform, hostGroup: String?,
                              now: Date = Date()) -> [Snippet] {
        snippets.enumerated().sorted { a, b in
            let ma = a.element.matches(platform: platform, hostGroup: hostGroup)
            let mb = b.element.matches(platform: platform, hostGroup: hostGroup)
            if ma != mb { return ma }
            let fa = a.element.frecency(now: now), fb = b.element.frecency(now: now)
            if fa != fb { return fa > fb }
            return a.offset < b.offset
        }.map(\.element)
    }

    // MARK: Codable (reads the old `{id, name, command}` format)

    private enum CodingKeys: String, CodingKey {
        case id, name, titleZh, titleEn, command, platform, hostGroup, category, lastValues, useCount, lastUsed
        case folder, builtinID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
        let zh = try c.decodeIfPresent(String.self, forKey: .titleZh)
        let en = try c.decodeIfPresent(String.self, forKey: .titleEn)
        if zh == nil && en == nil {
            (titleZh, titleEn) = Self.splitTitle(try c.decodeIfPresent(String.self, forKey: .name) ?? "")
        } else {
            titleZh = zh ?? ""; titleEn = en ?? ""
        }
        // An unknown raw value (written by a newer build) falls back instead of failing the file.
        platform = (try? c.decodeIfPresent(SnippetPlatform.self, forKey: .platform)) ?? .any
        hostGroup = try c.decodeIfPresent(String.self, forKey: .hostGroup)
        categoryOverride = try? c.decodeIfPresent(SnippetCategory.self, forKey: .category)
        lastValues = (try? c.decodeIfPresent([String: String].self, forKey: .lastValues)) ?? [:]
        useCount = (try? c.decodeIfPresent(Int.self, forKey: .useCount)) ?? 0
        lastUsed = try? c.decodeIfPresent(Date.self, forKey: .lastUsed)
        folder = SnippetFolders.normalize(try? c.decodeIfPresent(String.self, forKey: .folder))
        builtinID = try? c.decodeIfPresent(String.self, forKey: .builtinID)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        // `name` keeps the file readable by builds from before the redesign.
        let legacy = [titleZh, titleEn].filter { !$0.isEmpty }.joined(separator: " / ")
        try c.encode(legacy, forKey: .name)
        try c.encode(titleZh, forKey: .titleZh)
        try c.encode(titleEn, forKey: .titleEn)
        try c.encode(command, forKey: .command)
        try c.encode(platform, forKey: .platform)
        try c.encodeIfPresent(hostGroup, forKey: .hostGroup)
        try c.encodeIfPresent(categoryOverride, forKey: .category)
        if !lastValues.isEmpty { try c.encode(lastValues, forKey: .lastValues) }
        if useCount > 0 { try c.encode(useCount, forKey: .useCount) }
        try c.encodeIfPresent(lastUsed, forKey: .lastUsed)
        try c.encodeIfPresent(folder, forKey: .folder)
        try c.encodeIfPresent(builtinID, forKey: .builtinID)
    }

    // MARK: Built-ins

    private static func builtin(_ id: String, _ zh: String, _ en: String, _ folder: String, _ command: String,
                                _ platform: SnippetPlatform = .any) -> Snippet {
        Snippet(titleZh: zh, titleEn: en, command: command, platform: platform, folder: folder, builtinID: id)
    }

    /// The shipped templates. Ids are stable: "restore built-ins" re-adds any
    /// whose id is missing and never touches one the user kept or edited.
    public static let defaults: [Snippet] = [
        builtin("sysinfo", "系统信息", "System info", "系统 System",
                "uname -a; cat /etc/os-release 2>/dev/null | head -4; uptime", .linux),
        builtin("sysinfo-mac", "系统信息", "System info", "系统 System", "sw_vers; uname -a; uptime", .macos),
        builtin("disk", "磁盘占用", "Disk usage", "系统 System", "df -h"),
        builtin("du-top", "目录大小", "Largest directories", "系统 System",
                "du -sh {{path:.}}/* 2>/dev/null | sort -rh | head -20"),
        builtin("mem", "内存", "Memory", "系统 System", "free -h", .linux),
        builtin("mem-mac", "内存", "Memory", "系统 System", "vm_stat", .macos),
        builtin("load", "系统负载", "Load", "系统 System", "uptime"),
        // BSD `ps` (macOS) has no --sort.
        builtin("top", "进程占用", "Top processes", "系统 System", "ps aux --sort=-%cpu | head", .linux),
        builtin("top-mac", "进程占用", "Top processes", "系统 System", "top -l 1 -o cpu -n 10", .macos),
        builtin("findproc", "查找进程", "Find process", "系统 System", "ps aux | grep {{keyword}}"),
        builtin("ports", "监听端口", "Listening ports", "网络 Network", "ss -tlnp", .linux),
        builtin("ports-mac", "监听端口", "Listening ports", "网络 Network", "lsof -nP -iTCP -sTCP:LISTEN", .macos),
        builtin("port-who", "端口占用", "Who uses a port", "网络 Network", "sudo lsof -nP -i :{{port:80}}"),
        builtin("docker-ps", "容器列表", "Containers", "Docker",
                "docker ps --format 'table {{.Names}}\\t{{.Image}}\\t{{.Status}}\\t{{.Ports}}'"),
        builtin("docker-logs", "容器日志", "Container logs", "Docker", "docker logs -f --tail 200 {{container}}"),
        builtin("docker-stats", "容器资源", "Container stats", "Docker", "docker stats --no-stream"),
        builtin("tail", "查看日志", "Tail log", "日志 Logs", "tail -f {{path:/var/log/syslog}}"),
        builtin("journal", "服务日志", "Service log", "日志 Logs", "journalctl -u {{service}} -n 200 -f", .linux),
    ]

    /// Snippets in `current` plus the built-ins whose id is missing from it.
    public static func restoringDefaults(_ current: [Snippet]) -> (snippets: [Snippet], added: Int) {
        let have = Set(current.compactMap(\.builtinID))
        let missing = defaults.filter { !have.contains($0.builtinID ?? "") }
        return (current + missing, missing.count)
    }

    /// The commands of the built-ins as they shipped before the redesign, keyed
    /// by command: an untouched old default gets the new platform on migration.
    public static let legacyDefaultPlatforms: [String: SnippetPlatform] = [
        "free -h": .linux,
        "ss -tlnp": .linux,
        "ps aux --sort=-%cpu | head": .linux,
    ]
}

/// Commands that must be confirmed before they run, even a single line.
public enum SnippetSafety {
    /// Short reasons ("sudo", "rm -rf", …); empty when nothing risky was found.
    public static func dangerReasons(_ command: String) -> [String] {
        let c = command.lowercased()
        let checks: [(String, String)] = [
            ("sudo", #"(^|[\s;&|(])sudo\b"#),
            ("rm -rf", #"\brm\s+(-[a-z]*\s+)*-[a-z]*[rf]"#),
            ("dd", #"(^|[\s;&|(])dd\s"#),
            ("mkfs", #"\bmkfs(\.\w+)?\b"#),
            ("shutdown / reboot", #"\b(shutdown|reboot|halt|poweroff)\b"#),
            // Writing to a device; /dev/null and the std streams are harmless.
            ("> /dev/…", #">\s*/dev/(?!null\b|stdout\b|stderr\b|tty\b|fd/)"#),
            // The rest of the AI agent's list (`AICommandSafety`), minus its
            // loose `rm` pattern, which also catches a plain `rm file`.
            ("chmod -R 777", #"\bchmod\s+-r\s+777\b"#),
            ("drop database", #"\bdrop\s+(database|table)\b"#),
            ("git reset --hard", #"\bgit\s+reset\s+--hard\b"#),
            ("kill -9", #"\bkill(all)?\s+-9\b"#),
            ("fork bomb", #":\(\)\s*\{.*\};:"#),
        ]
        return checks.filter { c.range(of: $0.1, options: .regularExpression) != nil }.map(\.0)
    }

    public static func isDangerous(_ command: String) -> Bool { !dangerReasons(command).isEmpty }
}

/// Loading `snippets.json`, upgrading a file written before the redesign.
public enum SnippetMigration {
    /// Decode the file. `migrated` is true when it was in the old
    /// `{id, name, command}` format (and should be written back): titles are
    /// split into zh / en, untouched old built-ins get their real platform, and
    /// the new macOS built-ins are appended. Nothing the user wrote is dropped.
    public static func load(_ data: Data) throws -> (snippets: [Snippet], migrated: Bool) {
        let raw = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        var snippets = try JSONDecoder().decode([Snippet].self, from: data)
        let isLegacy = raw.contains { $0["titleZh"] == nil && $0["titleEn"] == nil }
        var migrated = false
        if isLegacy {
            for i in snippets.indices where snippets[i].platform == .any {
                if let p = Snippet.legacyDefaultPlatforms[snippets[i].command] { snippets[i].platform = p }
            }
            let have = Set(snippets.map(\.command))
            snippets += Snippet.defaults.filter { $0.platform == .macos && !have.contains($0.command) }
            migrated = true
        }
        // Files from before folders: recognise the shipped snippets still there
        // (same command and platform), so they get their id and folder.
        if !raw.contains(where: { $0["builtinID"] != nil }) {
            for i in snippets.indices where snippets[i].builtinID == nil {
                guard let d = Snippet.defaults.first(where: {
                    $0.command == snippets[i].command && $0.platform == snippets[i].platform
                }), !snippets.contains(where: { $0.builtinID == d.builtinID }) else { continue }
                snippets[i].builtinID = d.builtinID
                if snippets[i].folder == nil { snippets[i].folder = d.folder }
                migrated = true
            }
        }
        return (snippets, migrated)
    }
}

/// Folder paths: "/"-separated, trimmed, at most two levels.
public enum SnippetFolders {
    public static let maxDepth = 2

    public static func normalize(_ path: String?) -> String? {
        guard let path else { return nil }
        let parts = path.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.prefix(maxDepth).joined(separator: "/")
    }

    /// Every folder in use, parents included, sorted so a parent precedes its children.
    public static func all(in snippets: [Snippet]) -> [String] {
        var set = Set<String>()
        for f in snippets.compactMap(\.folder) {
            set.insert(f)
            if let parent = parent(of: f) { set.insert(parent) }
        }
        return set.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    public static func parent(of path: String) -> String? {
        let parts = path.split(separator: "/")
        return parts.count > 1 ? parts.dropLast().joined(separator: "/") : nil
    }

    /// Whether a snippet in `folder` shows when browsing `selected` (a parent shows its children's).
    public static func contains(_ selected: String, _ folder: String?) -> Bool {
        guard let folder else { return false }
        return folder == selected || folder.hasPrefix(selected + "/")
    }

    /// The folder list including folders kept without snippets in them.
    public static func all(in snippets: [Snippet], extra: [String]) -> [String] {
        var set = Set(all(in: snippets))
        for f in extra.compactMap(normalize) {
            set.insert(f)
            if let parent = parent(of: f) { set.insert(parent) }
        }
        return set.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// `rename` for a plain list of folder paths.
    public static func rename(_ old: String, to newPath: String?, in paths: [String]) -> [String] {
        let target = normalize(newPath)
        var out: [String] = []
        for p in paths {
            let renamed = contains(old, p) ? normalize((target ?? "") + p.dropFirst(old.count)) : p
            if let renamed, !out.contains(renamed) { out.append(renamed) }
        }
        return out
    }

    /// Rename a folder (and its subfolders) to `newPath`.
    public static func rename(_ old: String, to newPath: String?, in snippets: inout [Snippet]) {
        let target = normalize(newPath)
        for i in snippets.indices where contains(old, snippets[i].folder) {
            let rest = snippets[i].folder!.dropFirst(old.count)
            snippets[i].folder = normalize((target ?? "") + rest)
        }
    }
}

/// What `snippets-meta.json` keeps beside the snippet list (which stays a
/// plain array for older versions): folders with nothing in them yet and the
/// built-ins already offered. A missing key means a library from before it.
public struct SnippetLibraryMeta: Codable, Equatable, Sendable {
    public var emptyFolders: [String]
    public var seenBuiltins: [String]?

    public init(emptyFolders: [String] = [], seenBuiltins: [String]? = nil) {
        self.emptyFolders = emptyFolders; self.seenBuiltins = seenBuiltins
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        emptyFolders = (try? c.decodeIfPresent([String].self, forKey: .emptyFolders)) ?? []
        seenBuiltins = try? c.decodeIfPresent([String].self, forKey: .seenBuiltins)
    }
}

/// Write-then-rename, so a crash mid-write never leaves a half-written file.
public enum AtomicFile {
    public static func write(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: tmp)
        if rename(tmp.path, url.path) != 0 {
            let err = errno
            try? FileManager.default.removeItem(at: tmp)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err))
        }
    }
}
