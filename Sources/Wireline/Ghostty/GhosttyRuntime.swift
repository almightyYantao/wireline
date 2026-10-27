// The runtime callbacks follow Ghostty's macOS app (macos/Sources/Ghostty/Ghostty.App.swift),
// Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors. MIT License — see LICENSE-ghostty.

import AppKit
import GhosttyKit
import UniformTypeIdentifiers
import os

let ghosttyLog = Logger(subsystem: "com.wireline.app", category: "ghostty")

/// libghostty's process-wide half: the one `ghostty_app_t`, its runtime
/// callbacks, and the configs generated from Wireline's appearance settings.
///
/// Threading: libghostty calls `wakeup_cb` from its IO / renderer threads,
/// and the other callbacks from inside `ghostty_app_tick` or a surface call —
/// in practice the main thread, but nothing promises it. Every callback is a
/// nonisolated C function that copies its payload (pointers die when it
/// returns) and then runs on the main actor: synchronously when already
/// there, else hopped.
@MainActor
final class GhosttyRuntime {
    static let shared = GhosttyRuntime()

    private(set) var app: ghostty_app_t?
    private var started = false
    /// Why the runtime isn't available, once `start()` has failed.
    private(set) var failure: String?

    /// Start libghostty on first use. False (and `failure` set) if it can't.
    @discardableResult
    func start() -> Bool {
        if started { return app != nil }
        started = true
        configureResourcesDirectory()
        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
            return fail("ghostty_init failed")
        }
        let base = TerminalAppearance(
            theme: .wireline, font: TerminalFont.preferred(size: 13) ?? .monospacedSystemFont(ofSize: 13, weight: .regular),
            gpu: true, cursorShape: .block, cursorBlink: true)
        // The app keeps its config for its whole life; never freed.
        guard let config = makeConfig(GhosttyConfig.text(for: base)) else { return fail("base config failed to load") }
        var rt = ghostty_runtime_config_s(
            userdata: nil,
            supports_selection_clipboard: false,
            wakeup_cb: ghosttyWakeup,
            action_cb: ghosttyAction,
            read_clipboard_cb: ghosttyReadClipboard,
            confirm_read_clipboard_cb: ghosttyConfirmReadClipboard,
            write_clipboard_cb: ghosttyWriteClipboard,
            close_surface_cb: ghosttyCloseSurface)
        guard let app = ghostty_app_new(&rt, config) else { return fail("ghostty_app_new failed") }
        self.app = app
        ghostty_app_set_focus(app, NSApp?.isActive ?? false)

        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { if let app = GhosttyRuntime.shared.app { ghostty_app_set_focus(app, true) } }
        }
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { if let app = GhosttyRuntime.shared.app { ghostty_app_set_focus(app, false) } }
        }
        // A new keyboard layout changes how keys translate.
        center.addObserver(forName: NSTextInputContext.keyboardSelectionDidChangeNotification, object: nil,
                           queue: .main) { _ in
            MainActor.assumeIsolated { if let app = GhosttyRuntime.shared.app { ghostty_app_keyboard_changed(app) } }
        }
        let info = ghostty_info()
        let version = String(decoding: UnsafeRawBufferPointer(start: info.version, count: Int(info.version_len)),
                             as: UTF8.self)
        ghosttyLog.info("libghostty \(version, privacy: .public) ready")
        return true
    }

    private func fail(_ why: String) -> Bool {
        failure = why
        ghosttyLog.error("libghostty unavailable: \(why, privacy: .public)")
        return false
    }

    /// Ghostty finds shell-integration / terminfo through GHOSTTY_RESOURCES_DIR
    /// (or by climbing from the executable to `Contents/Resources/terminfo`).
    /// `scripts/bundle.sh` puts them in `Contents/Resources/ghostty` and
    /// `Contents/Resources/terminfo`; say so explicitly.
    private func configureResourcesDirectory() {
        guard getenv("GHOSTTY_RESOURCES_DIR") == nil,
              let dir = Bundle.main.resourceURL?.appendingPathComponent("ghostty"),
              FileManager.default.fileExists(atPath: dir.path) else { return }
        setenv("GHOSTTY_RESOURCES_DIR", dir.path, 1)
    }

    // MARK: Tick

    /// Coalesces wakeups: one main-queue tick per burst.
    fileprivate nonisolated static let tickPending = OSAllocatedUnfairLock(initialState: false)

    fileprivate func tick() {
        Self.tickPending.withLock { $0 = false }
        if let app { ghostty_app_tick(app) }
    }

    // MARK: Surfaces

    /// Live views by the id passed to libghostty as surface userdata. An id,
    /// not the view pointer: a late callback for a freed view finds nothing
    /// instead of a dangling object.
    private var views: [Int: WeakView] = [:]
    private var nextID = 1
    private final class WeakView { weak var view: GhosttyTerminalView?; init(_ v: GhosttyTerminalView) { view = v } }

    /// A fresh surface id (never reused).
    func makeID() -> Int {
        defer { nextID += 1 }
        return nextID
    }

    func register(_ view: GhosttyTerminalView, id: Int) {
        views = views.filter { $0.value.view != nil }
        views[id] = WeakView(view)
    }

    func view(_ id: Int) -> GhosttyTerminalView? { views[id]?.view }

    // MARK: Configs

    /// Generated configs by text, so a re-applied appearance (SwiftUI re-renders
    /// constantly) or a focus flip reuses a parsed one. Surfaces copy what
    /// `ghostty_surface_update_config` gives them, so evicting is safe.
    private var configs: [(text: String, config: ghostty_config_t)] = []

    func config(for appearance: TerminalAppearance, focused: Bool) -> ghostty_config_t? {
        let text = GhosttyConfig.text(for: appearance, focused: focused)
        if let i = configs.firstIndex(where: { $0.text == text }) {
            let hit = configs.remove(at: i)
            configs.append(hit)
            return hit.config
        }
        guard let config = makeConfig(text) else { return nil }
        configs.append((text, config))
        if configs.count > 8 { ghostty_config_free(configs.removeFirst().config) }
        return config
    }

    private lazy var configDirectory: URL = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wireline-ghostty-\(getpid())", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Parse `text` as a Ghostty config file. Never loads the user's files.
    private func makeConfig(_ text: String) -> ghostty_config_t? {
        let url = configDirectory.appendingPathComponent("\(UUID().uuidString).ghostty")
        guard (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil,
              let cfg = ghostty_config_new() else { return nil }
        defer { try? FileManager.default.removeItem(at: url) }
        ghostty_config_load_file(cfg, url.path)
        ghostty_config_finalize(cfg)
        for i in 0..<ghostty_config_diagnostics_count(cfg) {
            let message = String(cString: ghostty_config_get_diagnostic(cfg, i).message)
            ghosttyLog.warning("config: \(message, privacy: .public)")
            Self.diagnostics.append(message)
        }
        return cfg
    }

    /// Every config diagnostic so far (the harness asserts there are none).
    private(set) static var diagnostics: [String] = []

    // MARK: Clipboard

    /// While set, a clipboard write from libghostty goes here instead of the
    /// pasteboard (`write_screen_file:copy` hands back the file path this way).
    var clipboardCapture: ((String) -> Void)?

    fileprivate func writeClipboard(_ items: [(mime: String, data: Data)]) {
        if let capture = clipboardCapture,
           let text = items.first(where: { $0.mime == "text/plain" }).flatMap({ String(data: $0.data, encoding: .utf8) }) {
            capture(text)
            return
        }
        let pb = NSPasteboard.general
        let typed = items.compactMap { item in Self.pasteboardType(mime: item.mime).map { ($0, item.data) } }
        guard !typed.isEmpty else { return }
        pb.declareTypes(typed.map(\.0), owner: nil)
        for (type, data) in typed { pb.setData(data, forType: type) }
    }

    fileprivate func readClipboard(surface: ghostty_surface_t, mimes: [String], list: Bool, state: UInt) -> Bool {
        let pb = NSPasteboard.general
        var contents: [(String, Data)] = []
        for mime in Set(mimes) {
            guard let type = Self.pasteboardType(mime: mime), let data = pb.data(forType: type) else { continue }
            contents.append((mime, data))
        }
        let available = list ? (pb.types ?? []).compactMap { Self.mime(for: $0) } : []
        if contents.isEmpty && !list { return false }
        Self.complete(surface, contents: contents, available: available, state: state, confirmed: false)
        return true
    }

    static func complete(_ surface: ghostty_surface_t, contents: [(String, Data)], available: [String],
                         state: UInt, confirmed: Bool) {
        // C copies that live for the duration of the call.
        var cStrings: [UnsafeMutablePointer<CChar>] = []
        var cDatas: [UnsafeMutableRawPointer] = []
        defer { cStrings.forEach { free($0) }; cDatas.forEach { $0.deallocate() } }
        var cContents: [ghostty_clipboard_content_s] = []
        for (mime, data) in contents {
            guard let m = strdup(mime) else { continue }
            cStrings.append(m)
            let buf = UnsafeMutableRawPointer.allocate(byteCount: max(data.count, 1), alignment: 1)
            cDatas.append(buf)
            data.withUnsafeBytes { if let base = $0.baseAddress { buf.copyMemory(from: base, byteCount: $0.count) } }
            cContents.append(ghostty_clipboard_content_s(mime: m, data: buf.assumingMemoryBound(to: CChar.self),
                                                        len: data.count))
        }
        var cAvailable: [UnsafePointer<CChar>?] = []
        for mime in available { if let s = strdup(mime) { cStrings.append(s); cAvailable.append(UnsafePointer(s)) } }
        cContents.withUnsafeBufferPointer { cb in
            cAvailable.withUnsafeBufferPointer { ab in
                var complete = ghostty_clipboard_complete_s(
                    contents: cb.baseAddress, contents_len: cb.count,
                    available: ab.baseAddress, available_len: ab.count,
                    confirmed: confirmed, remember: false)
                ghostty_surface_complete_clipboard_request(surface, &complete, UnsafeMutableRawPointer(bitPattern: state))
            }
        }
    }

    static func pasteboardType(mime: String) -> NSPasteboard.PasteboardType? {
        if mime == "text/plain" || mime.hasPrefix("text/plain;") { return .string }
        return UTType(mimeType: mime).map { NSPasteboard.PasteboardType($0.identifier) }
    }

    static func mime(for type: NSPasteboard.PasteboardType) -> String? {
        if type == .string { return "text/plain" }
        return UTType(type.rawValue)?.preferredMIMEType
    }
}

// MARK: - C callbacks (nonisolated)

/// Run `body` on the main actor: now if we're on the main thread, else soon.
private func onMain(_ body: @escaping @MainActor @Sendable () -> Void) {
    if Thread.isMainThread { MainActor.assumeIsolated { body() } }
    else { DispatchQueue.main.async { MainActor.assumeIsolated { body() } } }
}

private func surfaceID(_ userdata: UnsafeMutableRawPointer?) -> Int { Int(bitPattern: userdata) }

private func ghosttyWakeup(_ userdata: UnsafeMutableRawPointer?) {
    let alreadyPending = GhosttyRuntime.tickPending.withLock { pending in
        defer { pending = true }
        return pending
    }
    guard !alreadyPending else { return }
    DispatchQueue.main.async { MainActor.assumeIsolated { GhosttyRuntime.shared.tick() } }
}

private func ghosttyAction(_ app: ghostty_app_t?, _ target: ghostty_target_s, _ action: ghostty_action_s) -> Bool {
    var id = 0
    if target.tag == GHOSTTY_TARGET_SURFACE, let s = target.target.surface {
        id = surfaceID(ghostty_surface_userdata(s))
    }
    guard let event = GhosttyEvent(action) else { return false }
    // App-wide actions (quit, new window, …) belong to Wireline, not libghostty.
    guard id != 0 else { return event.isAppLevelNoop }
    onMain { GhosttyRuntime.shared.view(id)?.handle(event) }
    return true
}

private func ghosttyReadClipboard(_ userdata: UnsafeMutableRawPointer?, _ location: ghostty_clipboard_e,
                                  _ state: UnsafeMutableRawPointer?, _ mimes: UnsafePointer<UnsafePointer<CChar>?>?,
                                  _ mimesLen: Int, _ list: Bool) -> ghostty_clipboard_read_result_e {
    guard location == GHOSTTY_CLIPBOARD_STANDARD else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }
    let id = surfaceID(userdata)
    var wanted: [String] = []
    if let mimes { for i in 0..<mimesLen { if let p = mimes[i] { wanted.append(String(cString: p)) } } }
    let stateBits = UInt(bitPattern: state)
    let wantedCopy = wanted
    if Thread.isMainThread {
        return MainActor.assumeIsolated {
            guard let s = GhosttyRuntime.shared.view(id)?.surface?.raw else { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }
            return GhosttyRuntime.shared.readClipboard(surface: s, mimes: wantedCopy, list: list, state: stateBits)
                ? GHOSTTY_CLIPBOARD_READ_STARTED : GHOSTTY_CLIPBOARD_READ_UNAVAILABLE
        }
    }
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            guard let s = GhosttyRuntime.shared.view(id)?.surface?.raw else { return }
            if !GhosttyRuntime.shared.readClipboard(surface: s, mimes: wantedCopy, list: list, state: stateBits) {
                ghostty_surface_deny_clipboard_request(s, UnsafeMutableRawPointer(bitPattern: stateBits))
            }
        }
    }
    return GHOSTTY_CLIPBOARD_READ_STARTED
}

/// Reached for a paste libghostty calls unsafe under the paste-confirm policy
/// (multi-line; bracketed paste counts as safe unless the policy is "always"):
/// Wireline's card asks. Anything else that needs confirming is denied.
private func ghosttyConfirmReadClipboard(_ userdata: UnsafeMutableRawPointer?,
                                         _ confirm: UnsafePointer<ghostty_clipboard_confirm_s>?,
                                         _ state: UnsafeMutableRawPointer?, _ request: ghostty_clipboard_request_e) {
    let id = surfaceID(userdata)
    let stateBits = UInt(bitPattern: state)
    var contents: [(String, Data)] = []
    var available: [String] = []
    if let c = confirm?.pointee {
        if let items = c.contents {
            for i in 0..<c.contents_len {
                let item = items[i]
                let data = item.len > 0 && item.data != nil ? Data(bytes: item.data, count: item.len) : Data()
                contents.append((String(cString: item.mime), data))
            }
        }
        if let av = c.available { for i in 0..<c.available_len { if let p = av[i] { available.append(String(cString: p)) } } }
    }
    let isPaste = request == GHOSTTY_CLIPBOARD_REQUEST_PASTE
    let sendable = contents.map { ClipboardItem(mime: $0.0, data: $0.1) }
    let availableCopy = available
    onMain {
        guard let s = GhosttyRuntime.shared.view(id)?.surface?.raw else { return }
        guard isPaste, let view = GhosttyRuntime.shared.view(id) else {
            return ghostty_surface_deny_clipboard_request(s, UnsafeMutableRawPointer(bitPattern: stateBits))
        }
        let text = sendable.first { $0.mime.hasPrefix("text/plain") }.map { String(decoding: $0.data, as: UTF8.self) } ?? ""
        PasteConfirmCenter.shared.ask(text, from: view) { choice in
            guard let s = GhosttyRuntime.shared.view(id)?.surface?.raw else { return }
            var items = sendable.map { ($0.mime, $0.data) }
            switch choice {
            case .cancel:
                return ghostty_surface_deny_clipboard_request(s, UnsafeMutableRawPointer(bitPattern: stateBits))
            case .singleLine:
                let one = Data(PasteConfirmCenter.singleLine(text).utf8)
                items = items.map { $0.0.hasPrefix("text/plain") ? ($0.0, one) : $0 }
            case .paste:
                break
            }
            GhosttyRuntime.complete(s, contents: items, available: availableCopy, state: stateBits, confirmed: true)
        }
    }
}

private struct ClipboardItem: Sendable { let mime: String; let data: Data }

private func ghosttyWriteClipboard(_ userdata: UnsafeMutableRawPointer?, _ location: ghostty_clipboard_e,
                                   _ content: UnsafePointer<ghostty_clipboard_content_s>?, _ len: Int,
                                   _ confirm: Bool) {
    guard location == GHOSTTY_CLIPBOARD_STANDARD, let content, len > 0 else { return }
    var items: [ClipboardItem] = []
    for i in 0..<len {
        let c = content[i]
        guard let mime = c.mime else { continue }
        let data = c.len > 0 && c.data != nil ? Data(bytes: c.data, count: c.len) : Data()
        items.append(ClipboardItem(mime: String(cString: mime), data: data))
    }
    let copy = items
    onMain { GhosttyRuntime.shared.writeClipboard(copy.map { ($0.mime, $0.data) }) }
}

private func ghosttyCloseSurface(_ userdata: UnsafeMutableRawPointer?, _ processAlive: Bool) {
    let id = surfaceID(userdata)
    onMain { GhosttyRuntime.shared.view(id)?.surfaceRequestedClose(processAlive: processAlive) }
}

// MARK: - Actions

/// A libghostty action, copied out of its C payload (which dies when the
/// callback returns).
enum GhosttyEvent: Sendable {
    case title(String)
    case pwd(String)
    case commandFinished(exitCode: Int?, seconds: Double)
    case scrollbar(total: UInt64, offset: UInt64, length: UInt64)
    case cellSize(width: UInt32, height: UInt32)
    case searchStarted
    case searchEnded
    case searchTotal(Int?)
    case searchSelected(Int?)
    case mouseShape(UInt32)
    case mouseVisible(Bool)
    case mouseOverLink(String?)
    case openURL(String)
    case bell
    case childExited(code: UInt32)
    case rendererHealthy(Bool)
    /// Handled, nothing to do (render ticks, config/colour change echoes).
    case ignored

    init?(_ a: ghostty_action_s) {
        func str(_ p: UnsafePointer<CChar>?) -> String { p.map { String(cString: $0) } ?? "" }
        switch a.tag {
        case GHOSTTY_ACTION_SET_TITLE: self = .title(str(a.action.set_title.title))
        case GHOSTTY_ACTION_PWD: self = .pwd(str(a.action.pwd.pwd))
        case GHOSTTY_ACTION_COMMAND_FINISHED:
            let c = a.action.command_finished
            self = .commandFinished(exitCode: c.exit_code < 0 ? nil : Int(c.exit_code), seconds: Double(c.duration) / 1e9)
        case GHOSTTY_ACTION_SCROLLBAR:
            let s = a.action.scrollbar
            self = .scrollbar(total: s.total, offset: s.offset, length: s.len)
        case GHOSTTY_ACTION_CELL_SIZE: self = .cellSize(width: a.action.cell_size.width, height: a.action.cell_size.height)
        case GHOSTTY_ACTION_START_SEARCH: self = .searchStarted
        case GHOSTTY_ACTION_END_SEARCH: self = .searchEnded
        case GHOSTTY_ACTION_SEARCH_TOTAL:
            let t = a.action.search_total.total
            self = .searchTotal(t < 0 ? nil : t)
        case GHOSTTY_ACTION_SEARCH_SELECTED:
            let s = a.action.search_selected.selected
            self = .searchSelected(s < 0 ? nil : s)
        case GHOSTTY_ACTION_MOUSE_SHAPE: self = .mouseShape(a.action.mouse_shape.rawValue)
        case GHOSTTY_ACTION_MOUSE_VISIBILITY: self = .mouseVisible(a.action.mouse_visibility == GHOSTTY_MOUSE_VISIBLE)
        case GHOSTTY_ACTION_MOUSE_OVER_LINK:
            let l = a.action.mouse_over_link
            self = .mouseOverLink(l.len > 0 && l.url != nil
                ? String(decoding: UnsafeRawBufferPointer(start: l.url, count: l.len), as: UTF8.self) : nil)
        case GHOSTTY_ACTION_OPEN_URL:
            let u = a.action.open_url
            guard let p = u.url else { return nil }
            self = .openURL(String(decoding: UnsafeRawBufferPointer(start: p, count: Int(u.len)), as: UTF8.self))
        case GHOSTTY_ACTION_RING_BELL: self = .bell
        case GHOSTTY_ACTION_SHOW_CHILD_EXITED: self = .childExited(code: a.action.child_exited.exit_code)
        case GHOSTTY_ACTION_RENDERER_HEALTH:
            self = .rendererHealthy(a.action.renderer_health == GHOSTTY_RENDERER_HEALTH_HEALTHY)
        case GHOSTTY_ACTION_RENDER, GHOSTTY_ACTION_CONFIG_CHANGE, GHOSTTY_ACTION_COLOR_CHANGE,
             GHOSTTY_ACTION_SELECTION_CHANGED, GHOSTTY_ACTION_KEY_SEQUENCE, GHOSTTY_ACTION_KEY_TABLE,
             GHOSTTY_ACTION_PROGRESS_REPORT, GHOSTTY_ACTION_SET_TAB_TITLE, GHOSTTY_ACTION_RELOAD_CONFIG:
            self = .ignored
        default:
            // Window / tab / split management, quit, inspector, notifications:
            // Wireline does those itself. Unhandled → libghostty's default.
            return nil
        }
    }

    /// App-targeted actions we acknowledge without doing anything.
    var isAppLevelNoop: Bool { if case .ignored = self { true } else { false } }
}
