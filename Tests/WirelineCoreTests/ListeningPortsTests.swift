import XCTest
@testable import WirelineCore

final class ListeningPortsTests: XCTestCase {
    func testSS() {
        let out = """
        LISTEN 0      4096   127.0.0.53%lo:53         0.0.0.0:*
        LISTEN 0      511          0.0.0.0:80         0.0.0.0:*    users:(("nginx",pid=812,fd=6))
        LISTEN 0      511             [::]:80            [::]:*    users:(("nginx",pid=812,fd=7))
        LISTEN 0      128                *:22               *:*
        LISTEN 0      4096           [::1]:5432          [::]:*
        """
        let ports = ListeningPorts.parse(out)
        XCTAssertEqual(ports.map(\.port), [22, 53, 80, 5432])
        let http = ports.first { $0.port == 80 }!
        XCTAssertEqual(http.addresses, ["0.0.0.0", "::"])
        XCTAssertEqual(http.process, "nginx")
        XCTAssertEqual(http.forwardTarget, "127.0.0.1")
        XCTAssertEqual(ports.first { $0.port == 53 }?.addresses, ["127.0.0.53"])
        XCTAssertEqual(ports.first { $0.port == 5432 }?.forwardTarget, "localhost")
    }

    func testNetstat() {
        let out = """
        Active Internet connections (only servers)
        Proto Recv-Q Send-Q Local Address           Foreign Address         State       PID/Program name
        tcp        0      0 0.0.0.0:22              0.0.0.0:*               LISTEN      901/sshd
        tcp        0      0 10.0.0.5:8080           0.0.0.0:*               LISTEN      -
        tcp6       0      0 :::3000                 :::*                    LISTEN      1200/node
        """
        let ports = ListeningPorts.parse(out)
        XCTAssertEqual(ports.map(\.port), [22, 3000, 8080])
        XCTAssertEqual(ports[0].process, "sshd")
        XCTAssertEqual(ports[1].addresses, ["::"])
        XCTAssertEqual(ports[1].process, "node")
        XCTAssertEqual(ports[2].process, nil)
        XCTAssertEqual(ports[2].forwardTarget, "10.0.0.5")
    }

    func testLsof() {
        let out = """
        COMMAND   PID USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        redis-ser 500 me    6u  IPv4 0x1      0t0  TCP 127.0.0.1:6379 (LISTEN)
        ControlCe 600 me    9u  IPv6 0x2      0t0  TCP *:7000 (LISTEN)
        """
        let ports = ListeningPorts.parse(out)
        XCTAssertEqual(ports.map(\.port), [6379, 7000])
        XCTAssertEqual(ports[0].process, "redis-ser")
        XCTAssertEqual(ports[1].addresses, ["*"])
    }

    func testBSDNetstat() {
        let out = """
        tcp4       0      0  127.0.0.1.631          *.*                    LISTEN
        tcp46      0      0  *.22                   *.*                    LISTEN
        tcp4       0      0  192.168.0.139.61198    203.208.49.130.443     ESTABLISHED
        """
        XCTAssertEqual(ListeningPorts.parse(out).map(\.port), [22, 631])
    }
}
