import Foundation
import Darwin

/// Who is on the other end of a session-agent socket. The agent holds shells
/// (some of them `sudo -i`) and gets spawn requests carrying passwords, so
/// "same user" isn't enough on either side: any process of the user could
/// otherwise type into a root shell, or pose as the agent and collect
/// passwords. Both ends require the peer to be signed like themselves:
///
/// - with a Team ID (Developer ID builds): the same Team ID;
/// - ad hoc (local builds): an executable in the same directory
///   (`Wireline.app/Contents/MacOS/`, or `.build/debug/`).
///
/// The identity is the kernel's (`csops`): the signature it validated when
/// the process started, which it keeps enforcing page by page (`CS_VALID`).
/// Not the file on disk — an update replaces that under a running agent,
/// and a disk check would then refuse the agent holding the sessions.
///
/// Debug builds accept anyone with `WIRELINE_AGENT_TRUST_ANY=1` (tests run
/// under xctest, signed by Apple); release builds have no such switch.
public enum PeerIdentity {
    public enum Verdict: Equatable, Sendable {
        case trusted
        case refused(String)
    }

    public static func check(fd: Int32) -> Verdict {
        #if DEBUG
        if ProcessInfo.processInfo.environment["WIRELINE_AGENT_TRUST_ANY"] == "1" { return .trusted }
        #endif
        var token = audit_token_t()
        var len = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &len) == 0 else {
            return .refused("no peer token (errno \(errno))")
        }
        let pid = pid_t(bitPattern: token.val.5)
        // The token pins this exact process: a reused pid doesn't match it.
        guard let flags = codeSignStatus(pid, &token), flags & csValid != 0 else {
            return .refused("peer \(pid)'s code signature isn't valid")
        }
        if let team = teamID(getpid(), nil) {
            let peerTeam = teamID(pid, &token)
            return peerTeam == team ? .trusted : .refused("peer's team \(peerTeam ?? "none") isn't \(team)")
        }
        guard let peerPath = path(pid), let selfPath = path(getpid()) else {
            return .refused("can't locate the peer")
        }
        // Still the same process after reading its path.
        guard codeSignStatus(pid, &token) != nil else { return .refused("peer went away") }
        let peerDir = (peerPath as NSString).deletingLastPathComponent
        let selfDir = (selfPath as NSString).deletingLastPathComponent
        return peerDir == selfDir ? .trusted : .refused("peer \(peerPath) isn't beside \(selfPath)")
    }

    // <sys/codesign.h> (not in the SDK's public headers, stable since 10.x).
    private static let csValid: UInt32 = 0x1
    private static let csOpsStatus: UInt32 = 0
    private static let csOpsTeamID: UInt32 = 14

    private static func codeSignStatus(_ pid: pid_t, _ token: UnsafeMutablePointer<audit_token_t>?) -> UInt32? {
        var flags: UInt32 = 0
        return csops(pid, csOpsStatus, &flags, 4, token) == 0 ? flags : nil
    }

    /// The Team ID the kernel holds for the process; nil when ad hoc.
    private static func teamID(_ pid: pid_t, _ token: UnsafeMutablePointer<audit_token_t>?) -> String? {
        var buf = [UInt8](repeating: 0, count: 128)
        guard csops(pid, csOpsTeamID, &buf, buf.count, token) == 0 else { return nil }
        // A blob: u32 magic, u32 length (big-endian), then the string.
        let id = String(decoding: buf.dropFirst(8).prefix { $0 != 0 }, as: UTF8.self)
        return id.isEmpty ? nil : id
    }

    private static func csops(_ pid: pid_t, _ op: UInt32, _ buf: UnsafeMutableRawPointer, _ size: Int,
                              _ token: UnsafeMutablePointer<audit_token_t>?) -> Int32 {
        token.map { wl_csops_audittoken(pid, op, buf, size, $0) } ?? wl_csops(pid, op, buf, size)
    }

    private static func path(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        let p = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return URL(fileURLWithPath: p).resolvingSymlinksInPath().path
    }
}

@_silgen_name("csops")
private func wl_csops(_ pid: pid_t, _ ops: UInt32, _ useraddr: UnsafeMutableRawPointer?, _ usersize: Int) -> Int32

@_silgen_name("csops_audittoken")
private func wl_csops_audittoken(_ pid: pid_t, _ ops: UInt32, _ useraddr: UnsafeMutableRawPointer?,
                                 _ usersize: Int, _ token: UnsafeMutablePointer<audit_token_t>) -> Int32
