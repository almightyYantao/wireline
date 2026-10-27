import AppKit
import SwiftUI
import WirelineCore

/// Smart completion for local shells: follows the typed line from the bytes
/// sent to the PTY and shows a small list near the cursor. Only while the
/// shell itself owns the terminal — never inside vim, an AI CLI or any job.
/// SSH panes only once the remote shell's OSC 133 marks say it's at its own
/// prompt (`RemotePromptGate`), with history / paths over SFTP.
@MainActor
final class CompletionController {
    static var enabled: Bool { UserDefaults.standard.object(forKey: "smartCompletion") as? Bool ?? true }

    private weak var session: TerminalSession?
    private var tracker = CompletionLineTracker()
    private var items: [Completion] = []
    private var selected = 0
    private var generation = 0
    private var panel: NSPanel?
    private var monitor: Any?
    /// Typed with `send` by an accept — tracked, but must not reopen the list.
    private var accepting = false

    init(session: TerminalSession) { self.session = session }

    // MARK: Events from the session

    /// SSH: whether the remote shell is at its own prompt (OSC 133 marks).
    private var remoteGate = RemotePromptGate()

    func promptReady() { remoteGate.commandFinished(); tracker.promptReady(); hide() }
    func commandStarted() { remoteGate.commandStarted(); tracker.invalidate(); hide() }
    func disconnected() { remoteGate.reset(); tracker.invalidate(); hide() }

    /// Bytes going to the PTY (keys, pastes, our own inserts).
    func input(_ bytes: ArraySlice<UInt8>) {
        guard let session else { return }
        switch session.kind {
        case .localShell:
            // A job (vim, claude, ssh…) owns the terminal: its input isn't a shell line.
            guard session.io.foregroundJob() == .child else { tracker.invalidate(); hide(); return }
            for line in tracker.feed(bytes) { CompletionProvider.shared.record(line) }
        case .ssh(let alias, _, _, _, _):
            // Not sure it's the remote shell's own prompt: stay quiet.
            if bytes.contains(0x04) { remoteGate.endOfInput(lineWasEmpty: tracker.isValid && tracker.line.isEmpty) }
            guard remoteGate.isOpen, !session.io.inAltBuffer, session.activeEditor == nil else {
                tracker.invalidate(); hide(); return
            }
            for line in tracker.feed(bytes) {
                remoteGate.submitted(line)
                Task { await RemoteCompletionProvider.shared.record(line, alias: alias) }
            }
            guard remoteGate.isOpen else { tracker.invalidate(); hide(); return }
        default:
            return
        }
        guard Self.enabled, tracker.isValid, !accepting, !tracker.line.isEmpty else { hide(); return }
        refresh()
    }

    // MARK: Suggesting

    private func refresh() {
        generation += 1
        let gen = generation
        let ctx = CompletionContext.parse(tracker.line)
        guard let session else { return }
        if case .ssh(let alias, _, _, _, _) = session.kind {
            refreshRemote(ctx, alias: alias, cwd: session.remoteDirectory, gen: gen)
            return
        }
        let cwd = session.currentDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path
        Task.detached(priority: .userInitiated) {
            let data = CompletionProvider.shared.data(for: ctx, cwd: cwd)
            let result = CompletionEngine.suggest(ctx, data: data)
            await MainActor.run { [weak self] in
                guard let self, gen == self.generation, self.tracker.isValid else { return }
                self.show(result)
            }
        }
    }

    private func refreshRemote(_ ctx: CompletionContext, alias: String, cwd: String?, gen: Int) {
        guard let store = HostStore.current, let host = store.hosts.first(where: { $0.alias == alias }) else { return }
        let credential = FileBrowserModel.credential(for: host, store: store)
        let hostname = host.connectHostname, port = host.effectivePort, user = host.user ?? NSUserName()
        Task { [weak self] in
            let data = await RemoteCompletionProvider.shared.data(
                for: ctx, alias: alias, cwd: cwd, credential: credential, hostname: hostname, port: port, user: user)
            let result = CompletionEngine.suggest(ctx, data: data)
            guard let self, gen == self.generation, self.tracker.isValid, self.remoteGate.isOpen else { return }
            self.show(result)
        }
    }

    private func show(_ result: [Completion]) {
        guard !result.isEmpty, let session, let view = session.terminalView as? (NSView & NSTextInputClient),
              let window = view.window, window.firstResponder === view else { hide(); return }
        items = result
        selected = 0
        let caret = view.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)
        let panel = self.panel ?? makePanel(parent: window)
        render(panel)
        let size = panel.contentView?.fittingSize ?? NSSize(width: 260, height: 100)
        var origin = NSPoint(x: caret.minX, y: caret.minY - size.height - 2)
        if let screen = window.screen?.visibleFrame, origin.y < screen.minY { origin.y = caret.maxY + 2 }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
        installMonitor()
    }

    func hide() {
        generation += 1
        items = []
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func makePanel(parent: NSWindow) -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = parent.level
        panel = p
        return p
    }

    private func render(_ panel: NSPanel) {
        let host = NSHostingView(rootView: CompletionListView(items: items, selected: selected))
        panel.contentView = host
    }

    // MARK: Keys

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            nonisolated(unsafe) let e = event
            let used = MainActor.assumeIsolated { self.handle(e) }
            return used ? nil : event
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard !items.isEmpty, let session, let panel,
              session.terminalView.window?.firstResponder === session.terminalView else { return false }
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard mods.isEmpty else { return false }
        switch event.keyCode {
        case 125: selected = (selected + 1) % items.count; render(panel); return true
        case 126: selected = (selected - 1 + items.count) % items.count; render(panel); return true
        case 48, 124: accept(items[selected]); return true
        case 53: hide(); return true
        default: return false
        }
    }

    private func accept(_ item: Completion) {
        hide()
        guard let session else { return }
        accepting = true
        session.terminalView.send(txt: item.insert)
        accepting = false
    }
}

private struct CompletionListView: View {
    let items: [Completion]
    let selected: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                HStack(spacing: 8) {
                    Image(systemName: icon(item.kind)).frame(width: 14).foregroundStyle(.secondary)
                    Text(item.display).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 12)
                    Text(label(item.kind)).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .font(.system(size: 12, design: .monospaced))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(i == selected ? Color.accentColor.opacity(0.3) : .clear,
                            in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .padding(4)
        .frame(minWidth: 220, maxWidth: 420, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.separator))
        .fixedSize()
    }

    private func icon(_ k: Completion.Kind) -> String {
        switch k {
        case .branch: "arrow.triangle.branch"
        case .script: "play"
        case .makeTarget: "hammer"
        case .host: "server.rack"
        case .path: "folder"
        case .history: "clock.arrow.circlepath"
        case .subcommand: "terminal"
        }
    }

    private func label(_ k: Completion.Kind) -> String {
        let l = Localizer.shared
        return switch k {
        case .branch: l.t("分支", "branch")
        case .script: l.t("脚本", "script")
        case .makeTarget: l.t("目标", "target")
        case .host: l.t("主机", "host")
        case .path: l.t("路径", "path")
        case .history: l.t("历史", "history")
        case .subcommand: l.t("子命令", "command")
        }
    }
}

/// The IO behind completion: off the main thread, with timeouts and caches.
final class CompletionProvider: @unchecked Sendable {
    static let shared = CompletionProvider()

    private let lock = NSLock()
    private var branchCache: [String: (Date, [String])] = [:]
    private var fileCache: [String: (Date, Any)] = [:]
    private var sessionHistory: [String] = []

    /// A line submitted in a Wireline session.
    func record(_ line: String) {
        lock.withLock {
            sessionHistory.removeAll { $0 == line }
            sessionHistory.insert(line, at: 0)
            if sessionHistory.count > 500 { sessionHistory.removeLast() }
        }
    }

    func data(for ctx: CompletionContext, cwd: String) -> CompletionData {
        let needs = CompletionEngine.needs(for: ctx)
        var d = CompletionData()
        if needs.contains(.branches) { d.branches = branches(cwd) }
        if needs.contains(.scripts) {
            d.scripts = cachedFile(cwd + "/package.json") { CompletionParsers.packageScripts($0) } ?? []
        }
        if needs.contains(.makeTargets) {
            for name in ["GNUmakefile", "makefile", "Makefile"] {
                if let t = cachedFile(cwd + "/" + name, { CompletionParsers.makeTargets(String(decoding: $0, as: UTF8.self)) }) {
                    d.makeTargets = t
                    break
                }
            }
        }
        if needs.contains(.hosts) {
            d.hosts = cachedFile(home + "/.ssh/config") { CompletionParsers.sshHosts(String(decoding: $0, as: UTF8.self)) } ?? []
        }
        if needs.contains(.history) { d.history = history() }
        if needs.contains(.paths) { d.pathEntries = entries(ctx.current, cwd: cwd) }
        return d
    }

    private var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

    private func branches(_ cwd: String) -> [String] {
        if let (at, b) = lock.withLock({ branchCache[cwd] }), Date().timeIntervalSince(at) < 10 { return b }
        let out = Self.run("/usr/bin/git", ["-C", cwd, "for-each-ref", "--sort=-committerdate",
                                             "--format=%(refname)", "refs/heads", "refs/remotes"], timeout: 1)
        let b = (out ?? "").split(separator: "\n").compactMap { ref -> String? in
            guard !ref.hasSuffix("/HEAD") else { return nil }
            for p in ["refs/heads/", "refs/remotes/"] where ref.hasPrefix(p) { return String(ref.dropFirst(p.count)) }
            return nil
        }
        lock.withLock { branchCache[cwd] = (Date(), b) }
        return b
    }

    /// Parsed file contents, reparsed when its mtime changes; nil when missing.
    private func cachedFile<T>(_ path: String, _ parse: (Data) -> T) -> T? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        if let (at, v) = lock.withLock({ fileCache[path] }), at == mtime, let v = v as? T { return v }
        guard let size = attrs[.size] as? Int, size < 8 << 20,
              let data = FileManager.default.contents(atPath: path) else { return nil }
        let v = parse(data)
        lock.withLock { fileCache[path] = (mtime, v) }
        return v
    }

    private func history() -> [String] {
        var files = [home + "/.zsh_history", home + "/.bash_history"]
        if let h = ProcessInfo.processInfo.environment["HISTFILE"] { files.insert(h, at: 0) }
        var fromFiles: [String] = []
        for f in files {
            if let h = cachedFile(f, { data -> [String] in
                // Last 1 MB; zsh writes metafied bytes, decoded leniently.
                CompletionParsers.history(String(decoding: data.suffix(1 << 20), as: UTF8.self))
            }) { fromFiles += h }
        }
        return lock.withLock { sessionHistory } + fromFiles
    }

    private func entries(_ word: String, cwd: String) -> [String] {
        var dir = CompletionEngine.pathDirectoryPart(word)
        if dir.hasPrefix("~") { dir = home + dir.dropFirst() }
        let full = dir.hasPrefix("/") ? dir : cwd + "/" + dir
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: full) else { return [] }
        return names.sorted().prefix(2000).map { name in
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: full + "/" + name, isDirectory: &isDir)
            return isDir.boolValue ? name + "/" : name
        }
    }

    /// stdout of a short command, nil on failure or after `timeout` seconds.
    static func run(_ exe: String, _ args: [String], timeout: TimeInterval) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        timer.cancel()
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
