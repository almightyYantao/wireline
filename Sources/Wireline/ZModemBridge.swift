import AppKit
import Foundation

/// Bridges a remote `sz`/`rz` (ZMODEM) transfer to the local `lrzsz` binaries,
/// exactly the way iTerm2 does it. Wireline's terminal is a local PTY running
/// `ssh`, so the remote's ZMODEM control frames arrive as ordinary bytes in
/// `dataReceived`. When we spot a ZMODEM init header we stop feeding those bytes
/// to the terminal renderer and instead pump them through a local `rz`/`sz`
/// process, wiring its stdout back to the remote. The local tool speaks the
/// protocol; Wireline is only the wire.
///
/// - Remote `sz` (it wants to SEND) → we RECEIVE with local `rz`.
/// - Remote `rz` (it wants to RECEIVE) → we SEND with local `sz` (file picker).
///
/// Requires `lrzsz` installed locally (`brew install lrzsz`); when it's missing
/// we cancel the transfer so the remote side doesn't hang, and tell the user.
///
/// Marked `@unchecked Sendable`: state is confined to `ioQueue` (plus a small
/// lock for the `active` flag read on the terminal's hot path), and the callbacks
/// are `@Sendable`.
final class ZModemBridge: @unchecked Sendable {
    enum Direction {
        case receiveFromRemote   // remote `sz` → local `rz`
        case sendToRemote        // remote `rz` → local `sz`
    }

    enum StatusKind: Sendable { case info, success, error }

    /// Write raw bytes back to the remote (through the PTY → ssh → remote).
    private let sendToRemote: @Sendable (ArraySlice<UInt8>) -> Void
    /// Print a status line into the terminal. `(kind, 中文, English)`.
    private let status: @Sendable (StatusKind, String, String) -> Void

    /// Serializes all process state and — crucially — the writes into the local
    /// tool's stdin, keeping potentially-blocking pipe writes off the main thread.
    private let ioQueue = DispatchQueue(label: "com.wireline.zmodem")

    private let activeLock = NSLock()
    private var _active = false
    /// True while a transfer is in flight — the terminal view diverts all remote
    /// bytes to us instead of rendering them. Read on the terminal's hot path.
    var isActive: Bool { activeLock.lock(); defer { activeLock.unlock() }; return _active }
    private func setActive(_ v: Bool) { activeLock.lock(); _active = v; activeLock.unlock() }

    // Confined to ioQueue.
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var errBuf = Data()
    private var direction: Direction = .receiveFromRemote

    /// Where received files land.
    private let destDir: URL = FileManager.default
        .urls(for: .downloadsDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory() + "/Downloads")

    init(sendToRemote: @escaping @Sendable (ArraySlice<UInt8>) -> Void,
         status: @escaping @Sendable (StatusKind, String, String) -> Void) {
        self.sendToRemote = sendToRemote
        self.status = status
    }

    // MARK: - Detection

    /// Scan `slice` for a ZMODEM init header. Returns the direction and the byte
    /// offset (from `slice.startIndex`) where the header begins, or nil.
    ///
    /// A hex ZMODEM header is `* * <ZDLE=0x18> B <frametype:2 hex>`. ZRQINIT
    /// (`B00`) means the remote is the sender (`sz`) → we receive; ZRINIT
    /// (`B01`) means the remote is the receiver (`rz`) → we send.
    static func detect(in slice: ArraySlice<UInt8>) -> (Direction, Int)? {
        let prefix: [UInt8] = [0x2a, 0x2a, 0x18, 0x42, 0x30]   // "**\x18B0"
        guard slice.count >= prefix.count + 1 else { return nil }
        let base = slice.startIndex
        let last = slice.count - (prefix.count + 1)
        var off = 0
        while off <= last {
            var matched = true
            for k in 0..<prefix.count where slice[base + off + k] != prefix[k] {
                matched = false; break
            }
            if matched {
                switch slice[base + off + prefix.count] {
                case 0x30: return (.receiveFromRemote, off)   // B00 ZRQINIT
                case 0x31: return (.sendToRemote, off)        // B01 ZRINIT
                default: break
                }
            }
            off += 1
        }
        return nil
    }

    // MARK: - Lifecycle

    /// Begin a transfer. `initialBytes` are the captured header + any protocol
    /// bytes that came with it in the same chunk. Called on the main thread from
    /// the terminal's `dataReceived`.
    func begin(direction: Direction, initialBytes: [UInt8]) {
        setActive(true)   // synchronous, so subsequent chunks divert immediately
        ioQueue.async { [self] in
            self.direction = direction
            self.errBuf.removeAll()

            switch direction {
            case .receiveFromRemote:
                guard let rz = Self.toolPath("rz") else { self.failMissing(); return }
                try? FileManager.default.createDirectory(at: self.destDir, withIntermediateDirectories: true)
                self.status(.info,
                            "ZMODEM 接收中…（文件将保存到 下载 目录）",
                            "ZMODEM: receiving… (saving to Downloads)")
                // -b binary, -y overwrite existing without prompting.
                self.launch(exe: rz, args: ["-b", "-y"], initial: initialBytes)

            case .sendToRemote:
                DispatchQueue.main.async {
                    let files = Self.pickFilesToSend()
                    self.ioQueue.async {
                        guard let sz = Self.toolPath("sz") else { self.failMissing(); return }
                        guard let files, !files.isEmpty else {
                            self.cancelRemote()
                            self.status(.error, "已取消上传", "Upload cancelled")
                            self.finishState()
                            return
                        }
                        self.status(.info,
                                    "ZMODEM 发送中… \(files.count) 个文件",
                                    "ZMODEM: sending \(files.count) file(s)…")
                        // -b binary, -e escape all control chars (robust over ssh).
                        self.launch(exe: sz, args: ["-b", "-e"] + files.map(\.path), initial: initialBytes)
                    }
                }
            }
        }
    }

    /// Must run on ioQueue.
    private func launch(exe: String, args: [String], initial: [UInt8]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.currentDirectoryURL = destDir

        let sin = Pipe(), sout = Pipe(), serr = Pipe()
        p.standardInput = sin
        p.standardOutput = sout
        p.standardError = serr
        stdinHandle = sin.fileHandleForWriting

        // Protocol bytes the local tool emits → straight back to the remote.
        sout.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            self?.sendToRemote(ArraySlice(d))
        }
        // Human-readable progress/diagnostics → collected for the summary.
        serr.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty, let self else { return }
            self.ioQueue.async { [weak self] in self?.errBuf.append(d) }
        }
        p.terminationHandler = { [weak self] proc in
            guard let self else { return }
            self.ioQueue.async { [weak self] in self?.handleExit(proc) }
        }

        do {
            try p.run()
        } catch {
            status(.error, "无法启动本地 lrzsz", "Failed to launch local lrzsz")
            cancelRemote()
            finishState()
            return
        }
        process = p
        if !initial.isEmpty { try? stdinHandle?.write(contentsOf: Data(initial)) }
    }

    /// Feed a chunk of remote bytes into the running transfer. Called on the main
    /// thread; the actual (possibly blocking) pipe write is offloaded to ioQueue.
    func feedFromRemote(_ slice: ArraySlice<UInt8>) {
        let data = Data(slice)
        ioQueue.async { [weak self] in
            guard let self, let h = self.stdinHandle else { return }
            try? h.write(contentsOf: data)
        }
    }

    /// Must run on ioQueue.
    private func handleExit(_ proc: Process) {
        try? stdinHandle?.close()
        let ok = proc.terminationStatus == 0
        let names = Self.receivedFilenames(fromStderr: String(decoding: errBuf, as: UTF8.self))
        let dir = direction
        stdinHandle = nil
        process = nil
        setActive(false)

        switch dir {
        case .receiveFromRemote:
            if ok {
                let where_ = destDir.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
                status(.success,
                       "已接收 \(names.isEmpty ? "文件" : "\(names.count) 个文件") → \(where_)",
                       "Received \(names.isEmpty ? "file(s)" : "\(names.count) file(s)") → \(where_)")
                let destDir = self.destDir
                DispatchQueue.main.async {
                    Self.revealInFinder(names: names, in: destDir)
                    if !NSApp.isActive {
                        Notifier.post(title: Localizer.shared.t("下载完成", "Download complete"),
                                      body: names.first ?? destDir.lastPathComponent)
                    }
                }
            } else {
                status(.error, "接收失败或已中断", "Transfer failed or was interrupted")
            }
        case .sendToRemote:
            status(ok ? .success : .error,
                   ok ? "上传完成" : "上传失败或已中断",
                   ok ? "Upload complete" : "Upload failed or was interrupted")
        }
    }

    /// Abort the remote side with the standard ZMODEM cancel sequence
    /// (8×CAN followed by 8×BS), so a waiting `sz`/`rz` gives up instead of
    /// hanging. Must run on ioQueue (or any thread — `sendToRemote` is Sendable).
    private func cancelRemote() {
        let can = [UInt8](repeating: 0x18, count: 8) + [UInt8](repeating: 0x08, count: 8)
        sendToRemote(ArraySlice(can))
    }

    /// Must run on ioQueue.
    private func failMissing() {
        cancelRemote()
        status(.error,
               "未检测到 lrzsz —— 请先运行 brew install lrzsz",
               "lrzsz not found — run: brew install lrzsz")
        finishState()
    }

    /// Tear down an in-flight transfer without touching the remote (used when the
    /// PTY itself has gone away — a dropped link or a closed session — so the
    /// local `rz`/`sz` doesn't linger waiting on stdin that will never arrive).
    func abort() {
        guard isActive else { return }
        ioQueue.async { [weak self] in
            guard let self, let p = self.process else { self?.setActive(false); return }
            p.terminationHandler = nil
            if p.isRunning { p.terminate() }
            try? self.stdinHandle?.close()
            self.stdinHandle = nil
            self.process = nil
            self.setActive(false)
        }
    }

    /// Must run on ioQueue.
    private func finishState() {
        stdinHandle = nil
        process = nil
        setActive(false)
    }

    // MARK: - Helpers (main thread)

    @MainActor
    private static func pickFilesToSend() -> [URL]? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = Localizer.shared.t("上传", "Upload")
        panel.message = Localizer.shared.t("选择要上传到远端的文件", "Choose file(s) to send to the remote host")
        return panel.runModal() == .OK ? panel.urls : nil
    }

    @MainActor
    private static func revealInFinder(names: [String], in destDir: URL) {
        let urls = names.map { destDir.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        if urls.isEmpty {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: destDir.path)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    /// lrzsz `rz` prints `Receiving: <name>` to stderr for each file.
    static func receivedFilenames(fromStderr s: String) -> [String] {
        var names: [String] = []
        for line in s.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            guard let r = line.range(of: "Receiving: ") else { continue }
            let name = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { names.append(name) }
        }
        return names
    }

    static func toolPath(_ name: String) -> String? {
        let dirs = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin", "/bin"]
        let fm = FileManager.default
        for d in dirs {
            let p = "\(d)/\(name)"
            if fm.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }
}
