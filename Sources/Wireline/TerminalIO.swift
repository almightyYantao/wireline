import AppKit
import SwiftTerm
import WirelineCore

/// The engine-independent half of a terminal session: the PTY, and everything
/// that reads the raw byte stream on its way to the screen — ZMODEM, password
/// and auto-sudo answers, logging, the clean output tail for AI, the busy /
/// editor / `# …` heuristics, and the connect / disconnect edges.
///
/// The terminal engine (SwiftTerm today, libghostty next) only renders what
/// it's fed and hands back what the user types; it never owns the process.
/// That split is what lets both engines share every feature here.
@MainActor
final class TerminalIO {
    private let password: String?
    private let sudoPassword: String?
    private let autoSudo: Bool

    /// The renderer this session's output goes to.
    weak var engine: (any TerminalEngine)? {
        // The agent answers the program's queries for its sessions.
        didSet { if agent != nil { engine?.setQueryReplies(false) } }
    }

    /// The child process in its PTY: here (`PTYProcess`), or in the session
    /// agent (`AgentPTY`).
    private let process: any PTYBackend

    /// The PTY's size, settable from any thread — for an engine that
    /// `coalescesResize` and must resize the PTY in step with its grid.
    nonisolated let ptyWindowSize: PTYWindowSize

    /// The agent's handle on this session, when it lives there.
    var agent: AgentPTY? { process as? AgentPTY }

    init(password: String?, sudoPassword: String? = nil, autoSudo: Bool, backend: (any PTYBackend)? = nil) {
        self.password = password
        self.sudoPassword = sudoPassword
        self.autoSudo = autoSudo
        let process = backend ?? PTYProcess()
        self.process = process
        self.ptyWindowSize = process.windowSize
        process.onOutput = { [weak self] in self?.received($0) }
        process.onExit = { [weak self] in self?.terminated(exitCode: $0.code) }
        if let agent = process as? AgentPTY {
            agent.onSnapshotReady = { [weak self] bytes in
                guard let self else { return }
                self.engine?.restoreSnapshot(bytes)
                // An attached session is up as soon as its screen is.
                if !self.hasConnected { self.hasConnected = true; self.onConnected?() }
            }
            agent.onSnapshotHistory = { [weak self] in self?.engine?.restoreSnapshotHistory($0) }
        }
    }

    /// Attach to the agent session this IO was made for (instead of `start`).
    func attachToAgentSession() { agent?.attach() }

    /// The tab is closing: end the process — and its agent session, if any.
    func close() {
        if let agent { agent.close() } else { process.terminate() }
    }

    /// The theme the engine now draws with (the agent answers color queries).
    func themeChanged(_ theme: TerminalTheme) {
        agent?.setTheme(AgentTheme(foreground: Self.hex(theme.foreground), background: Self.hex(theme.background),
                                   cursor: Self.hex(theme.cursor)))
    }

    private static func hex(_ c: [Double]) -> String {
        func b(_ i: Int) -> Int { min(255, max(0, Int(((c.count > i ? c[i] : 0) * 255).rounded()))) }
        return String(format: "#%02x%02x%02x", b(0), b(1), b(2))
    }

    // MARK: Events

    /// Called when a command that ran for a while finishes (the shell prompt
    /// returns), with its elapsed seconds — drives the "command finished" notice.
    var onCommandFinished: ((TimeInterval) -> Void)?
    /// Busy state flips: `true` when a command starts (prompt goes away), `false`
    /// when the prompt returns (with the run's elapsed seconds). Only after the
    /// first shell prompt, so connecting / login doesn't count as a run.
    var onBusyChange: ((Bool, TimeInterval) -> Void)?
    /// Every chunk of output (a backgrounded tab flags unread output).
    var onOutput: (() -> Void)?
    /// The program rang the bell (nil) or posted a desktop notification
    /// (OSC 9 / 777 / 99; its text) — coding agents do when they wait for you.
    var onAttention: ((String?) -> Void)?
    /// The first byte from the host arrived — dialing → connected.
    var onConnected: (() -> Void)?
    /// The process exited (ssh dropped, logout, killed).
    var onDisconnected: ((Int32?) -> Void)?
    /// A vim-family editor started (`"vim"`) or exited (`nil`).
    var onEditorChange: ((String?) -> Void)?
    /// A `# …` line was submitted at the prompt — a natural-language AI request.
    var onCommentRequest: ((String) -> Void)?
    /// Called after every chunk of output has been fed to the engine, while set —
    /// used to reveal a resized terminal once the shell's redraw has finished.
    var outputObserver: (() -> Void)?

    // MARK: Process

    var isRunning: Bool { process.isRunning }
    /// The child's pid (0 when none).
    var childPID: pid_t { process.pid }

    /// Start the child in a fresh PTY sized to the engine's grid. Also after a
    /// previous child exited or was terminated (reconnect).
    func start(executable: String, args: [String], environment: [String]?,
               execName: String? = nil, currentDirectory: String? = nil) {
        // An engine that sizes the PTY itself has already set the size it wants
        // (and may update it concurrently): don't overwrite it with a read of ours.
        let ownsSize = engine?.coalescesResize == true && ptyWindowSize.current != nil
        do {
            try process.start(executable: executable, args: args,
                              environment: environment ?? Terminal.getEnvironmentVariables(termName: "xterm-256color"),
                              execName: execName, currentDirectory: currentDirectory,
                              windowSize: ownsSize ? nil : windowSize)
        } catch {
            // Couldn't exec: report it like a child that exited 127 at once.
            DispatchQueue.main.async { MainActor.assumeIsolated { self.terminated(exitCode: 127) } }
        }
    }

    /// Stop the child (SIGHUP, then SIGKILL). `onDisconnected` isn't called.
    func terminate() { process.terminate() }

    /// What owns the terminal: the child itself or a job it's running (local
    /// shells' busy polling).
    func foregroundJob() -> PTYForegroundJob { process.foregroundJob() }

    /// Bytes for the child: keystrokes and replies from the engine, answers
    /// from the heuristics here.
    func send(_ bytes: ArraySlice<UInt8>) {
        guard process.isRunning else { return }
        process.send(bytes)
    }

    func send(txt: String) { send(ArraySlice(Array(txt.utf8))) }

    /// Show text locally (notices, separators) without it reaching the child.
    func showLocally(_ text: String) { engine?.feed(ArraySlice(Array(text.utf8))) }

    /// What the PTY should be told its size is — the engine's grid.
    var windowSize: winsize {
        engine?.gridSize ?? winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
    }

    // MARK: Resize throttling

    // The *screen* reflows live on every resize, but the *PTY* learns the new
    // size at most every `settle` seconds. Each PTY resize is a SIGWINCH, and
    // shells with fancy prompts (p10k, starship) reprint the prompt on every
    // one — a fullscreen transition delivers ~30 sizes, which used to stack
    // duplicate prompts. Animated layout freezes the grid and flushes once.

    private var pendingResize: DispatchWorkItem?
    /// At most one PTY resize per this interval (Ghostty coalesces for 25 ms).
    private let settle: TimeInterval = 0.05

    /// The engine's grid changed size.
    func gridDidChange() {
        // It already told the PTY, synchronously with its reflow.
        if engine?.coalescesResize == true { engine?.didDeliverResize(); return }
        // Throttle, not debounce: while a drag keeps resizing, still deliver at
        // most every `settle` seconds so the shell keeps redrawing its prompt.
        guard pendingResize == nil else { return }
        // Reads the size at fire time: always the latest, never a stale one.
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.pendingResize = nil
                self?.deliverResize()
            }
        }
        pendingResize = work
        DispatchQueue.main.asyncAfter(deadline: .now() + settle, execute: work)
    }

    /// Send a pending throttled size to the PTY now. True if one was pending.
    @discardableResult
    func flushPendingResize() -> Bool {
        guard let work = pendingResize, !work.isCancelled else { return false }
        work.cancel()
        pendingResize = nil
        deliverResize()
        return true
    }

    private func deliverResize() {
        if process.isRunning { process.resize(windowSize) }
        engine?.didDeliverResize()
    }

    // MARK: Logging

    private var logHandle: FileHandle?

    /// Begin logging this session's (clean) output to a file under
    /// `~/Library/Logs/Wireline/`. Returns the file URL, or nil on failure.
    func startLogging(label: String) -> URL? {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Wireline", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = label.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let stamp = Self.logStampFormatter.string(from: Date())
        let url = dir.appendingPathComponent("\(String(safe))-\(stamp).log")
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else { return nil }
        // Seed with a header so a fresh log has context.
        handle.write(Data("# Wireline session log — \(label) — \(stamp)\n".utf8))
        logHandle = handle
        return url
    }

    func stopLogging() {
        try? logHandle?.close()
        logHandle = nil
    }

    private static let logStampFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmmss"; return f
    }()

    // MARK: Byte stream

    private var hasConnected = false
    private var tail = ""            // rolling tail of recent output
    private var passwordSends = 0
    private var sudoPasswordSends = 0
    private var sudoSent = false
    private var lastPasswordSend: DispatchTime?

    // Command timing, inferred from output only: a command runs from when the
    // shell prompt disappears (output starts) to when it returns.
    private var atPrompt = true
    private var leftPromptAt: DispatchTime?
    private var promptTail = ""
    /// Set once the first shell prompt appears, so the connect/login phase isn't
    /// mistaken for a running command.
    private var hasSeenFirstPrompt = false
    /// Debounced "a command is running" state — survives transient prompt redraws
    /// (async prompt segments, theme repaints) so an idle shell never flickers.
    private var busy = false
    /// Bumped on every prompt transition to invalidate a pending busy timer.
    private var busyGeneration = 0
    private var lastCommentRequest = ""

    /// A rolling, ANSI-stripped tail of recent terminal output, for AI context.
    private(set) var recentClean = ""

    /// Bridges remote `sz`/`rz` (ZMODEM) transfers to the local `lrzsz` tools.
    private lazy var zmodem = ZModemBridge(
        sendToRemote: { [weak self] bytes in
            let copy = Array(bytes)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.send(copy[...]) } }
        },
        status: { [weak self] kind, zh, en in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let color: String, icon: String
                    switch kind {
                    case .info: color = "36"; icon = "⇅"
                    case .success: color = "32"; icon = "✓"
                    case .error: color = "31"; icon = "✗"
                    }
                    let msg = Localizer.shared.t(zh, en)
                    self.showLocally("\r\n\u{1b}[\(color)m\(icon) \(msg)\u{1b}[0m\r\n")
                }
            }
        }
    )

    /// Watches for BEL and the notification OSCs, for every engine (libghostty
    /// beeps on BEL but doesn't report notifications; SwiftTerm reports neither
    /// reliably). The gate keeps the common chunk — no BEL, no ESC ] — cheap.
    private var attentionSniffer = TerminalStreamSniffer()
    private var attentionPending = false

    private func sniffAttention(_ slice: ArraySlice<UInt8>) {
        guard onAttention != nil, attentionPending || slice.contains(0x07) || slice.contains(0x1B) else { return }
        attentionPending = false
        for event in attentionSniffer.feed(slice) {
            switch event {
            case .bell: onAttention?(nil)
            case let .notification(title, body):
                let text = [title, body].filter { !$0.isEmpty }.joined(separator: ": ")
                onAttention?(text.isEmpty ? nil : text)
            default: break
            }
        }
        // A sequence split across reads must see its tail even without an ESC.
        attentionPending = attentionSniffer.isInsideSequence
    }

    /// Output from the child.
    private func received(_ slice: ArraySlice<UInt8>) {
        // ZMODEM: once a transfer is live, every remote byte belongs to the
        // protocol — divert it to the local `rz`/`sz` instead of rendering it.
        if zmodem.isActive { zmodem.feedFromRemote(slice); return }
        // Otherwise sniff for a ZMODEM init header. The gate on 0x18 (ZDLE),
        // which is virtually absent from normal output, keeps the hot path cheap.
        if slice.contains(0x18), let (dir, off) = ZModemBridge.detect(in: slice) {
            let start = slice.startIndex
            if off > 0 { engine?.feed(slice[start ..< start + off]) }
            zmodem.begin(direction: dir, initialBytes: Array(slice[(start + off)...]))
            return
        }

        engine?.feed(slice)
        outputObserver?()
        sniffAttention(slice)
        let chunk = String(decoding: slice, as: UTF8.self)
        detectFullScreenApp(chunk)
        let clean = Self.stripAnsi(chunk)
        recentClean += clean
        if recentClean.count > 20000 { recentClean = String(recentClean.suffix(20000)) }
        if let logHandle { logHandle.write(Data(clean.utf8)) }
        onOutput?()
        if !hasConnected { hasConnected = true; onConnected?() }

        // Command-finished heuristic (output only): track the prompt→output→prompt
        // cycle. Leaving the prompt = a command started; the prompt returning =
        // it finished. Only durations ≥ the threshold notify.
        promptTail += clean
        if promptTail.count > 400 { promptTail = String(promptTail.suffix(400)) }
        detectCommentRequest()
        let promptLine = promptTail.split(separator: "\n", omittingEmptySubsequences: false)
            .reversed().first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map(String.init) ?? ""
        let nowAtPrompt = isShellPrompt(promptLine)
        // Seeing any prompt means we're past the connect/login phase — even if it
        // doesn't flip the state (e.g. the first output already is a prompt).
        if nowAtPrompt { hasSeenFirstPrompt = true }
        if nowAtPrompt != atPrompt {
            atPrompt = nowAtPrompt
            busyGeneration &+= 1
            if nowAtPrompt {
                // Back at the prompt: if a command had actually started, it's done.
                if busy {
                    busy = false
                    let elapsed = leftPromptAt.map {
                        Double(DispatchTime.now().uptimeNanoseconds - $0.uptimeNanoseconds) / 1e9
                    } ?? 0
                    // The session applies the user's threshold.
                    if elapsed >= 1 { onCommandFinished?(elapsed) }
                    onBusyChange?(false, elapsed)
                }
            } else if hasSeenFirstPrompt {
                // Left the prompt — only count it as "running" if it stays that
                // way for a beat, so prompt redraws / async segments (p10k, etc.)
                // don't flicker the badge on an idle shell.
                leftPromptAt = .now()
                let gen = busyGeneration
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.busyGeneration == gen, !self.atPrompt, !self.busy else { return }
                        self.busy = true
                        self.onBusyChange?(true, 0)
                    }
                }
            }
        }

        guard password != nil || sudoPassword != nil || autoSudo else { return }

        tail += chunk
        if tail.count > 600 { tail = String(tail.suffix(600)) }
        // Examine the last couple of non-empty lines — the live prompt.
        let lines = tail.split(separator: "\n", omittingEmptySubsequences: false)
        let lastLine = lines.reversed().first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map(String.init) ?? ""

        // 1) Answer the ssh login (or key passphrase) prompt with the login
        //    password — only before auto-sudo kicks in, deduped so multiple read
        //    chunks around the same prompt don't double-send.
        if !sudoSent, let password, passwordSends < 3, isPasswordPrompt(lastLine), mayResend() {
            passwordSends += 1
            lastPasswordSend = .now()
            tail = ""
            send(txt: password + "\n")
            return
        }

        // 1b) Answer the sudo password prompt after `sudo -i`. Uses the dedicated
        //     sudo password, which is available even on key-auth hosts (where the
        //     login `password` is nil).
        if sudoSent, let sudoPassword, sudoPasswordSends < 3, isPasswordPrompt(lastLine), mayResend() {
            sudoPasswordSends += 1
            lastPasswordSend = .now()
            tail = ""
            send(txt: sudoPassword + "\n")
            return
        }

        // 2) On the first real shell prompt, kick off auto-sudo once.
        if autoSudo, !sudoSent, isShellPrompt(lastLine) {
            sudoSent = true
            tail = ""
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                MainActor.assumeIsolated { self?.send(txt: SSHCommand.autoSudoRemoteCommand() + "\n") }
            }
        }
    }

    /// The child exited — the connection is gone.
    private func terminated(exitCode: Int32?) {
        // Don't let an in-flight ZMODEM transfer's local tool hang waiting on a
        // stream that will never continue.
        zmodem.abort()
        onDisconnected?(exitCode)
    }

    /// Clear the per-connection heuristic state so a relaunched process (see
    /// `TerminalSession.reconnect`) is treated as a fresh dial. The on-screen
    /// buffer and scrollback are deliberately left untouched.
    func resetForReconnect() {
        hasConnected = false
        tail = ""
        passwordSends = 0
        sudoPasswordSends = 0
        sudoSent = false
        lastPasswordSend = nil
        atPrompt = true
        leftPromptAt = nil
        promptTail = ""
        hasSeenFirstPrompt = false
        busy = false
        busyGeneration &+= 1
        detectTail = ""
        inAltBuffer = false
        vimSniffing = false
        report(nil)
    }

    // MARK: Full-screen editor detection

    private var detectTail = ""
    private var inAltBuffer = false
    /// While in the alt screen and not yet identified, keep sniffing content for
    /// vim's on-screen signatures (see `contentLooksLikeVim`).
    private var vimSniffing = false
    private var reportedEditor: String?

    /// Detect the alternate-screen switch that full-screen TUIs (vim, less, htop…)
    /// trigger. Identify vim two ways — the echoed command that launched it, or
    /// vim's on-screen signatures once drawn — so the hint is reliable even with
    /// fancy prompts or indirect launches (`git commit`, `crontab -e`).
    private func detectFullScreenApp(_ chunk: String) {
        detectTail += chunk
        if detectTail.count > 4000 { detectTail = String(detectTail.suffix(4000)) }

        let enterTokens = ["\u{1b}[?1049h", "\u{1b}[?1047h", "\u{1b}[?47h"]
        let exitTokens  = ["\u{1b}[?1049l", "\u{1b}[?1047l", "\u{1b}[?47l"]
        func lastIndex(of tokens: [String]) -> String.Index? {
            tokens.compactMap { detectTail.range(of: $0, options: .backwards)?.lowerBound }.max()
        }
        let enterAt = lastIndex(of: enterTokens)
        let exitAt = lastIndex(of: exitTokens)

        // Current state = whichever toggle appears later in the buffer.
        let nowInAlt: Bool
        switch (enterAt, exitAt) {
        case (nil, nil): nowInAlt = inAltBuffer     // no toggle yet; keep current
        case (.some, nil): nowInAlt = true
        case (nil, .some): nowInAlt = false
        case let (.some(e), .some(x)): nowInAlt = e > x
        }

        if nowInAlt != inAltBuffer {
            inAltBuffer = nowInAlt
            if nowInAlt {
                if let e = enterAt, looksLikeVim(before: e) {
                    report("vim")
                } else {
                    vimSniffing = true          // undecided — watch the content
                }
            } else {
                vimSniffing = false
                report(nil)
            }
        } else if inAltBuffer, vimSniffing, contentLooksLikeVim(chunk) {
            report("vim")
        }
    }

    private func report(_ editor: String?) {
        if editor != nil { vimSniffing = false }
        guard editor != reportedEditor else { return }
        reportedEditor = editor
        onEditorChange?(editor)
    }

    /// vim's distinctive on-screen output: a column of `~` for empty lines, or a
    /// mode banner. `less`/`htop`/`man` don't draw these. A tilde only counts
    /// when it stands alone at the start of a row — `~/.ssh/config` in a
    /// TUI's output (Claude Code's, say) isn't vim.
    private func contentLooksLikeVim(_ chunk: String) -> Bool {
        let clean = Self.stripAnsi(chunk)
        if clean.contains("-- INSERT --") || clean.contains("-- VISUAL --") { return true }
        let rowTilde = /(?:\e\[\d+(?:;1)?H|\r?\n)~(?=\e|\r|\n|$)/.matchingSemantics(.unicodeScalar)
        return chunk.matches(of: rowTilde).count >= 3
    }

    /// Was a vim-family editor the command that just switched to the alt screen?
    /// Scans a ~300-char window right before the switch for a `vim`/`vi`/`nvim`
    /// command word — a window, not the last line, tolerates prompt redraws.
    private func looksLikeVim(before enterIndex: String.Index) -> Bool {
        let head = detectTail[..<enterIndex]
        let start = head.index(head.endIndex, offsetBy: -300, limitedBy: head.startIndex) ?? head.startIndex
        let window = Self.stripAnsi(String(head[start...]))
        let words = window.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        let editors: Set<String> = ["vim", "vi", "nvim", "view", "vimdiff", "nvimdiff"]
        return words.contains { editors.contains($0) }
    }

    /// Remove CSI / OSC escape sequences so residual escape bytes don't get
    /// mistaken for command words.
    static func stripAnsi(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "\u{1b}" {
                // Skip until the terminating byte of the escape sequence.
                var j = s.index(after: i)
                while j < s.endIndex {
                    let c = s[j]
                    if c.isLetter || c == "\u{07}" { j = s.index(after: j); break }
                    j = s.index(after: j)
                }
                i = j
            } else {
                out.append(s[i])
                i = s.index(after: i)
            }
        }
        return out
    }

    /// At least ~1.5s since the last password we sent, so we don't answer the
    /// same prompt twice as it streams in over several reads.
    private func mayResend() -> Bool {
        guard let last = lastPasswordSend else { return true }
        return DispatchTime.now().uptimeNanoseconds - last.uptimeNanoseconds > 1_500_000_000
    }

    private func isPasswordPrompt(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces).lowercased()
        guard t.hasSuffix(":") else { return false }
        return t.contains("password") || t.contains("passphrase")
    }

    private func isShellPrompt(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.hasSuffix("$") || t.hasSuffix("#") || t.hasSuffix("%") || t.hasSuffix("❯") || t.hasSuffix(">")
    }

    /// A completed `# …` request line typed at the prompt. Requires a prompt
    /// terminator (`$`/`#`/`%`/`>`/`❯`) followed by `# <text>` and a line break,
    /// so a root prompt's own trailing `#` (e.g. `root@h:~# ls`) can't be mistaken
    /// for a request — only a *second* `#` the user typed counts.
    private static let commentRequestRE = try? NSRegularExpression(
        pattern: "[#$%>\u{2771}\u{276F}][ \\t]+#[ \\t\u{3000}]+(\\S[^\\r\\n]{0,200})[\\r\\n]")

    private func detectCommentRequest() {
        guard hasSeenFirstPrompt, onCommentRequest != nil,
              let re = Self.commentRequestRE else { return }
        let ns = promptTail as NSString
        guard let m = re.matches(in: promptTail, range: NSRange(location: 0, length: ns.length)).last,
              m.numberOfRanges > 1 else { return }
        let req = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
        guard req.count >= 2, req != lastCommentRequest else { return }
        lastCommentRequest = req
        onCommentRequest?(req)
    }
}
