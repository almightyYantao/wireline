import Foundation

/// Builds `ssh` invocations from a `Host`. Because the host lives in
/// `~/.ssh/config`, most connections are just `ssh <alias>` — the config
/// supplies HostName/User/Port/IdentityFile. Extra flags are only added for
/// one-off overrides or non-interactive batch runs.
public enum SSHCommand {

    /// Arguments (excluding the leading `ssh`) for an interactive session.
    ///
    /// `accept-new` auto-trusts a first-seen host key (but still refuses a
    /// *changed* key), so connecting to a new host goes straight to the password
    /// prompt instead of stopping on an interactive yes/no question — which also
    /// lets the built-in terminal auto-fill the stored password reliably.
    public static func interactiveArguments(for host: Host) -> [String] {
        ["-o", "StrictHostKeyChecking=accept-new"] + host.launchArgTokens + [host.alias]
    }

    /// Arguments for running a single non-interactive command on a host.
    /// `BatchNonInteractive` disables password prompts so a batch run never
    /// hangs waiting on stdin; hosts needing a password should pipe it in.
    public static func runArguments(for host: Host, command: String,
                                    connectTimeout: Int = 10) -> [String] {
        var args = [
            "-o", "ConnectTimeout=\(connectTimeout)",
            "-o", "StrictHostKeyChecking=accept-new"
        ]
        args.append(host.alias)
        args.append(command)
        return args
    }

    /// Arguments for a tunnel: `-L` / `-R` / `-D` per `forward.kind`. `-N` means
    /// "don't run a remote command", so this is a pure tunnel;
    /// `ExitOnForwardFailure` makes a port that can't be bound fail the tunnel
    /// (and show the error) instead of leaving a live ssh that forwards nothing.
    public static func forwardArguments(for host: Host, forward: PortForward) -> [String] {
        var bindSpec = ""
        if let bind = forward.bindAddress, !bind.isEmpty { bindSpec = "\(bind):" }
        let flag: String, spec: String
        switch forward.kind {
        case .local:
            flag = "-L"
            spec = "\(bindSpec)\(forward.localPort):\(forward.remoteHost):\(forward.remotePort)"
        case .remote:
            // The server listens on remotePort; connections come back to
            // remoteHost:localPort as seen from this Mac.
            flag = "-R"
            spec = "\(bindSpec)\(forward.remotePort):\(forward.remoteHost):\(forward.localPort)"
        case .dynamic:
            flag = "-D"
            spec = "\(bindSpec)\(forward.localPort)"
        }
        return ["-N", "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=30",
                flag, spec, host.alias]
    }

    /// The command Wireline sends after login when a host is marked auto-sudo.
    /// Password reuse happens by feeding the stored secret to `sudo -S`.
    public static func autoSudoRemoteCommand() -> String {
        "sudo -i"
    }
}

/// A port-forwarding rule, configured in the UI and mapped to `ssh -L` / `-R`
/// / `-D`. Persisted as JSON alongside app state (not in ssh config, since it
/// is session-scoped runtime state rather than host identity).
public struct PortForward: Identifiable, Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// `-L`: a local port reaches remoteHost:remotePort from the server.
        case local
        /// `-R`: the server's remotePort reaches remoteHost:localPort from this Mac.
        case remote
        /// `-D`: a SOCKS5 proxy on localPort that exits from the server.
        case dynamic
    }

    public var id: UUID
    public var kind: Kind
    /// Host alias this tunnel runs over (may itself be a jump host).
    public var hostAlias: String
    public var localPort: Int
    /// `-L`: the target as seen from the server. `-R`: the target as seen from
    /// this Mac. Unused for `-D`.
    public var remoteHost: String
    public var remotePort: Int
    /// Listening address (local for `-L` / `-D`, the server's for `-R`), e.g.
    /// `127.0.0.1`. Nil leaves it to ssh's default (loopback).
    public var bindAddress: String?
    public var label: String?
    /// Start this tunnel when Wireline launches.
    public var autoStart: Bool

    public init(id: UUID = UUID(), kind: Kind = .local, hostAlias: String, localPort: Int,
                remoteHost: String, remotePort: Int,
                bindAddress: String? = "127.0.0.1", label: String? = nil, autoStart: Bool = false) {
        self.id = id
        self.kind = kind
        self.hostAlias = hostAlias
        self.localPort = localPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.bindAddress = bindAddress
        self.label = label
        self.autoStart = autoStart
    }

    // `kind` / `autoStart` are newer than the saved format: default them.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .local
        hostAlias = try c.decode(String.self, forKey: .hostAlias)
        localPort = try c.decode(Int.self, forKey: .localPort)
        remoteHost = try c.decodeIfPresent(String.self, forKey: .remoteHost) ?? "127.0.0.1"
        remotePort = try c.decodeIfPresent(Int.self, forKey: .remotePort) ?? 0
        bindAddress = try c.decodeIfPresent(String.self, forKey: .bindAddress)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        autoStart = try c.decodeIfPresent(Bool.self, forKey: .autoStart) ?? false
    }

    /// One line describing where traffic goes, e.g. `127.0.0.1:5432 → db:5432`.
    public var summary: String {
        let bind = bindAddress.flatMap { $0.isEmpty ? nil : $0 } ?? "127.0.0.1"
        switch kind {
        case .local:   return "\(bind):\(localPort) → \(remoteHost):\(remotePort)"
        case .remote:  return "\(hostAlias):\(remotePort) → \(remoteHost):\(localPort)"
        case .dynamic: return "SOCKS5 \(bind):\(localPort)"
        }
    }
}
