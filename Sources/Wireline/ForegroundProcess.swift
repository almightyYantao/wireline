import Darwin
import Foundation

/// Names the program in a PTY's foreground: `claude`, `node`, `python`, … —
/// what the pane icon should show.
///
/// `proc_name` alone isn't enough: Claude Code installs as
/// `…/claude/versions/2.1.306` (the process is named after its version),
/// npm-installed CLIs run as `node …/bin/codex`, and Python reports
/// `python3.10`. So look at the executable path and, for interpreters, the
/// script they run.
enum ForegroundProcess {
    static func identify(_ pid: pid_t) -> String? {
        var nameBuf = [CChar](repeating: 0, count: 64)
        let name = proc_name(pid, &nameBuf, UInt32(nameBuf.count)) > 0 ? String(cString: nameBuf) : nil
        var pathBuf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let path = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count)) > 0 ? String(cString: pathBuf) : nil

        // An interpreter running a named tool: name the tool.
        let exe = normalize(path.map { ($0 as NSString).lastPathComponent } ?? name ?? "")
        if interpreters.contains(exe), let script = scriptName(pid) { return script }

        if let path, let fromPath = nameFromPath(path) { return fromPath }
        return name.map(normalize)
    }

    private static let interpreters: Set<String> = ["node", "bun", "deno", "python", "ruby", "perl"]

    /// `python3.10` → `python`, `Python` → `python`, `node22` → `node`.
    static func normalize(_ raw: String) -> String {
        var s = raw.lowercased()
        while let last = s.last, last.isNumber || last == "." { s.removeLast() }
        return s.isEmpty ? raw.lowercased() : s
    }

    /// The executable's name, skipping version-number components
    /// (`…/claude/versions/2.1.306` → `claude`).
    static func nameFromPath(_ path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        for part in parts.reversed() {
            let isVersion = part.allSatisfy { $0.isNumber || $0 == "." }
            if isVersion || ["versions", "bin", "libexec", "current"].contains(part) { continue }
            return normalize(part)
        }
        return nil
    }

    /// The first non-option argument of an interpreter — its script's name
    /// (`node /opt/homebrew/bin/codex` → `codex`; `python -m http.server` → `http`).
    private static func scriptName(_ pid: pid_t) -> String? {
        let args = arguments(pid)
        guard args.count > 1 else { return nil }
        var i = 1
        while i < args.count {
            let a = args[i]
            if a == "-m", i + 1 < args.count {
                return normalize(String(args[i + 1].split(separator: ".").first ?? ""))
            }
            if a.hasPrefix("-") { i += 1; continue }
            var base = (a as NSString).lastPathComponent
            for ext in [".js", ".mjs", ".cjs", ".ts", ".py", ".rb"] where base.hasSuffix(ext) {
                base.removeLast(ext.count)
            }
            // `node …/cli.js` of a package: name the package directory instead.
            if ["cli", "index", "main"].contains(base) {
                let dir = ((a as NSString).deletingLastPathComponent as NSString).lastPathComponent
                return nameFromPath(dir)
            }
            return normalize(base)
        }
        return nil
    }

    /// argv of `pid` via sysctl KERN_PROCARGS2.
    private static func arguments(_ pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return [] }
        let argc = buf.withUnsafeBytes { Int($0.load(as: Int32.self)) }
        var i = 4
        while i < size, buf[i] != 0 { i += 1 }        // executable path
        while i < size, buf[i] == 0 { i += 1 }        // padding
        var args: [String] = []
        while args.count < argc, i < size {
            let start = i
            while i < size, buf[i] != 0 { i += 1 }
            args.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }
}
