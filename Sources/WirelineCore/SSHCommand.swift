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
        ["-o", "StrictHostKeyChecking=accept-new", host.alias]
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

    /// Arguments for a local port forward: `-L [bind:]localPort:remoteHost:remotePort`.
    /// `-N` means "don't run a remote command", so this is a pure tunnel.
    public static func forwardArguments(for host: Host, forward: PortForward) -> [String] {
        var bindSpec = ""
        if let bind = forward.bindAddress, !bind.isEmpty { bindSpec = "\(bind):" }
        let spec = "\(bindSpec)\(forward.localPort):\(forward.remoteHost):\(forward.remotePort)"
        return ["-N", "-L", spec, host.alias]
    }

    /// The command Wireline sends after login when a host is marked auto-sudo.
    /// Password reuse happens by feeding the stored secret to `sudo -S`.
    public static func autoSudoRemoteCommand() -> String {
        "sudo -i"
    }
}

/// A local→remote port-forwarding rule, configured in the UI and mapped to
/// `ssh -L`. Persisted as JSON alongside app state (not in ssh config, since it
/// is session-scoped runtime state rather than host identity).
public struct PortForward: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    /// Host alias this tunnel runs over (may itself be a jump host).
    public var hostAlias: String
    public var localPort: Int
    public var remoteHost: String
    public var remotePort: Int
    /// Local bind address, e.g. `127.0.0.1`. Nil binds to loopback by default.
    public var bindAddress: String?
    public var label: String?

    public init(id: UUID = UUID(), hostAlias: String, localPort: Int,
                remoteHost: String, remotePort: Int,
                bindAddress: String? = "127.0.0.1", label: String? = nil) {
        self.id = id
        self.hostAlias = hostAlias
        self.localPort = localPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.bindAddress = bindAddress
        self.label = label
    }
}
