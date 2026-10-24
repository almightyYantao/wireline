import Foundation
import AppKit
import Observation

/// Edit a remote file in a local editor: it's copied to a cache folder and
/// opened there, and every save is copied back with `scp` (the system ssh, so
/// it keeps working after you leave the file browser).
@Observable
@MainActor
final class RemoteEditStore {
    static let shared = RemoteEditStore()

    struct Edit: Identifiable {
        let id = UUID()
        let alias: String
        let remotePath: String
        let localURL: URL
        var syncing = false
        var lastSynced: Date?
        var error: String?
        /// The local file's modification date as of the last copy either way.
        fileprivate var seen: Date?

        var name: String { localURL.lastPathComponent }
    }

    /// A local app that can edit text.
    struct Editor: Identifiable, Hashable {
        let bundleID: String
        let name: String
        let url: URL
        var id: String { bundleID }
    }

    private(set) var edits: [Edit] = []
    private var timer: Timer?

    private static let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Wireline/RemoteEdit", isDirectory: true)
    private static let editorKey = "remoteEditEditor"

    private init() {
        // Nothing survives a relaunch (edits aren't persisted): start clean.
        try? FileManager.default.removeItem(at: Self.cacheDir)
    }

    /// Editors found on this Mac, in a sensible order (looked up once: menus
    /// ask on every redraw).
    static func installedEditors() -> [Editor] { installed }
    private static let installed: [Editor] = {
        let known: [(String, String)] = [
            ("com.microsoft.VSCode", "VS Code"), ("com.todesktop.230313mzl4w4u92", "Cursor"),
            ("dev.zed.Zed", "Zed"), ("com.sublimetext.4", "Sublime Text"), ("com.panic.Nova", "Nova"),
            ("com.barebones.bbedit", "BBEdit"), ("com.apple.TextEdit", "TextEdit"),
        ]
        return known.compactMap { id, name in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { Editor(bundleID: id, name: name, url: $0) }
        }
    }()

    /// The editor picked last time, if it's still installed.
    static var preferredEditor: Editor? {
        let id = UserDefaults.standard.string(forKey: editorKey)
        return installedEditors().first { $0.bundleID == id }
    }

    func edits(for alias: String) -> [Edit] { edits.filter { $0.alias == alias } }

    /// Start editing `remotePath` (whose current bytes are `data`) in `editor`,
    /// or the one used last / the file type's default app.
    func begin(alias: String, remotePath: String, data: Data, editor: Editor?) {
        if let editor { UserDefaults.standard.set(editor.bundleID, forKey: Self.editorKey) }
        let chosen = editor ?? Self.preferredEditor
        // Already open: just bring the editor back rather than overwrite local edits.
        if let e = edits.first(where: { $0.alias == alias && $0.remotePath == remotePath }) {
            open(e.localURL, with: chosen)
            return
        }
        let dir = Self.cacheDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = dir.appendingPathComponent((remotePath as NSString).lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: url)
        } catch {
            Notifier.post(title: Localizer.shared.t("打开失败", "Couldn't open"), body: error.localizedDescription)
            return
        }
        edits.append(Edit(alias: alias, remotePath: remotePath, localURL: url, seen: Self.modified(url)))
        open(url, with: chosen)
        startWatching()
    }

    /// Stop syncing (the local copy is thrown away).
    func stop(_ id: UUID) {
        guard let e = edits.first(where: { $0.id == id }) else { return }
        edits.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: e.localURL.deletingLastPathComponent())
        if edits.isEmpty { timer?.invalidate(); timer = nil }
    }

    private func open(_ url: URL, with editor: Editor?) {
        let config = NSWorkspace.OpenConfiguration()
        if let editor {
            NSWorkspace.shared.open([url], withApplicationAt: editor.url, configuration: config)
        } else if NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            NSWorkspace.shared.open(url)
        } else if let textEdit = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
            // No app claims the type (`nginx.conf`, a dotfile): plain text it is.
            NSWorkspace.shared.open([url], withApplicationAt: textEdit, configuration: config)
        }
    }

    /// Editors often save by writing a new file and renaming it over the old
    /// one, which a file-descriptor watch loses; polling the date doesn't.
    private func startWatching() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { RemoteEditStore.shared.poll() }
        }
    }

    private func poll() {
        for e in edits where !e.syncing {
            guard let m = Self.modified(e.localURL), m != e.seen else { continue }
            sync(e.id, modified: m)
        }
    }

    private func sync(_ id: UUID, modified: Date) {
        guard let i = edits.firstIndex(where: { $0.id == id }) else { return }
        edits[i].syncing = true
        edits[i].seen = modified
        let e = edits[i]
        Task {
            let r = await FleetRunner.upload(localPath: e.localURL.path, to: e.alias, remotePath: e.remotePath)
            guard let j = edits.firstIndex(where: { $0.id == id }) else { return }
            edits[j].syncing = false
            if r.ok {
                edits[j].lastSynced = Date()
                edits[j].error = nil
            } else {
                edits[j].error = r.output
                Notifier.post(title: Localizer.shared.t("没能写回 \(e.alias):\(e.name)", "Couldn't save \(e.alias):\(e.name)"),
                              body: r.output)
            }
        }
    }

    private static func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
