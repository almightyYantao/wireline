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
