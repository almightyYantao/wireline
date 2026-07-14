import Foundation

/// Which terminal to hand an interactive session to.
public enum TerminalApp: String, Codable, Sendable, CaseIterable {
    case terminal = "Terminal"
    case iterm = "iTerm"

    public var displayName: String {
        switch self {
        case .terminal: return "Terminal.app"
        case .iterm: return "iTerm2"
        }
    }
}

/// Opens interactive SSH sessions in the user's preferred terminal by driving
/// it with AppleScript. Wireline stays true to "standard-first": it shells out
/// to the system `ssh` binary rather than embedding its own client.
public struct SSHLauncher: Sendable {
    public var sshPath: String
    public var terminal: TerminalApp

    public init(sshPath: String = "/usr/bin/ssh", terminal: TerminalApp = .terminal) {
        self.sshPath = sshPath
        self.terminal = terminal
    }

    /// The shell command line the terminal will execute.
    func commandLine(for host: Host) -> String {
        let args = SSHCommand.interactiveArguments(for: host)
        return ([sshPath] + args).map(shellQuote).joined(separator: " ")
    }

    /// AppleScript that opens a new terminal window/tab running the command.
    func appleScript(command: String) -> String {
        switch terminal {
        case .terminal:
            let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
                                 .replacingOccurrences(of: "\"", with: "\\\"")
            return """
            tell application "Terminal"
                activate
                do script "\(escaped)"
            end tell
            """
        case .iterm:
            let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
                                 .replacingOccurrences(of: "\"", with: "\\\"")
            return """
            tell application "iTerm"
                activate
                set newWindow to (create window with default profile)
                tell current session of newWindow
                    write text "\(escaped)"
                end tell
            end tell
            """
        }
    }

    /// Launch an interactive session for the host. Throws if osascript fails.
    @discardableResult
    public func launch(_ host: Host) throws -> String {
        let command = commandLine(for: host)
        let script = appleScript(command: command)
        try runOsascript(script)
        return command
    }
}

func shellQuote(_ s: String) -> String {
    if s.isEmpty { return "''" }
    let safe = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./=:@")
    if s.unicodeScalars.allSatisfy({ safe.contains($0) }) { return s }
    return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

func runOsascript(_ script: String) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", script]
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
        throw NSError(domain: "Wireline.SSHLauncher", code: Int(process.terminationStatus),
                      userInfo: [NSLocalizedDescriptionKey: "osascript exited with \(process.terminationStatus)"])
    }
}
