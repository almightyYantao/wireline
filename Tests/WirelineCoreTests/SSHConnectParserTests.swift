import XCTest
@testable import WirelineCore

/// Real `ssh -v -E <file>` logs from OpenSSH_10.3p1 (macOS), captured against
/// a throwaway local sshd and unreachable / closed addresses. Home paths are
/// anonymised and the user's own key lines dropped; everything else is verbatim.
final class SSHConnectParserTests: XCTestCase {
    private func run(_ log: String, exit: Bool = false) -> (SSHConnectParser, [SSHConnectParser.Entry]) {
        var p = SSHConnectParser()
        var rows = log.split(separator: "\n", omittingEmptySubsequences: false).flatMap { p.feed(String($0)) }
        if exit, let r = p.processExited() { rows.append(r) }
        return (p, rows)
    }

    func testSuccessWithNewControlMaster() {
        let (p, rows) = run(Fixtures.success)
        XCTAssertEqual(p.status, .established)
        XCTAssertFalse(p.reusedMaster)
        XCTAssertEqual(p.authMethod, "publickey")
        XCTAssertTrue(rows.contains(.init(.connect, "host key added to known_hosts")))
        XCTAssertEqual(rows.first, .init(.resolve, "destination = 127.0.0.1:2299"))
        XCTAssertTrue(rows.contains(.init(.connect, "tcp established")))
        XCTAssertTrue(rows.contains(.init(.connect, "kex mlkem768x25519-sha256")))
        XCTAssertTrue(rows.contains(.init(.auth, "offer key clientkey (ED25519)")))
        XCTAssertTrue(rows.contains(.init(.auth, "authenticated using publickey")))
        XCTAssertEqual(rows.last, .init(.session, "interactive session"))
        XCTAssertEqual(rows.map(\.stage), rows.map(\.stage).sorted(), "rows arrive in step order")
        XCTAssertFalse(rows.contains { $0.isError })
    }

    func testStepsAdvanceInOrder() {
        var p = SSHConnectParser()
        var seen: [SSHConnectStage] = [.resolve]
        for line in Fixtures.success.split(separator: "\n") {
            _ = p.feed(String(line))
            if let s = p.currentStage, s != seen.last { seen.append(s) }
        }
        XCTAssertEqual(seen, [.resolve, .connect, .auth, .session])
    }

    func testReusedControlMasterIsInstant() {
        let (p, rows) = run(Fixtures.mux)
        XCTAssertEqual(p.status, .established)
        XCTAssertTrue(p.reusedMaster)
        XCTAssertEqual(rows, [.init(.session, "multiplexed over existing connection")])
    }

    func testHostnameWithoutBracketedAddress() {
        let (p, rows) = run(Fixtures.fallback)
        XCTAssertEqual(p.status, .established)
        XCTAssertEqual(rows.first, .init(.resolve, "destination = localhost:2299"))
    }

    func testConnectionRefused() {
        let (p, rows) = run(Fixtures.refused, exit: true)
        XCTAssertEqual(p.status, .failed(.connect, .refused))
        XCTAssertEqual(rows.last, .init(.connect, "connect to host 127.0.0.1 port 1: Connection refused", isError: true))
        XCTAssertEqual(rows.filter(\.isError).count, 1, "exit after a known error adds nothing")
    }

    func testTimeout() {
        let (p, _) = run(Fixtures.timedOut, exit: true)
        XCTAssertEqual(p.status, .failed(.connect, .timedOut))
    }

    func testUnresolvable() {
        let (p, rows) = run(Fixtures.unresolvable, exit: true)
        XCTAssertEqual(p.status, .failed(.resolve, .unresolvable))
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows[0].text.hasPrefix("Could not resolve hostname nonexistent-host.invalid"))
    }

    func testPermissionDenied() {
        let (p, rows) = run(Fixtures.denied, exit: true)
        XCTAssertEqual(p.status, .failed(.auth, .permissionDenied(methods: "publickey,password,keyboard-interactive")))
        XCTAssertTrue(rows.contains(.init(.auth, "methods publickey,password,keyboard-interactive")))
    }

    func testHostKeyChanged() {
        let (p, rows) = run(Fixtures.hostKey, exit: true)
        XCTAssertEqual(p.status, .failed(.connect, .hostKeyChanged))
        XCTAssertEqual(rows.last, .init(.connect, "Host key verification failed.", isError: true))
    }

    /// A debug-level refusal is one address of several; only ssh's own error
    /// line is fatal.
    func testDebugRefusalIsNotFatal() {
        var p = SSHConnectParser()
        _ = p.feed("debug1: Connecting to localhost [::1] port 22.")
        _ = p.feed("debug1: connect to address ::1 port 22: Connection refused")
        XCTAssertEqual(p.status, .running(.connect))
        _ = p.feed("debug1: Connection established.")
        XCTAssertEqual(p.status, .running(.connect))
    }

    func testExitWithoutKnownErrorFailsAtCurrentStep() {
        var p = SSHConnectParser()
        _ = p.feed("debug1: Connecting to h [10.0.0.1] port 22.")
        _ = p.feed("debug1: Connection established.")
        _ = p.feed("Something odd happened")
        XCTAssertEqual(p.processExited(), .init(.connect, "Something odd happened", isError: true))
        XCTAssertEqual(p.status, .failed(.connect, .exited("Something odd happened")))
    }

    func testOtherFailures() {
        func fail(_ lines: [String]) -> SSHConnectParser.Status {
            var p = SSHConnectParser()
            lines.forEach { _ = p.feed($0) }
            return p.status
        }
        XCTAssertEqual(fail(["debug1: Connecting to h [10.0.0.1] port 22.",
                             "kex_exchange_identification: read: Connection reset by peer"]),
                       .failed(.connect, .closed))
        XCTAssertEqual(fail(["debug1: Connecting to h [10.0.0.1] port 22.",
                             "ssh: connect to host h port 22: No route to host"]),
                       .failed(.connect, .unreachable))
        XCTAssertEqual(fail(["debug1: Authentications that can continue: publickey",
                             "Received disconnect from 10.0.0.1 port 22:2: Too many authentication failures"]),
                       .failed(.auth, .tooManyAuthFailures))
        XCTAssertEqual(fail(["debug1: Authentications that can continue: publickey,password",
                             "Connection closed by 10.0.0.1 port 22"]),
                       .failed(.auth, .closed))
        XCTAssertEqual(fail(["Unable to negotiate with 10.0.0.1 port 22: no matching host key type found."]),
                       .failed(.connect, .negotiation))
    }

    func testOutputAfterAuthCompletesSession() {
        var p = SSHConnectParser()
        XCTAssertNil(p.sessionOutputSeen())
        _ = p.feed(#"Authenticated to h ([10.0.0.1]:22) using "keyboard-interactive"."#)
        XCTAssertEqual(p.authMethod, "keyboard-interactive")
        XCTAssertEqual(p.sessionOutputSeen(), .init(.session, "interactive session"))
        XCTAssertEqual(p.status, .established)
    }

    func testUserFacingLines() {
        XCTAssertTrue(SSHConnectParser.isUserFacing("ssh: connect to host h port 22: Connection refused"))
        XCTAssertTrue(SSHConnectParser.isUserFacing("Warning: Permanently added 'h' (ED25519) to the list of known hosts."))
        XCTAssertFalse(SSHConnectParser.isUserFacing("debug1: Connection established."))
        XCTAssertFalse(SSHConnectParser.isUserFacing(#"Authenticated to h ([10.0.0.1]:22) using "publickey"."#))
        XCTAssertFalse(SSHConnectParser.isUserFacing(""))
    }
}

private enum Fixtures {
    static let success = #"""
debug1: OpenSSH_10.3p1, LibreSSL 3.3.6
debug1: Reading configuration data /dev/null
debug1: Authenticator provider $SSH_SK_PROVIDER did not resolve; disabling
debug1: auto-mux: Trying existing master at '/tmp/wlssh/cm.sock'
debug1: Control socket "/tmp/wlssh/cm.sock" does not exist
debug1: Connecting to 127.0.0.1 [127.0.0.1] port 2299.
debug1: Connection established.
debug1: loaded pubkey from /tmp/wlssh/clientkey: ED25519 SHA256:QCAMyaK0pij2CnSDIi9Ng58R522AikBrXZ2h+zOtVP0
debug1: identity file /tmp/wlssh/clientkey type 2
debug1: no identity pubkey loaded from /tmp/wlssh/clientkey
debug1: Local version string SSH-2.0-OpenSSH_10.3
debug1: Remote protocol version 2.0, remote software version OpenSSH_10.3
debug1: compat_banner: match: OpenSSH_10.3 pat OpenSSH* compat 0x04000000
debug1: Authenticating to 127.0.0.1:2299 as 'admin'
debug1: load_hostkeys: fopen /tmp/wlssh/kh2: No such file or directory
debug1: load_hostkeys: fopen /etc/ssh/ssh_known_hosts: No such file or directory
debug1: load_hostkeys: fopen /etc/ssh/ssh_known_hosts2: No such file or directory
debug1: SSH2_MSG_KEXINIT sent
debug1: SSH2_MSG_KEXINIT received
debug1: kex: algorithm: mlkem768x25519-sha256
debug1: kex: host key algorithm: ssh-ed25519
debug1: kex: server->client cipher: chacha20-poly1305@openssh.com MAC: <implicit> compression: none
debug1: kex: client->server cipher: chacha20-poly1305@openssh.com MAC: <implicit> compression: none
debug1: expecting SSH2_MSG_KEX_ECDH_REPLY
debug1: SSH2_MSG_KEX_ECDH_REPLY received
debug1: Server host key: ssh-ed25519 SHA256:Sr9d/6dKEgXZTTY3I75/npMaEUfOMg/KWXxYI09+Rcc
debug1: load_hostkeys: fopen /tmp/wlssh/kh2: No such file or directory
debug1: load_hostkeys: fopen /etc/ssh/ssh_known_hosts: No such file or directory
debug1: load_hostkeys: fopen /etc/ssh/ssh_known_hosts2: No such file or directory
debug1: checking without port identifier
debug1: load_hostkeys: fopen /tmp/wlssh/kh2: No such file or directory
debug1: load_hostkeys: fopen /etc/ssh/ssh_known_hosts: No such file or directory
debug1: load_hostkeys: fopen /etc/ssh/ssh_known_hosts2: No such file or directory
Warning: Permanently added '[127.0.0.1]:2299' (ED25519) to the list of known hosts.
debug1: ssh_packet_send2_wrapped: resetting send seqnr 3
debug1: rekey out after 134217728 blocks
debug1: SSH2_MSG_NEWKEYS sent
debug1: Sending SSH2_MSG_EXT_INFO
debug1: expecting SSH2_MSG_NEWKEYS
debug1: ssh_packet_read_poll2: resetting read seqnr 3
debug1: SSH2_MSG_NEWKEYS received
debug1: rekey in after 134217728 blocks
debug1: SSH2_MSG_EXT_INFO received
debug1: kex_ext_info_check_ver: publickey-hostbound@openssh.com=<0>
debug1: kex_ext_info_check_ver: ping@openssh.com=<0>
debug1: kex_ext_info_check_ver: agent-forward=<0>
debug1: SSH2_MSG_SERVICE_ACCEPT received
debug1: SSH2_MSG_EXT_INFO received
debug1: Authentications that can continue: publickey
debug1: Next authentication method: publickey
debug1: Will attempt key: /tmp/wlssh/clientkey ED25519 SHA256:QCAMyaK0pij2CnSDIi9Ng58R522AikBrXZ2h+zOtVP0 explicit
debug1: Offering public key: /tmp/wlssh/clientkey ED25519 SHA256:QCAMyaK0pij2CnSDIi9Ng58R522AikBrXZ2h+zOtVP0 explicit
debug1: Server accepts key: /tmp/wlssh/clientkey ED25519 SHA256:QCAMyaK0pij2CnSDIi9Ng58R522AikBrXZ2h+zOtVP0 explicit
Authenticated to 127.0.0.1 ([127.0.0.1]:2299) using "publickey".
debug1: setting up multiplex master socket
debug1: channel 0: new mux listener [/tmp/wlssh/cm.sock] (inactive timeout: 0)
debug1: control_persist_detach: backgrounding master process
debug1: forking to background
debug1: Entering interactive session.
debug1: pledge: id
debug1: multiplexing control connection
debug1: channel 1: new mux-control [mux-control] (inactive timeout: 0)
debug1: Received 'info' extension
debug1: channel 2: new session [client-session] (inactive timeout: 0)
debug1: client_input_global_request: rtype hostkeys-00@openssh.com want_reply 0
debug1: Remote: /tmp/wlssh/authkeys:1: key options: agent-forwarding port-forwarding pty user-rc x11-forwarding
debug1: Remote: /tmp/wlssh/authkeys:1: key options: agent-forwarding port-forwarding pty user-rc x11-forwarding
debug1: Sending command: echo hi; exit
debug1: mux_client_request_session: master session id: 2
debug1: client_input_channel_req: channel 2 rtype exit-status reply 0
debug1: client_input_channel_req: channel 2 rtype eow@openssh.com reply 0
debug1: channel 2: free: client-session, nchannels 3
debug1: channel 1: free: mux-control, nchannels 2
debug1: multiplexing control connection
debug1: channel 1: new mux-control [mux-control] (inactive timeout: 0)
debug1: channel 2: new session [client-session] (inactive timeout: 0)
debug1: Sending command: echo hi2; exit
debug1: client_input_channel_req: channel 2 rtype exit-status reply 0
debug1: client_input_channel_req: channel 2 rtype eow@openssh.com reply 0
debug1: channel 2: free: client-session, nchannels 3
debug1: channel 1: free: mux-control, nchannels 2
debug1: ControlPersist timeout expired
debug1: channel 0: free: /tmp/wlssh/cm.sock, nchannels 1
Transferred: sent 4400, received 3860 bytes, in 4.7 seconds
Bytes per second: sent 931.3, received 817.0
debug1: Exit status -1
"""#

    static let mux = #"""
debug1: OpenSSH_10.3p1, LibreSSL 3.3.6
debug1: Reading configuration data /dev/null
debug1: Authenticator provider $SSH_SK_PROVIDER did not resolve; disabling
debug1: auto-mux: Trying existing master at '/tmp/wlssh/cm.sock'
debug1: Received 'info' extension
debug1: mux_client_request_session: master session id: 2
"""#

    static let fallback = #"""
debug1: OpenSSH_10.3p1, LibreSSL 3.3.6
debug1: Reading configuration data /dev/null
debug1: Authenticator provider $SSH_SK_PROVIDER did not resolve; disabling
debug1: Connecting to localhost port 2299.
debug1: Connection established.
debug1: loaded pubkey from /tmp/wlssh/clientkey: ED25519 SHA256:QCAMyaK0pij2CnSDIi9Ng58R522AikBrXZ2h+zOtVP0
debug1: identity file /tmp/wlssh/clientkey type 2
debug1: no identity pubkey loaded from /tmp/wlssh/clientkey
debug1: Local version string SSH-2.0-OpenSSH_10.3
debug1: Remote protocol version 2.0, remote software version OpenSSH_10.3
debug1: compat_banner: match: OpenSSH_10.3 pat OpenSSH* compat 0x04000000
debug1: Authenticating to localhost:2299 as 'admin'
debug1: load_hostkeys: fopen /etc/ssh/ssh_known_hosts: No such file or directory
debug1: load_hostkeys: fopen /etc/ssh/ssh_known_hosts2: No such file or directory
debug1: SSH2_MSG_KEXINIT sent
debug1: SSH2_MSG_KEXINIT received
debug1: kex: algorithm: mlkem768x25519-sha256
debug1: kex: host key algorithm: ssh-ed25519
debug1: kex: server->client cipher: chacha20-poly1305@openssh.com MAC: <implicit> compression: none
debug1: kex: client->server cipher: chacha20-poly1305@openssh.com MAC: <implicit> compression: none
debug1: expecting SSH2_MSG_KEX_ECDH_REPLY
debug1: SSH2_MSG_KEX_ECDH_REPLY received
debug1: Server host key: ssh-ed25519 SHA256:Sr9d/6dKEgXZTTY3I75/npMaEUfOMg/KWXxYI09+Rcc
debug1: load_hostkeys: fopen /etc/ssh/ssh_known_hosts: No such file or directory
debug1: load_hostkeys: fopen /etc/ssh/ssh_known_hosts2: No such file or directory
debug1: checking without port identifier
debug1: load_hostkeys: fopen /etc/ssh/ssh_known_hosts: No such file or directory
debug1: load_hostkeys: fopen /etc/ssh/ssh_known_hosts2: No such file or directory
Warning: Permanently added '[localhost]:2299' (ED25519) to the list of known hosts.
debug1: ssh_packet_send2_wrapped: resetting send seqnr 3
debug1: rekey out after 134217728 blocks
debug1: SSH2_MSG_NEWKEYS sent
debug1: Sending SSH2_MSG_EXT_INFO
debug1: expecting SSH2_MSG_NEWKEYS
debug1: ssh_packet_read_poll2: resetting read seqnr 3
debug1: SSH2_MSG_NEWKEYS received
debug1: rekey in after 134217728 blocks
debug1: SSH2_MSG_EXT_INFO received
debug1: kex_ext_info_check_ver: publickey-hostbound@openssh.com=<0>
debug1: kex_ext_info_check_ver: ping@openssh.com=<0>
debug1: kex_ext_info_check_ver: agent-forward=<0>
debug1: SSH2_MSG_SERVICE_ACCEPT received
debug1: SSH2_MSG_EXT_INFO received
debug1: Authentications that can continue: publickey
debug1: Next authentication method: publickey
debug1: Will attempt key: /tmp/wlssh/clientkey ED25519 SHA256:QCAMyaK0pij2CnSDIi9Ng58R522AikBrXZ2h+zOtVP0 explicit
debug1: Offering public key: /tmp/wlssh/clientkey ED25519 SHA256:QCAMyaK0pij2CnSDIi9Ng58R522AikBrXZ2h+zOtVP0 explicit
debug1: Server accepts key: /tmp/wlssh/clientkey ED25519 SHA256:QCAMyaK0pij2CnSDIi9Ng58R522AikBrXZ2h+zOtVP0 explicit
Authenticated to localhost ([127.0.0.1]:2299) using "publickey".
debug1: channel 0: new session [client-session] (inactive timeout: 0)
debug1: Requesting no-more-sessions@openssh.com
debug1: Entering interactive session.
debug1: pledge: network
debug1: client_input_global_request: rtype hostkeys-00@openssh.com want_reply 0
debug1: Remote: /tmp/wlssh/authkeys:1: key options: agent-forwarding port-forwarding pty user-rc x11-forwarding
debug1: Remote: /tmp/wlssh/authkeys:1: key options: agent-forwarding port-forwarding pty user-rc x11-forwarding
debug1: Sending command: exit
debug1: pledge: fork
debug1: client_input_channel_req: channel 0 rtype exit-status reply 0
debug1: client_input_channel_req: channel 0 rtype eow@openssh.com reply 0
debug1: channel 0: free: client-session, nchannels 1
Transferred: sent 3992, received 3576 bytes, in 0.0 seconds
Bytes per second: sent 285428.3, received 255684.3
debug1: Exit status 0
"""#

    static let refused = #"""
debug1: OpenSSH_10.3p1, LibreSSL 3.3.6
debug1: Reading configuration data /dev/null
debug1: Authenticator provider $SSH_SK_PROVIDER did not resolve; disabling
debug1: Connecting to 127.0.0.1 [127.0.0.1] port 1.
debug1: connect to address 127.0.0.1 port 1: Connection refused
ssh: connect to host 127.0.0.1 port 1: Connection refused
"""#

    static let timedOut = #"""
debug1: OpenSSH_10.3p1, LibreSSL 3.3.6
debug1: Reading configuration data /dev/null
debug1: Authenticator provider $SSH_SK_PROVIDER did not resolve; disabling
debug1: Connecting to 10.255.255.1 [10.255.255.1] port 22.
debug1: connect to address 10.255.255.1 port 22: Operation timed out
ssh: connect to host 10.255.255.1 port 22: Operation timed out
"""#

    static let unresolvable = #"""
debug1: OpenSSH_10.3p1, LibreSSL 3.3.6
debug1: Reading configuration data /dev/null
debug1: Authenticator provider $SSH_SK_PROVIDER did not resolve; disabling
ssh: Could not resolve hostname nonexistent-host.invalid: nodename nor servname provided, or not known
"""#

    static let denied = #"""
debug1: OpenSSH_10.3p1, LibreSSL 3.3.6
debug1: Reading configuration data /dev/null
debug1: Authenticator provider $SSH_SK_PROVIDER did not resolve; disabling
debug1: Connecting to 127.0.0.1 [127.0.0.1] port 22.
debug1: fd 4 clearing O_NONBLOCK
debug1: Connection established.
debug1: Local version string SSH-2.0-OpenSSH_10.3
debug1: Remote protocol version 2.0, remote software version OpenSSH_10.3
debug1: compat_banner: match: OpenSSH_10.3 pat OpenSSH* compat 0x04000000
debug1: Authenticating to 127.0.0.1:22 as 'wl-nobody-test'
debug1: load_hostkeys: fopen /etc/ssh/ssh_known_hosts: No such file or directory
debug1: load_hostkeys: fopen /etc/ssh/ssh_known_hosts2: No such file or directory
debug1: SSH2_MSG_KEXINIT sent
debug1: SSH2_MSG_KEXINIT received
debug1: kex: algorithm: mlkem768x25519-sha256
debug1: kex: host key algorithm: ssh-ed25519
debug1: kex: server->client cipher: chacha20-poly1305@openssh.com MAC: <implicit> compression: none
debug1: kex: client->server cipher: chacha20-poly1305@openssh.com MAC: <implicit> compression: none
debug1: expecting SSH2_MSG_KEX_ECDH_REPLY
debug1: SSH2_MSG_KEX_ECDH_REPLY received
debug1: Server host key: ssh-ed25519 SHA256:ZmDyvp4139BMS5uPX3tLvzHSMm0OzhUlob1rGIzXN78
debug1: load_hostkeys: fopen /etc/ssh/ssh_known_hosts: No such file or directory
debug1: load_hostkeys: fopen /etc/ssh/ssh_known_hosts2: No such file or directory
debug1: Host '127.0.0.1' is known and matches the ED25519 host key.
debug1: Found key in /tmp/wlssh/kh:1
debug1: ssh_packet_send2_wrapped: resetting send seqnr 3
debug1: rekey out after 134217728 blocks
debug1: SSH2_MSG_NEWKEYS sent
debug1: Sending SSH2_MSG_EXT_INFO
debug1: expecting SSH2_MSG_NEWKEYS
debug1: ssh_packet_read_poll2: resetting read seqnr 3
debug1: SSH2_MSG_NEWKEYS received
debug1: rekey in after 134217728 blocks
debug1: SSH2_MSG_EXT_INFO received
debug1: kex_ext_info_check_ver: publickey-hostbound@openssh.com=<0>
debug1: kex_ext_info_check_ver: ping@openssh.com=<0>
debug1: kex_ext_info_check_ver: agent-forward=<0>
debug1: SSH2_MSG_SERVICE_ACCEPT received
debug1: SSH2_MSG_EXT_INFO received
debug1: Authentications that can continue: publickey,password,keyboard-interactive
debug1: No more authentication methods to try.
wl-nobody-test@127.0.0.1: Permission denied (publickey,password,keyboard-interactive).
"""#

    static let hostKey = #"""
debug1: OpenSSH_10.3p1, LibreSSL 3.3.6
debug1: Reading configuration data /dev/null
debug1: Authenticator provider $SSH_SK_PROVIDER did not resolve; disabling
debug1: Connecting to 127.0.0.1 [127.0.0.1] port 22.
debug1: fd 4 clearing O_NONBLOCK
debug1: Connection established.
debug1: Local version string SSH-2.0-OpenSSH_10.3
debug1: Remote protocol version 2.0, remote software version OpenSSH_10.3
debug1: compat_banner: match: OpenSSH_10.3 pat OpenSSH* compat 0x04000000
debug1: Authenticating to 127.0.0.1:22 as 'wl-nobody-test'
debug1: load_hostkeys: fopen /etc/ssh/ssh_known_hosts: No such file or directory
debug1: load_hostkeys: fopen /etc/ssh/ssh_known_hosts2: No such file or directory
debug1: SSH2_MSG_KEXINIT sent
debug1: SSH2_MSG_KEXINIT received
debug1: kex: algorithm: mlkem768x25519-sha256
debug1: kex: host key algorithm: ssh-ed25519
debug1: kex: server->client cipher: chacha20-poly1305@openssh.com MAC: <implicit> compression: none
debug1: kex: client->server cipher: chacha20-poly1305@openssh.com MAC: <implicit> compression: none
debug1: expecting SSH2_MSG_KEX_ECDH_REPLY
debug1: SSH2_MSG_KEX_ECDH_REPLY received
debug1: Server host key: ssh-ed25519 SHA256:ZmDyvp4139BMS5uPX3tLvzHSMm0OzhUlob1rGIzXN78
debug1: load_hostkeys: fopen /etc/ssh/ssh_known_hosts: No such file or directory
debug1: load_hostkeys: fopen /etc/ssh/ssh_known_hosts2: No such file or directory
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
IT IS POSSIBLE THAT SOMEONE IS DOING SOMETHING NASTY!
Someone could be eavesdropping on you right now (man-in-the-middle attack)!
It is also possible that a host key has just been changed.
The fingerprint for the ED25519 key sent by the remote host is
SHA256:ZmDyvp4139BMS5uPX3tLvzHSMm0OzhUlob1rGIzXN78.
Please contact your system administrator.
Add correct host key in /tmp/wlssh/badkh to get rid of this message.
Offending ED25519 key in /tmp/wlssh/badkh:1
Host key for 127.0.0.1 has changed and you have requested strict checking.
Host key verification failed.
"""#
}
