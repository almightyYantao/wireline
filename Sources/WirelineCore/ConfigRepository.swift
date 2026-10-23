import Foundation

/// Reads and writes the on-disk OpenSSH config, keeping it as the source of truth.
///
/// Writes are atomic and take a timestamped `.wireline-bak` copy first, so a
/// crash mid-write can never corrupt a user's real ssh config.
public final class ConfigRepository: @unchecked Sendable {
    public let url: URL
    private let fm = FileManager.default

    /// Defaults to `~/.ssh/config`.
    public init(url: URL? = nil) {
        if let url {
            self.url = url
        } else {
            self.url = fm.homeDirectoryForCurrentUser
                .appendingPathComponent(".ssh", isDirectory: true)
                .appendingPathComponent("config", isDirectory: false)
        }
    }

    public func load() throws -> SSHConfig.Document {
        guard fm.fileExists(atPath: url.path) else {
            return SSHConfig.Document(items: [])
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        return SSHConfig.parse(text)
    }

    /// Convenience: load just the managed hosts.
    public func loadHosts() throws -> [Host] {
        try load().hosts
    }

    public func save(_ document: SSHConfig.Document) throws {
        let dir = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        }
        if fm.fileExists(atPath: url.path) {
            let backup = url.appendingPathExtension("wireline-bak")
            try? fm.removeItem(at: backup)
            try? fm.copyItem(at: url, to: backup)
        }
        let text = SSHConfig.serialize(document)
        try text.write(to: url, atomically: true, encoding: .utf8)
        // ssh refuses a group/world-writable config; enforce 0600.
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

extension SSHConfig.Document {
    /// This document with its managed hosts replaced by `hosts`: unmanaged
    /// blocks stay where they are, surviving hosts keep their position,
    /// hosts no longer present are dropped, new ones are appended.
    public func replacingHosts(with hosts: [Host]) -> SSHConfig.Document {
        var remaining = hosts
        var items: [SSHConfig.Item] = []
        for item in self.items {
            switch item {
            case .raw(let text):
                items.append(.raw(text))
            case .host(let old):
                if let idx = remaining.firstIndex(where: { $0.alias == old.alias }) {
                    items.append(.host(remaining.remove(at: idx)))
                }
            }
        }
        for leftover in remaining { items.append(.host(leftover)) }
        return SSHConfig.Document(items: items)
    }
}

/// Where RDP hosts live: `~/.ssh/wireline-rdp-hosts`, in ssh_config syntax so
/// the same parser, backups and 0600 handling apply — but it is *not* an ssh
/// config. Nothing includes it, so `ssh <alias>`, shell completion, VS Code
/// Remote and friends never see a Windows machine as an SSH host. Each block
/// still carries `# wireline: protocol=rdp`, so a block pasted into
/// `~/.ssh/config` by hand is recognised (and moved here on the next save).
public enum RDPHostsFile {
    public static let header = """
    # Wireline — Remote Desktop (RDP) hosts.
    # Same syntax as ~/.ssh/config so Wireline can share its parser, but this is
    # NOT an ssh config: don't `Include` it from ~/.ssh/config, or ssh would
    # treat these Windows machines as SSH hosts. Passwords are in the Keychain.
    """

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh", isDirectory: true)
            .appendingPathComponent("wireline-rdp-hosts", isDirectory: false)
    }

    /// Hosts read from the RDP file are RDP whatever their metadata says.
    public static func normalize(_ doc: SSHConfig.Document) -> SSHConfig.Document {
        SSHConfig.Document(items: doc.items.map { item in
            guard case .host(var h) = item else { return item }
            h.hostProtocol = .rdp
            return .host(h)
        })
    }

    /// The document to write for `hosts` (all RDP), starting from what's on disk.
    public static func document(for hosts: [Host], from existing: SSHConfig.Document) -> SSHConfig.Document {
        let base = existing.items.isEmpty ? SSHConfig.Document(items: [.raw(header + "\n")]) : existing
        return base.replacingHosts(with: hosts)
    }
}
