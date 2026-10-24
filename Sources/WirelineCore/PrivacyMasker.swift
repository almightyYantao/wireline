import Foundation

/// What to hide from the model, and the exact values known to be sensitive.
public struct PrivacyPolicy: Equatable, Sendable {
    public enum Level: String, Codable, CaseIterable, Sendable {
        case off
        /// Passwords, tokens, private keys, long random strings.
        case secrets
        /// Secrets, plus IP addresses and the real hostnames behind aliases.
        case all
    }

    public var level: Level
    /// `HostName` values from the ssh config (names or IPs). Masked at `.all`;
    /// the aliases themselves never are: they are already pseudonyms.
    public var knownHosts: [String]
    /// Exact values that are always secret (saved host passwords).
    public var knownSecrets: [String]

    public init(level: Level, knownHosts: [String] = [], knownSecrets: [String] = []) {
        self.level = level
        self.knownHosts = knownHosts
        self.knownSecrets = knownSecrets
    }
}

/// Reversible masking for text sent to an AI model.
///
/// A sensitive value becomes a placeholder such as `[WLk3f9_IP_2]`; the same
/// value always gets the same placeholder within one masker, so the model can
/// still compare and correlate. When the model writes a placeholder back (in a
/// command, a file it edits), `restore` turns it into the real value locally.
/// The mapping lives only in memory. The nonce keeps one masker's placeholders
/// from ever resolving in another; anything placeholder-shaped that survives
/// `restore` is stale or invented, and must not reach a host
/// (`containsPlaceholder`).
public final class PrivacyMasker: @unchecked Sendable {
    public enum Kind: String, Sendable { case ip = "IP", host = "HOST", secret = "SECRET" }

    public let level: PrivacyPolicy.Level
    public let nonce: String

    /// Beyond this many values, new ones are replaced one-way instead.
    public static let maxEntries = 10_000
    /// What an over-limit value becomes. Not a placeholder: it can't be restored.
    public static let irreversible = "[WL-REDACTED]"

    private let lock = NSLock()
    private var byValue: [String: String] = [:]     // "KIND\0value" → placeholder
    private var byToken: [String: String] = [:]     // placeholder → value
    private var counters: [Kind: Int] = [:]
    private var knownHosts: [String] = []
    private var knownSecrets: [String] = []

    public init(policy: PrivacyPolicy, nonce: String? = nil) {
        level = policy.level
        self.nonce = nonce ?? Self.makeNonce()
        updateKnown(hosts: policy.knownHosts, secrets: policy.knownSecrets)
    }

    /// Swap in the current hosts / passwords (one was added since this masker
    /// was made) without losing the placeholders already handed out.
    public func updateKnown(hosts: [String], secrets: [String]) {
        // Longest first, so `db.example.com` wins over `example.com`.
        let h = Array(Set(hosts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 3 }))
            .sorted { $0.count > $1.count }
        // Short passwords ("admin") would mask every ordinary use of the word.
        let s = Array(Set(secrets.filter { $0.count >= 6 })).sorted { $0.count > $1.count }
        lock.lock(); defer { lock.unlock() }
        knownHosts = h
        knownSecrets = s
    }

    // MARK: Placeholders

    private static let tokenPattern = #"\[WL([a-z0-9]{4})_(IP|HOST|SECRET)_(\d{1,6})\]"#
    private static let tokenRE = try! NSRegularExpression(pattern: tokenPattern)

    /// Whether `text` still holds anything placeholder-shaped: after `restore`,
    /// that is a placeholder this masker never issued (stale history, another
    /// conversation, or made up by the model).
    public static func containsPlaceholder(_ text: String) -> Bool {
        text.contains("[WL") && tokenRE.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// The placeholders left in `text` (for telling the model which ones failed).
    public static func placeholders(in text: String) -> [String] {
        let ns = text as NSString
        return tokenRE.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    private static func makeNonce() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<4).map { _ in alphabet.randomElement()! })
    }

    /// The placeholder for `value`, issuing one on first sight. Nil once the
    /// table is full.
    private func token(for value: String, kind: Kind) -> String? {
        lock.lock(); defer { lock.unlock() }
        let key = kind.rawValue + "\u{0}" + value
        if let t = byValue[key] { return t }
        guard byToken.count < Self.maxEntries else { return nil }
        let n = (counters[kind] ?? 0) + 1
        counters[kind] = n
        let t = "[WL\(nonce)_\(kind.rawValue)_\(n)]"
        byValue[key] = t
        byToken[t] = value
        return t
    }

    // MARK: Mask

    private struct Hit { var range: NSRange; var kind: Kind }

    /// `text` with every sensitive value replaced by its placeholder.
    public func mask(_ text: String) -> String {
        guard level != .off, !text.isEmpty else { return text }
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)

        // Placeholders already in the text (the model's own words coming back,
        // old history) are left alone and nothing may overlap them.
        var taken = Self.tokenRE.matches(in: text, range: whole).map(\.range)
        var hits: [Hit] = []
        func add(_ r: NSRange, _ kind: Kind) {
            guard r.location != NSNotFound, r.length > 0,
                  !taken.contains(where: { NSIntersectionRange($0, r).length > 0 }) else { return }
            taken.append(r)
            hits.append(Hit(range: r, kind: kind))
        }

        lock.lock()
        let knownHosts = knownHosts, knownSecrets = knownSecrets
        lock.unlock()

        // Order matters: earlier detectors claim their span first.
        for literal in knownSecrets {
            for r in Self.literalRanges(of: literal, in: ns, wordBounded: false) { add(r, .secret) }
        }
        for (re, group) in Self.secretDetectors {
            for m in re.matches(in: text, range: whole) {
                let r = m.range(at: group)
                if group == 0, re === Self.base64RE, !Self.looksRandom(ns.substring(with: r)) { continue }
                add(r, .secret)
            }
        }
        if level == .all {
            for host in knownHosts {
                let kind: Kind = Self.isIPAddress(host) ? .ip : .host
                for r in Self.literalRanges(of: host, in: ns, wordBounded: true) { add(r, kind) }
            }
            for m in Self.ipv4RE.matches(in: text, range: whole) where Self.maskableIPv4(ns.substring(with: m.range)) {
                add(m.range, .ip)
            }
            for m in Self.ipv6RE.matches(in: text, range: whole) where Self.maskableIPv6(ns.substring(with: m.range)) {
                add(m.range, .ip)
            }
        }

        guard !hits.isEmpty else { return text }
        // Number in reading order, then replace from the end so ranges hold.
        let replacements = hits.sorted { $0.range.location < $1.range.location }.map { h -> (NSRange, String) in
            let value = ns.substring(with: h.range)
            // A full table never lets anything through in the clear.
            return (h.range, token(for: value, kind: h.kind) ?? Self.irreversible)
        }
        let out = NSMutableString(string: text)
        for (range, replacement) in replacements.reversed() {
            out.replaceCharacters(in: range, with: replacement)
        }
        return out as String
    }

    // MARK: Restore

    /// `text` with every placeholder this masker issued turned back into its
    /// value. Unknown placeholders are left as they are (see `containsPlaceholder`).
    public func restore(_ text: String) -> String {
        guard text.contains("[WL") else { return text }
        let ns = text as NSString
        let matches = Self.tokenRE.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        lock.lock(); defer { lock.unlock() }
        let out = NSMutableString(string: text)
        for m in matches.reversed() {
            if let value = byToken[ns.substring(with: m.range)] {
                out.replaceCharacters(in: m.range, with: value)
            }
        }
        return out as String
    }

    /// Restores a streamed reply chunk by chunk, holding back a tail that might
    /// be the first half of a placeholder split across two chunks.
    public final class StreamRestorer {
        private let masker: PrivacyMasker
        private var pending = ""

        init(_ masker: PrivacyMasker) { self.masker = masker }

        /// What can be shown now (possibly empty).
        public func feed(_ chunk: String) -> String {
            pending += chunk
            if let open = pending.lastIndex(of: "["),
               Self.couldBePlaceholderPrefix(pending[open...]) {
                let ready = String(pending[..<open])
                pending = String(pending[open...])
                return masker.restore(ready)
            }
            let ready = pending
            pending = ""
            return masker.restore(ready)
        }

        /// Whatever was held back.
        public func finish() -> String {
            let rest = pending
            pending = ""
            return masker.restore(rest)
        }

        static func couldBePlaceholderPrefix(_ s: Substring) -> Bool {
            guard s.count <= 24, !s.contains("]") else { return false }
            return s.range(of: #"^\[(W(L[a-z0-9]{0,4}(_[A-Z]{0,6}(_\d{0,6})?)?)?)?$"#,
                           options: .regularExpression) != nil
        }
    }

    public func streamRestorer() -> StreamRestorer { StreamRestorer(self) }

    // MARK: Detectors

    private static func re(_ p: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: options)
    }

    private static let base64RE = re(#"(?<![A-Za-z0-9+/=_-])[A-Za-z0-9+/]{40,}={0,2}(?![A-Za-z0-9+/=_-])"#)

    /// (pattern, capture group holding the secret). Group 0 = the whole match.
    private static let secretDetectors: [(NSRegularExpression, Int)] = [
        // A private key, header to footer, as one value.
        (re(#"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----"#), 0),
        // `scheme://user:password@host`: just the password.
        (re(#"(?i)\b[a-z][a-z0-9+.-]*://[^/\s:@]+:([^@\s/]+)@"#), 1),
        // `Authorization: Bearer …`
        (re(#"(?i)\bbearer\s+([A-Za-z0-9._~+/=-]{8,})"#), 1),
        // JWT
        (re(#"\beyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}"#), 0),
        // Well-known key formats.
        (re(#"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#), 0),
        (re(#"\bgh[pousr]_[A-Za-z0-9]{36,}\b"#), 0),
        (re(#"\bgithub_pat_[A-Za-z0-9_]{40,}\b"#), 0),
        (re(#"\bglpat-[A-Za-z0-9_-]{20,}\b"#), 0),
        (re(#"\bsk-[A-Za-z0-9_-]{20,}\b"#), 0),
        (re(#"\bxox[abprs]-[A-Za-z0-9-]{10,}\b"#), 0),
        // `password=…`, `"token": "…"`, `API_KEY: …`: the value only, quotes kept.
        (re(#"(?i)(?<![A-Za-z0-9])(?:[A-Za-z0-9]+[_-])*(?:password|passwd|passphrase|secret|token|api[_-]?key|access[_-]?key|private[_-]?key|credentials?)["']?[ \t]*[:=][ \t]*["']?([^\s"',;]+)"#), 1),
        // Long hex (keys, hashes) and long random base64.
        (re(#"\b[A-Fa-f0-9]{32,}\b"#), 0),
        (base64RE, 0)
    ]

    /// A 40+ char run of base64 letters is a secret only if it looks random:
    /// upper, lower and digits all present. Plain paths and words don't.
    private static func looksRandom(_ s: String) -> Bool {
        var upper = false, lower = false, digit = false
        for c in s.unicodeScalars {
            switch c {
            case "A"..."Z": upper = true
            case "a"..."z": lower = true
            case "0"..."9": digit = true
            default: break
            }
        }
        return upper && lower && digit
    }

    private static let ipv4RE = re(#"(?<![\d.])(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(?:\.(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}(?![\d.]*\d)"#)
    private static let ipv6RE = re(#"(?<![0-9A-Fa-f:.\w])(?:[0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4}(?![0-9A-Fa-f:\w])"#)

    /// Loopback, "any", broadcast and netmasks carry nothing.
    private static func maskableIPv4(_ s: String) -> Bool {
        !(s.hasPrefix("127.") || s.hasPrefix("0.") || s.hasPrefix("255."))
    }

    /// Only real IPv6 addresses: `::`-compressed or full eight groups (so
    /// `12:30:45` and MAC addresses don't count), and not `::` / `::1`.
    private static func maskableIPv6(_ s: String) -> Bool {
        guard s != "::", s != "::1" else { return false }
        let colons = s.filter { $0 == ":" }.count
        guard s.contains("::") || colons == 7 else { return false }
        var addr = in6_addr()
        return inet_pton(AF_INET6, s, &addr) == 1
    }

    static func isIPAddress(_ s: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, s, &v4) == 1 || inet_pton(AF_INET6, s, &v6) == 1
    }

    /// Every occurrence of `literal`; `wordBounded` keeps `web1` from matching
    /// inside `web10` or `web1.example.com`'s neighbours.
    private static func literalRanges(of literal: String, in ns: NSString, wordBounded: Bool) -> [NSRange] {
        var out: [NSRange] = []
        var search = NSRange(location: 0, length: ns.length)
        let options: NSString.CompareOptions = wordBounded ? [.caseInsensitive] : []
        while true {
            let r = ns.range(of: literal, options: options, range: search)
            guard r.location != NSNotFound else { break }
            if !wordBounded || (isBoundary(ns, r.location - 1) && isBoundary(ns, r.location + r.length)) {
                out.append(r)
            }
            let next = r.location + max(r.length, 1)
            search = NSRange(location: next, length: ns.length - next)
        }
        return out
    }

    private static func isBoundary(_ ns: NSString, _ i: Int) -> Bool {
        guard i >= 0, i < ns.length else { return true }
        guard let scalar = UnicodeScalar(ns.character(at: i)) else { return true }
        let c = Character(scalar)
        return !(c.isLetter || c.isNumber || c == "-" || c == "_" || (c == "." && i + 1 < ns.length
            && UnicodeScalar(ns.character(at: i + 1)).map { CharacterSet.alphanumerics.contains($0) } == true))
    }
}
