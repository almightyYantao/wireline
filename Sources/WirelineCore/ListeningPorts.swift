import Foundation

/// A TCP port a host is listening on, as found by `ListeningPorts.command`.
public struct ListeningPort: Identifiable, Sendable, Equatable {
    public var port: Int
    /// Every address it's bound on (`127.0.0.1`, `0.0.0.0`, `::` …).
    public var addresses: [String]
    /// The owning program, when the listing shows it (root, or your own process).
    public var process: String?
    public var id: Int { port }

    public init(port: Int, addresses: [String], process: String? = nil) {
        self.port = port; self.addresses = addresses; self.process = process
    }

    /// Where a `-L` tunnel should point, as seen from the host: the loopback
    /// when it listens there or on every interface, else its one address.
    public var forwardTarget: String {
        if addresses.contains(where: { $0.hasPrefix("127.") || $0 == "0.0.0.0" || $0 == "*" }) { return "127.0.0.1" }
        if addresses.contains(where: { $0 == "::" || $0 == "::1" }) { return "localhost" }   // IPv6-only
        return addresses.first ?? "127.0.0.1"
    }
}

/// Discover a host's listening TCP ports (VS Code's "Ports" view) from one
/// non-interactive command that works across Linux distros and macOS.
public enum ListeningPorts {
    /// `ss` (modern Linux), else `lsof` on macOS (its `netstat -ltn` "works" but
    /// lists every connection, without programs), else `netstat` (older / BusyBox).
    public static let command =
        "ss -ltnpH 2>/dev/null"
        + " || { [ \"$(uname)\" = Darwin ] && lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null; }"
        + " || netstat -ltnp 2>/dev/null || netstat -ltn 2>/dev/null"

    /// Parse any of those outputs, one entry per port (sorted).
    public static func parse(_ output: String) -> [ListeningPort] {
        var byPort: [Int: ListeningPort] = [:]
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            guard line.contains("LISTEN") else { continue }
            let cols = line.split(whereSeparator: \.isWhitespace).map(String.init)
            let local: String, process: String?
            if cols.first == "LISTEN", cols.count >= 4 {
                // ss: State Recv-Q Send-Q Local Peer [users:(("nginx",pid=1,fd=6))]
                local = cols[3]
                process = line.range(of: "users:((\"").flatMap { r in
                    line[r.upperBound...].split(separator: "\"").first.map(String.init)
                }
            } else if cols.first?.hasPrefix("tcp") == true, cols.count >= 4 {
                // netstat: Proto Recv-Q Send-Q Local Foreign State [PID/Program]
                local = cols[3]
                process = cols.count >= 7 && cols[6].contains("/")
                    ? cols[6].split(separator: "/", maxSplits: 1).last.map(String.init) : nil
            } else if let i = cols.firstIndex(of: "(LISTEN)"), i > 0, cols.count > 1 {
                // lsof: COMMAND PID USER FD TYPE DEVICE SIZE NODE NAME (LISTEN)
                local = cols[i - 1]
                process = cols[0]
            } else {
                continue
            }
            guard let (address, port) = split(local) else { continue }
            var entry = byPort[port] ?? ListeningPort(port: port, addresses: [], process: nil)
            if !entry.addresses.contains(address) { entry.addresses.append(address) }
            if entry.process == nil { entry.process = process }
            byPort[port] = entry
        }
        return byPort.values.sorted { $0.port < $1.port }
    }

    /// `127.0.0.53%lo:53`, `[::]:22`, `*:80`, `:::8080` → address and port
    /// (and BSD netstat's `127.0.0.1.631` / `*.22`).
    static func split(_ local: String) -> (String, Int)? {
        guard let colon = local.lastIndex(of: ":") ?? local.lastIndex(of: "."),
              let port = Int(local[local.index(after: colon)...]), port > 0 else { return nil }
        var address = String(local[..<colon])
        if address.hasPrefix("["), address.hasSuffix("]") { address = String(address.dropFirst().dropLast()) }
        if let pct = address.firstIndex(of: "%") { address = String(address[..<pct]) }   // interface scope
        if address.isEmpty || address == "::" || address == ":" { address = "::" }
        return (address, port)
    }
}

/// Local TCP ports, for picking where a discovered remote port lands.
public enum LocalPorts {
    /// Whether nothing is listening on `port` on the loopback right now.
    public static func isFree(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(truncatingIfNeeded: port)).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        return ok
    }

    /// `preferred` when it's free and unprivileged, else the next free one above it.
    public static func firstFree(preferring preferred: Int, taken: Set<Int> = []) -> Int {
        var p = preferred < 1024 ? preferred + 10000 : preferred
        while p < 65535 {
            if !taken.contains(p), isFree(p) { return p }
            p += 1
        }
        return preferred
    }
}
