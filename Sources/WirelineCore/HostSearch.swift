import Foundation

extension Host {
    /// Tags are `#words` inside the description, e.g. "primary db #prod #mysql".
    public var tags: [String] { HostTags.parse(descriptionText ?? "") }
}

/// Editing the `#tags` kept in a host's description text.
public enum HostTags {
    public static func parse(_ text: String) -> [String] {
        guard text.contains("#") else { return [] }
        var out: [String] = []
        for word in text.split(whereSeparator: { $0.isWhitespace || $0 == "," }) where word.hasPrefix("#") {
            let tag = word.dropFirst().trimmingCharacters(in: .punctuationCharacters.subtracting(["-", "_", "."]))
            if !tag.isEmpty, !out.contains(tag) { out.append(tag) }
        }
        return out
    }

    /// A typed tag as stored: no leading `#`, spaces or commas. Nil if empty.
    public static func normalize(_ raw: String) -> String? {
        let word = raw.trimmingCharacters(in: .whitespaces).drop { $0 == "#" }
            .split(whereSeparator: { $0.isWhitespace || $0 == "," }).first.map(String.init) ?? ""
        return parse("#" + word).first
    }

    /// `text` with `#tag` appended, unless it's already there.
    public static func adding(_ raw: String, to text: String) -> String {
        guard let tag = normalize(raw), !parse(text).contains(tag) else { return text }
        let base = text.trimmingCharacters(in: .whitespaces)
        return base.isEmpty ? "#" + tag : base + " #" + tag
    }

    /// `text` without the words carrying `#tag`; the other words stay in order.
    public static func removing(_ tag: String, from text: String) -> String {
        text.split(separator: " ", omittingEmptySubsequences: true)
            .filter { !($0.hasPrefix("#") && parse(String($0)) == [tag]) }
            .joined(separator: " ")
    }
}

/// The host fields a search can hit, in display order.
public enum HostSearchField: String, CaseIterable, Sendable, Comparable {
    case alias, address, user, group, tag, description

    public static func < (a: Self, b: Self) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}

/// One search hit: the host, its rank and which fields matched.
public struct HostSearchMatch: Sendable {
    public let host: Host
    public let score: Int
    public let fields: Set<HostSearchField>
}

/// Shared host matcher behind every host search box.
///
/// Whitespace-separated terms are ANDed; each must hit at least one field.
/// `tag:x`, `group:x` and `user:x` (also `#x` for a tag) filter on that field
/// only. Ranking: alias prefix > alias contains > address > other fields.
public struct HostQuery: Sendable, Equatable {
    public var terms: [String] = []
    public var tags: [String] = []
    public var groups: [String] = []
    public var users: [String] = []

    public init(_ raw: String) {
        for token in raw.lowercased().split(whereSeparator: \.isWhitespace).map(String.init) {
            if let v = Self.value(token, "tag:") { tags.append(v) }
            else if token.count > 1, token.hasPrefix("#") { tags.append(String(token.dropFirst())) }
            else if let v = Self.value(token, "group:") { groups.append(v) }
            else if let v = Self.value(token, "user:") { users.append(v) }
            else { terms.append(token) }
        }
    }

    private static func value(_ token: String, _ prefix: String) -> String? {
        guard token.hasPrefix(prefix), token.count > prefix.count else { return nil }
        return String(token.dropFirst(prefix.count))
    }

    public var isEmpty: Bool { terms.isEmpty && tags.isEmpty && groups.isEmpty && users.isEmpty }

    /// Words worth highlighting in a result row.
    public var highlightTerms: [String] { terms + tags + groups + users }

    public func match(_ host: Host) -> HostSearchMatch? {
        var fields = Set<HostSearchField>()
        var score = 0
        let hostTags = host.tags.map { $0.lowercased() }
        for t in tags {
            guard hostTags.contains(where: { $0.contains(t) }) else { return nil }
            fields.insert(.tag); score += hostTags.contains(t) ? 150 : 100
        }
        let group = (host.group ?? "").lowercased()
        for g in groups {
            guard group.contains(g) else { return nil }
            fields.insert(.group); score += group == g ? 150 : 100
        }
        let user = (host.user ?? "").lowercased()
        for u in users {
            guard user.contains(u) else { return nil }
            fields.insert(.user); score += user == u ? 150 : 100
        }
        for term in terms {
            guard let (s, f) = Self.best(term, host, hostTags) else { return nil }
            score += s; fields.formUnion(f)
        }
        return HostSearchMatch(host: host, score: score, fields: fields)
    }

    private static func best(_ term: String, _ host: Host, _ tags: [String]) -> (Int, Set<HostSearchField>)? {
        let alias = host.alias.lowercased()
        var score = 0
        var fields = Set<HostSearchField>()
        func hit(_ s: Int, _ f: HostSearchField) { score = max(score, s); fields.insert(f) }

        if alias == term { hit(1200, .alias) }
        else if alias.hasPrefix(term) { hit(1000, .alias) }
        else if alias.contains(term) { hit(700, .alias) }
        for addr in [host.hostname, host.proxyJump].compactMap({ $0?.lowercased() }) where addr.contains(term) {
            hit(addr.hasPrefix(term) ? 450 : 400, .address)
        }
        if (host.user ?? "").lowercased().contains(term) { hit(200, .user) }
        if (host.group ?? "").lowercased().contains(term) { hit(200, .group) }
        if tags.contains(where: { $0.contains(term) }) { hit(200, .tag) }
        if (host.descriptionText ?? "").lowercased().contains(term) { hit(150, .description) }
        if fields.isEmpty, isSubsequence(term, of: alias) { hit(50, .alias) }
        return fields.isEmpty ? nil : (score, fields)
    }

    static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var it = haystack.makeIterator()
        return needle.allSatisfy { ch in
            while let h = it.next() { if h == ch { return true } }
            return false
        }
    }
}

public enum HostSearch {
    /// Matching hosts, best first; ties keep alias order. Empty query → all.
    public static func search(_ query: String, in hosts: [Host]) -> [HostSearchMatch] {
        let q = HostQuery(query)
        let byAlias = hosts.sorted { $0.alias.localizedCaseInsensitiveCompare($1.alias) == .orderedAscending }
        if q.isEmpty { return byAlias.map { HostSearchMatch(host: $0, score: 0, fields: []) } }
        return byAlias.compactMap(q.match).enumerated()
            .sorted { $0.element.score != $1.element.score ? $0.element.score > $1.element.score : $0.offset < $1.offset }
            .map(\.element)
    }

    /// Ranges of `text` covered by any of `terms` (case-insensitive), merged.
    public static func highlightRanges(in text: String, terms: [String]) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        for term in terms where !term.isEmpty {
            var from = text.startIndex
            while let r = text.range(of: term, options: .caseInsensitive, range: from..<text.endIndex) {
                ranges.append(r); from = r.upperBound
            }
        }
        ranges.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<String.Index>] = []
        for r in ranges {
            if let last = merged.last, r.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound)
            } else { merged.append(r) }
        }
        return merged
    }
}
