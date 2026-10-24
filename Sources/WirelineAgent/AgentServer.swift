import Foundation
import Darwin
import WirelineCore

/// The agent's socket server: accepts clients (same user only), routes their
/// frames to sessions, and exits once it has had neither for `idleExit`.
@MainActor
final class AgentServer {
    private let socketPath: String
    private let idleExit: TimeInterval
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clients: [AgentConnection] = []
    private var sessions: [UUID: AgentSession] = [:]
    private var idleWork: DispatchWorkItem?
    private var foregroundTimer: DispatchSourceTimer?

    init(socketPath: String, idleExit: TimeInterval) {
        self.socketPath = socketPath
        self.idleExit = idleExit
    }

    func start() throws {
        listenFD = try AgentConnection.listen(path: socketPath)
        let src = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: .main)
        src.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.acceptAll() } }
        acceptSource = src
        src.resume()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 0.8, repeating: 0.8)
        t.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.sessions.values.forEach { $0.pollForeground() } }
        }
        t.resume()
        foregroundTimer = t
        AgentLog.write("listening on \(socketPath) (pid \(getpid()))")
        considerIdle()
    }

    private func acceptAll() {
        while true {
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else { return }
            let conn = AgentConnection(fd: fd, queue: .main)
            // Same user, and signed like us (PeerIdentity): anything else
            // could type into these shells.
            guard conn.peerUID == getuid() else {
                AgentLog.write("refused a client with uid \(conn.peerUID.map(String.init) ?? "?")")
                conn.close()
                continue
            }
            if case .refused(let why) = PeerIdentity.check(fd: fd) {
                AgentLog.write("refused a client: \(why)")
                conn.close()
                continue
            }
            conn.onFrame = { [weak self, weak conn] frame in
                MainActor.assumeIsolated {
                    guard let self, let conn else { return }
                    self.handle(frame, from: conn)
                }
            }
            conn.onClose = { [weak self, weak conn] in
                MainActor.assumeIsolated {
                    guard let self, let conn else { return }
                    self.dropped(conn)
                }
            }
            clients.append(conn)
            conn.start()
            considerIdle()
        }
    }

    private func dropped(_ conn: AgentConnection) {
        clients.removeAll { $0 === conn }
        for s in sessions.values { s.detach(conn) }
        considerIdle()
    }

    private func handle(_ frame: AgentFrame, from conn: AgentConnection) {
        switch frame {
        case .control(let c): control(c, from: conn)
        case let .input(id, bytes): sessions[id]?.input(bytes)
        case .output, .snapshotReady, .snapshotHistory: conn.close()   // agent → client only
        }
    }

    private func control(_ c: AgentControl, from conn: AgentConnection) {
        switch c {
        case .hello(let proto, let client):
            guard proto == AgentProtocol.version else {
                conn.send(.control(.failure(id: nil, message: "protocol \(proto) unsupported (agent speaks \(AgentProtocol.version))")))
                conn.close()
                return
            }
            AgentLog.write("client: \(client)")
            conn.send(.control(.welcome(proto: AgentProtocol.version, agentVersion: AgentInfo.version,
                                        snapshotFormat: AgentInfo.snapshotFormat)))
        case .list:
            conn.send(.control(.sessions(sessions.values.map(\.info).sorted { $0.id.uuidString < $1.id.uuidString })))
        case let .spawn(id, spec, keepAlive):
            guard sessions[id] == nil else { return fail(conn, id, "session exists") }
            guard let s = AgentSession(id: id, spec: spec, keepAlive: keepAlive) else {
                return fail(conn, id, "couldn't create a terminal")
            }
            s.onRelease = { [weak self] s in self?.release(s) }
            s.adopt(conn)
            do { try s.start() } catch { return fail(conn, id, "couldn't start \(spec.executable): \(error)") }
            sessions[id] = s
            conn.send(.control(.spawned(id: id, pid: s.pid)))
            considerIdle()
        case let .respawn(id, spec):
            guard let s = sessions[id] else { return fail(conn, id, "no such session") }
            do { try s.respawn(spec) } catch { return fail(conn, id, "couldn't restart: \(error)") }
            conn.send(.control(.spawned(id: id, pid: s.pid)))
        case let .attach(id, cols, rows, cw, ch):
            guard let s = sessions[id] else { return fail(conn, id, "no such session") }
            s.attach(conn, cols: cols, rows: rows, cellWidth: cw, cellHeight: ch)
        case .detach(let id):
            sessions[id]?.detach(conn)
        case let .resize(id, cols, rows, cw, ch):
            sessions[id]?.resize(cols: cols, rows: rows, cellWidth: cw, cellHeight: ch)
        case let .theme(id, theme):
            sessions[id]?.setTheme(theme)
        case let .keepAlive(id, seconds):
            sessions[id]?.keepAlive = seconds
        case .hangup(let id):
            sessions[id]?.hangup()
        case .close(let id):
            sessions[id]?.close()
        case .welcome, .sessions, .spawned, .foreground, .exited, .failure:
            conn.close()                                                // agent → client only
        }
    }

    private func fail(_ conn: AgentConnection, _ id: UUID?, _ message: String) {
        AgentLog.write("\(id.map { "\($0) " } ?? "")\(message)")
        conn.send(.control(.failure(id: id, message: message)))
    }

    private func release(_ s: AgentSession) {
        sessions[s.id] = nil
        considerIdle()
    }

    /// No sessions and no clients for `idleExit`: nothing to keep alive.
    private func considerIdle() {
        idleWork?.cancel(); idleWork = nil
        guard sessions.isEmpty, clients.isEmpty else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.sessions.isEmpty, self.clients.isEmpty else { return }
                AgentLog.write("idle, exiting")
                unlink(self.socketPath)
                exit(0)
            }
        }
        idleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + idleExit, execute: work)
    }
}

enum AgentInfo {
    static let version = "0.1"
    /// libghostty-vt's snapshot format (snapshot.h envelope).
    static let snapshotFormat: UInt16 = 1
}

/// `~/Library/Logs/Wireline/agent.log`, or stderr with `--foreground`.
enum AgentLog {
    nonisolated(unsafe) static var toStderr = false
    nonisolated(unsafe) private static var handle: FileHandle?

    static func write(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        if toStderr { FileHandle.standardError.write(Data(line.utf8)); return }
        if handle == nil {
            let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Logs/Wireline", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("agent.log")
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
            handle = try? FileHandle(forWritingTo: url)
            _ = try? handle?.seekToEnd()
        }
        handle?.write(Data(line.utf8))
    }
}
