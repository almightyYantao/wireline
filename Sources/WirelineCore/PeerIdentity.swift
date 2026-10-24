import Foundation
import Security

/// Who is on the other end of a session-agent socket. The agent holds shells
/// (some of them `sudo -i`) and gets spawn requests carrying passwords, so
/// "same user" isn't enough on either side: any process of the user could
/// otherwise type into a root shell, or pose as the agent and collect
/// passwords. Both ends require the peer to be signed like themselves:
///
/// - with a Team ID (Developer ID builds): the same Team ID;
/// - ad hoc (local builds): a validly signed executable in the same
///   directory (`Wireline.app/Contents/MacOS/`, or `.build/debug/`).
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
        let tokenData = withUnsafeBytes(of: &token) { Data($0) }
        var peer: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: tokenData] as CFDictionary, [], &peer) == errSecSuccess,
              let peer else { return .refused("can't identify the peer") }
        let validity = SecCodeCheckValidity(peer, [], nil)
        guard validity == errSecSuccess else { return .refused("peer's signature is invalid (\(validity))") }
        guard let peerStatic = staticCode(of: peer), let selfStatic = selfStaticCode() else {
            return .refused("can't read signatures")
        }
        if let team = teamID(selfStatic) {
            let peerTeam = teamID(peerStatic)
            return peerTeam == team ? .trusted : .refused("peer's team \(peerTeam ?? "none") isn't \(team)")
        }
        guard let peerPath = path(of: peerStatic), let selfPath = path(of: selfStatic) else {
            return .refused("can't locate the peer")
        }
        let peerDir = (peerPath as NSString).deletingLastPathComponent
        let selfDir = (selfPath as NSString).deletingLastPathComponent
        return peerDir == selfDir ? .trusted : .refused("peer \(peerPath) isn't beside \(selfPath)")
    }

    private static func staticCode(of code: SecCode) -> SecStaticCode? {
        var s: SecStaticCode?
        return SecCodeCopyStaticCode(code, [], &s) == errSecSuccess ? s : nil
    }

    private static func selfStaticCode() -> SecStaticCode? {
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return nil }
        return staticCode(of: me)
    }

    private static func teamID(_ code: SecStaticCode) -> String? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private static func path(of code: SecStaticCode) -> String? {
        var url: CFURL?
        guard SecCodeCopyPath(code, [], &url) == errSecSuccess, let url else { return nil }
        return (url as URL).resolvingSymlinksInPath().path
    }
}
