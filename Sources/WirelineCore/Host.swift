import Foundation

/// How a host authenticates.
public enum AuthMethod: String, Codable, Sendable, CaseIterable {
    /// Public-key authentication (an `IdentityFile` is present).
    case key
    /// Password authentication (the password lives in the macOS Keychain).
    case password
    /// Not yet decided / inherited from ssh defaults.
    case unknown
}

/// A single SSH host, backed 1:1 by a `Host` block in `~/.ssh/config`.
///
/// The fields that map to real OpenSSH keywords (`HostName`, `User`, `Port`,
/// `IdentityFile`, `ProxyJump`) round-trip verbatim. Wireline-specific metadata
/// (group, description, auth method, auto-sudo) is persisted as a comment line
/// inside the same block so the stock `ssh` client ignores it.
public struct Host: Identifiable, Codable, Sendable, Equatable {
    /// The `Host` alias — this is the identity users type to connect.
    public var alias: String

    // Standard OpenSSH keywords ---------------------------------------------
    public var hostname: String?
    public var user: String?
    public var port: Int?
    public var identityFile: String?
    /// `ProxyJump` — the bastion/jump host used to reach this host.
    public var proxyJump: String?
    /// Any other keyword/value pairs we don't model explicitly, preserved as-is.
    public var extraOptions: [(keyword: String, value: String)]

    // Wireline metadata (persisted as a comment) ----------------------------
    public var group: String?
    public var descriptionText: String?
    public var authMethod: AuthMethod
    /// Run `sudo -i` automatically after login, reusing the stored password.
    public var autoSudo: Bool
    /// Extra `ssh` command-line arguments prepended before the alias, e.g.
    /// `-o HostKeyAlgorithms=+ssh-rsa`. Some legacy hosts need these to connect.
    public var launchArgs: String?

    public var id: String { alias }

    public init(
        alias: String,
        hostname: String? = nil,
        user: String? = nil,
        port: Int? = nil,
        identityFile: String? = nil,
        proxyJump: String? = nil,
        extraOptions: [(keyword: String, value: String)] = [],
        group: String? = nil,
        descriptionText: String? = nil,
        authMethod: AuthMethod = .unknown,
        autoSudo: Bool = false,
        launchArgs: String? = nil
    ) {
        self.alias = alias
        self.hostname = hostname
        self.user = user
        self.port = port
        self.identityFile = identityFile
        self.proxyJump = proxyJump
        self.extraOptions = extraOptions
        self.group = group
        self.descriptionText = descriptionText
        self.authMethod = authMethod
        self.autoSudo = autoSudo
        self.launchArgs = launchArgs
    }

    /// `launchArgs` split into individual command-line tokens.
    public var launchArgTokens: [String] {
        (launchArgs ?? "").split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    }

    /// Effective port, defaulting to the SSH standard 22.
    public var effectivePort: Int { port ?? 22 }

    /// The host we should actually open a TCP socket to for a reachability check.
    public var connectHostname: String { hostname ?? alias }

    /// Infer the auth method when it wasn't explicitly set: an identity file
    /// implies key auth, otherwise password.
    public var resolvedAuthMethod: AuthMethod {
        if authMethod != .unknown { return authMethod }
        return (identityFile?.isEmpty == false) ? .key : .password
    }

    // Codable: tuples aren't Codable, so flatten extraOptions. --------------
    private enum CodingKeys: String, CodingKey {
        case alias, hostname, user, port, identityFile, proxyJump
        case extraOptions, group, descriptionText, authMethod, autoSudo, launchArgs
    }

    private struct Option: Codable { var keyword: String; var value: String }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        alias = try c.decode(String.self, forKey: .alias)
        hostname = try c.decodeIfPresent(String.self, forKey: .hostname)
        user = try c.decodeIfPresent(String.self, forKey: .user)
        port = try c.decodeIfPresent(Int.self, forKey: .port)
        identityFile = try c.decodeIfPresent(String.self, forKey: .identityFile)
        proxyJump = try c.decodeIfPresent(String.self, forKey: .proxyJump)
        let opts = try c.decodeIfPresent([Option].self, forKey: .extraOptions) ?? []
        extraOptions = opts.map { ($0.keyword, $0.value) }
        group = try c.decodeIfPresent(String.self, forKey: .group)
        descriptionText = try c.decodeIfPresent(String.self, forKey: .descriptionText)
        authMethod = try c.decodeIfPresent(AuthMethod.self, forKey: .authMethod) ?? .unknown
        autoSudo = try c.decodeIfPresent(Bool.self, forKey: .autoSudo) ?? false
        launchArgs = try c.decodeIfPresent(String.self, forKey: .launchArgs)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(alias, forKey: .alias)
        try c.encodeIfPresent(hostname, forKey: .hostname)
        try c.encodeIfPresent(user, forKey: .user)
        try c.encodeIfPresent(port, forKey: .port)
        try c.encodeIfPresent(identityFile, forKey: .identityFile)
        try c.encodeIfPresent(proxyJump, forKey: .proxyJump)
        try c.encode(extraOptions.map { Option(keyword: $0.keyword, value: $0.value) },
                     forKey: .extraOptions)
        try c.encodeIfPresent(group, forKey: .group)
        try c.encodeIfPresent(descriptionText, forKey: .descriptionText)
        try c.encode(authMethod, forKey: .authMethod)
        try c.encode(autoSudo, forKey: .autoSudo)
        try c.encodeIfPresent(launchArgs, forKey: .launchArgs)
    }

    public static func == (lhs: Host, rhs: Host) -> Bool {
        lhs.alias == rhs.alias &&
        lhs.hostname == rhs.hostname &&
        lhs.user == rhs.user &&
        lhs.port == rhs.port &&
        lhs.identityFile == rhs.identityFile &&
        lhs.proxyJump == rhs.proxyJump &&
        lhs.group == rhs.group &&
        lhs.descriptionText == rhs.descriptionText &&
        lhs.authMethod == rhs.authMethod &&
        lhs.autoSudo == rhs.autoSudo &&
        lhs.launchArgs == rhs.launchArgs &&
        lhs.extraOptions.map(\.keyword) == rhs.extraOptions.map(\.keyword) &&
        lhs.extraOptions.map(\.value) == rhs.extraOptions.map(\.value)
    }
}
