import Foundation

/// The four steps of an OpenSSH connection, as the connect panel shows them.
/// `connect` covers the TCP connect *and* the SSH handshake (version banner,
/// key exchange, host key check); `auth` is user authentication; `session` is
/// the interactive channel (or a multiplexed one over an existing master).
public enum SSHConnectStage: Int, CaseIterable, Comparable, Sendable {
    case resolve, connect, auth, session

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// Short English tag for log rows.
    public var tag: String {
        switch self {
        case .resolve: "resolve"
        case .connect: "connect"
        case .auth: "auth"
        case .session: "session"
        }
    }
}

/// Why a connection attempt failed. The UI turns these into a sentence.
public enum SSHConnectFailure: Equatable, Sendable {
    case unresolvable
    case refused
    case timedOut
    case unreachable
    /// The server's key differs from the one in known_hosts.
    case hostKeyChanged
    /// Host key could not be verified (unknown key with strict checking, …).
    case hostKeyFailed
    /// No common kex / cipher / host key algorithm.
    case negotiation
    /// The server dropped the connection (handshake or mid-auth).
    case closed
    /// Every method was tried and rejected; the server's method list.
    case permissionDenied(methods: String)
    case tooManyAuthFailures
    /// ssh exited before a session was up for a reason we don't recognise;
    /// carries its last message, if any.
    case exited(String?)
}

/// Turns `ssh -v -E <file>` output into connect-panel progress: which step is
/// in progress, a short curated log, and — on failure — the step that failed
/// and why. Feed it the log one line at a time.
///
/// Errors are only taken from lines *without* a `debugN:` prefix (ssh's
/// error/fatal messages): debug lines like `connect to address ::1 port 22:
/// Connection refused` are not fatal when ssh goes on to try the next address.
public struct SSHConnectParser: Sendable {
    public enum Status: Equatable, Sendable {
        /// This step is in progress (every earlier one is done).
        case running(SSHConnectStage)
        /// All four steps are done.
        case established
        case failed(SSHConnectStage, SSHConnectFailure)
    }

    /// One row of the panel's log.
    public struct Entry: Equatable, Sendable {
        public var stage: SSHConnectStage
        public var text: String
        public var isError: Bool

        public init(_ stage: SSHConnectStage, _ text: String, isError: Bool = false) {
            self.stage = stage
            self.text = text
            self.isError = isError
        }
    }

    public private(set) var status: Status = .running(.resolve)
    /// The auth method ssh is trying (`publickey`, `keyboard-interactive`, …).
    public private(set) var authMethod: String?
    /// This ssh is riding an existing ControlMaster connection.
    public private(set) var reusedMaster = false
    /// The last message ssh meant for the user (a non-debug line).
    public private(set) var lastMessage: String?
    /// Lines consumed so far (any kind).
    public private(set) var lineCount = 0

    private var lastMethods: String?
    private var sawHostKeyChanged = false

    public init() {}

    /// The step in progress, or the one that failed; nil once established.
    public var currentStage: SSHConnectStage? {
        switch status {
        case .running(let s), .failed(let s, _): s
        case .established: nil
        }
    }

    public var isRunning: Bool { if case .running = status { true } else { false } }

    /// Consume one log line; returns the rows it adds to the panel's log.
    public mutating func feed(_ raw: String) -> [Entry] {
        let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
        guard !line.isEmpty else { return [] }
        lineCount += 1
        guard case .running(let current) = status else { return [] }
        if let body = Self.debugBody(line) {
            return debugLine(body, current: current)
        }
        return messageLine(line, current: current)
    }

    /// ssh exited. If no session came up, that's a failure at the current step
    /// (unless a log line already said why).
    public mutating func processExited() -> Entry? {
        guard case .running(let s) = status else { return nil }
        status = .failed(s, .exited(lastMessage))
        return Entry(s, lastMessage ?? "ssh exited", isError: true)
    }

    /// The remote end produced terminal output after authentication: the
    /// session is up even if the log never said so (older ssh, odd configs).
    public mutating func sessionOutputSeen() -> Entry? {
        guard status == .running(.session) else { return nil }
        status = .established
        return Entry(.session, "interactive session")
    }

    /// Whether a log line is something ssh would have printed to the terminal
    /// without `-v` (`-E` diverts those to the log file too): not a debug
    /// line, and not one of the VERBOSE-level lines `-v` also enables.
    public static func isUserFacing(_ raw: String) -> Bool {
        let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
        guard !line.isEmpty, debugBody(line) == nil else { return false }
        return !verbosePrefixes.contains { line.hasPrefix($0) }
    }

    private static let verbosePrefixes = ["Authenticated to ", "Transferred: ", "Bytes per second"]

    // MARK: - Debug lines (progress)

    private mutating func debugLine(_ body: String, current: SSHConnectStage) -> [Entry] {
        if body.hasPrefix("auto-mux: Trying existing master") {
            reusedMaster = true
            return []
        }
        if body.hasPrefix("Control socket "), body.contains("does not exist") {
            reusedMaster = false
            return []
        }
        if body.hasPrefix("Connecting to ") {
            reusedMaster = false   // no usable master: a direct connection
            advance(to: .connect)
            return [Entry(.resolve, "destination = \(Self.destination(body))")]
        }
        if body.hasPrefix("Setting implicit ProxyCommand from ProxyJump:") {
            advance(to: .connect)
            return [Entry(.connect, "via ProxyJump")]
        }
        if body.hasPrefix("Executing proxy command:") {
            advance(to: .connect)
            return [Entry(.connect, "proxy command")]
        }
        if body == "Connection established." {
            advance(to: .connect)
            return [Entry(.connect, "tcp established")]
        }
        if let v = body.after("Remote protocol version 2.0, remote software version ") {
            advance(to: .connect)
            return [Entry(.connect, "server \(v)")]
        }
        if let alg = body.after("kex: algorithm: ") {
            return [Entry(.connect, "kex \(alg)")]
        }
        if let key = body.after("Server host key: ") {
            return [Entry(.connect, "host key \(key)")]
        }
        if body == "SSH2_MSG_NEWKEYS received" {
            advance(to: .auth)
            return [Entry(.connect, "handshake complete")]
        }
        if let methods = body.after("Authentications that can continue: ") {
            advance(to: .auth)
            guard methods != lastMethods else { return [] }
            lastMethods = methods
            return [Entry(.auth, "methods \(methods)")]
        }
        if let method = body.after("Next authentication method: ") {
            advance(to: .auth)
            authMethod = method
            return [Entry(.auth, "try \(method)")]
        }
        if let key = body.after("Offering public key: ") {
            return [Entry(.auth, "offer key \(Self.keyLabel(key))")]
        }
        if body.hasPrefix("Server accepts key:") {
            return [Entry(.auth, "key accepted")]
        }
        if let rest = body.after("Authentication succeeded (") {   // older OpenSSH
            let method = rest.hasSuffix(").") ? String(rest.dropLast(2)) : rest
            authMethod = method
            advance(to: .session)
            return [Entry(.auth, "authenticated using \(method)")]
        }
        if body == "Entering interactive session." || body.hasPrefix("pledge:")
            || body.hasPrefix("mux_client_request_session: master session id") {
            // A mux client asks for a session straight away, so this alone is
            // proof enough; a direct connection must have authenticated first.
            guard reusedMaster || current == .session else { return [] }
            status = .established
            return [Entry(.session, reusedMaster ? "multiplexed over existing connection" : "interactive session")]
        }
        return []
    }

    // MARK: - Messages (auth success, errors)

    private mutating func messageLine(_ line: String, current: SSHConnectStage) -> [Entry] {
        if !line.allSatisfy({ $0 == "@" }) { lastMessage = Self.clean(line) }
        if let rest = line.after("Authenticated to ") {
            if let r = rest.range(of: "using \"") {
                let method = rest[r.upperBound...].prefix { $0 != "\"" }
                authMethod = String(method)
            }
            advance(to: .session)
            return [Entry(.auth, "authenticated using \(authMethod ?? "?")")]
        }
        if line.hasPrefix("Warning: Permanently added") {
            return [Entry(.connect, "host key added to known_hosts")]
        }
        if line.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") {
            sawHostKeyChanged = true
            return []
        }
        guard let (stage, failure) = classify(line, current: current) else { return [] }
        status = .failed(stage, failure)
        return [Entry(stage, Self.clean(line), isError: true)]
    }

    private func classify(_ line: String, current: SSHConnectStage) -> (SSHConnectStage, SSHConnectFailure)? {
        let has = { (s: String) in line.contains(s) }
        if has("Could not resolve hostname") { return (.resolve, .unresolvable) }
        if has("Host key verification failed") {
            return (.connect, sawHostKeyChanged ? .hostKeyChanged : .hostKeyFailed)
        }
        if has("Unable to negotiate with") { return (.connect, .negotiation) }
        if has("Too many authentication failures") { return (.auth, .tooManyAuthFailures) }
        if let r = line.range(of: "Permission denied (") {
            let methods = line[r.upperBound...].prefix { $0 != ")" }
            return (.auth, .permissionDenied(methods: String(methods)))
        }
        if has("kex_exchange_identification") { return (max(current, .connect), .closed) }
        if has("Connection refused") { return (.connect, .refused) }
        if has("Operation timed out") || has("Connection timed out") { return (max(current, .connect), .timedOut) }
        if has("No route to host") || has("Network is unreachable") || has("Host is down") {
            return (.connect, .unreachable)
        }
        if has("Connection closed by") || has("Connection reset by") { return (max(current, .connect), .closed) }
        return nil
    }

    // MARK: - Helpers

    private mutating func advance(to stage: SSHConnectStage) {
        guard case .running(let s) = status, stage > s else { return }
        status = .running(stage)
    }

    /// `debug1: foo` → `foo`; nil for a line without a debug prefix.
    private static func debugBody(_ line: String) -> String? {
        guard line.hasPrefix("debug"), line.count > 7 else { return nil }
        let level = line[line.index(line.startIndex, offsetBy: 5)]
        let colon = line[line.index(line.startIndex, offsetBy: 6)]
        guard ("1"..."3").contains(level), colon == ":" else { return nil }
        return String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)
    }

    /// `Connecting to web [10.0.0.5] port 22.` → `10.0.0.5:22`;
    /// `Connecting to localhost port 2299.` → `localhost:2299`.
    private static func destination(_ body: String) -> String {
        let rest = body.dropFirst("Connecting to ".count)
        var name = rest.prefix { $0 != " " }
        if let open = rest.firstIndex(of: "["), let close = rest[open...].firstIndex(of: "]") {
            name = rest[rest.index(after: open)..<close]
        }
        guard let r = rest.range(of: " port ", options: .backwards) else { return String(name) }
        let port = rest[r.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return name.contains(":") ? "[\(name)]:\(port)" : "\(name):\(port)"
    }

    /// `/Users/me/.ssh/id_ed25519 ED25519 SHA256:… explicit` → `id_ed25519 (ED25519)`;
    /// an agent key's comment is kept as is.
    private static func keyLabel(_ s: String) -> String {
        let parts = s.split(separator: " ")
        guard let fp = parts.firstIndex(where: { $0.hasPrefix("SHA256:") || $0.hasPrefix("MD5:") }), fp > 0 else {
            return s
        }
        let type = parts[fp - 1]
        let name = parts[..<(fp - 1)].joined(separator: " ")
        let short = name.hasPrefix("/") ? (name as NSString).lastPathComponent : name
        return short.isEmpty ? String(type) : "\(short) (\(type))"
    }

    /// Drop ssh's `ssh: ` prefix from a message.
    private static func clean(_ line: String) -> String {
        line.hasPrefix("ssh: ") ? String(line.dropFirst(5)) : line
    }
}

private extension String {
    /// The rest of the string after `prefix`, if it starts with it.
    func after(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
