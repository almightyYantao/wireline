import AppKit
import Observation
import WirelineCore

/// Named workspace layouts, in `Application Support/Wireline/workspaces.json`.
@Observable
@MainActor
final class WorkspaceStore {
    static let shared = WorkspaceStore()

    private(set) var library = WorkspaceLibrary()
    /// The file couldn't be read (corrupt, or from a newer Wireline): it is
    /// left alone rather than overwritten.
    private(set) var readOnly = false

    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wireline/workspaces.json")
    }

    var workspaces: [Workspace] { library.sorted }

    private init() { load() }

    func load() {
        guard let data = try? Data(contentsOf: Self.fileURL) else { return }
        do {
            library = try WorkspaceLibrary.decode(data)
        } catch {
            readOnly = true
        }
    }

    private func write() {
        guard !readOnly, let data = try? library.encoded() else { return }
        let url = Self.fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    @discardableResult
    func save(name: String, from sessions: SessionStore) -> Workspace? {
        let (tabs, active) = sessions.workspaceTabs()
        guard let w = library.save(name: name, tabs: tabs, activeTab: active) else { return nil }
        write()
        return w
    }

    func rename(_ id: UUID, to name: String) -> Bool {
        guard library.rename(id, to: name) else { return false }
        write()
        return true
    }

    func delete(_ id: UUID) {
        library.delete(id)
        write()
    }
}

/// The save / rename / delete prompts (menu and command palette).
@MainActor
enum WorkspaceActions {
    private static var loc: Localizer { Localizer.shared }

    static func save(_ sessions: SessionStore) {
        let store = WorkspaceStore.shared
        guard !store.readOnly else { return unreadable() }
        guard !sessions.tabs.isEmpty else {
            return info(loc.t("没有打开的标签可保存", "No open tabs to save"))
        }
        let suggested = loc.t("工作区 \(store.workspaces.count + 1)", "Workspace \(store.workspaces.count + 1)")
        guard let name = ask(loc.t("保存工作区", "Save Workspace"),
                             detail: loc.t("保存当前窗口的标签、分屏和每个窗格的会话。同名会覆盖。",
                                           "Saves this window's tabs, splits and what runs in each pane. A workspace with the same name is replaced."),
                             value: suggested, button: loc.t("保存", "Save")) else { return }
        if let existing = store.library.workspace(named: name),
           !confirm(loc.t("覆盖「\(existing.name)」？", "Replace “\(existing.name)”?"), button: loc.t("覆盖", "Replace")) {
            return
        }
        store.save(name: name, from: sessions)
    }

    static func open(_ w: Workspace, sessions: SessionStore, store: HostStore) {
        if sessions.openWorkspace(w, store: store) == 0 {
            info(loc.t("「\(w.name)」里的主机都已不在", "None of “\(w.name)”'s hosts exist any more"))
        }
    }

    static func rename(_ w: Workspace) {
        let store = WorkspaceStore.shared
        guard !store.readOnly else { return unreadable() }
        guard let name = ask(loc.t("重命名工作区", "Rename Workspace"), detail: nil, value: w.name,
                             button: loc.t("重命名", "Rename")) else { return }
        if !store.rename(w.id, to: name) {
            info(loc.t("名称为空或已被占用", "That name is empty or already taken"))
        }
    }

    static func delete(_ w: Workspace) {
        let store = WorkspaceStore.shared
        guard !store.readOnly else { return unreadable() }
        guard confirm(loc.t("删除工作区「\(w.name)」？", "Delete workspace “\(w.name)”?"),
                      button: loc.t("删除", "Delete")) else { return }
        store.delete(w.id)
    }

    // MARK: - Prompts

    private static func ask(_ title: String, detail: String?, value: String, button: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        if let detail { alert.informativeText = detail }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = value
        alert.accessoryView = field
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: loc.t("取消", "Cancel"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = WorkspaceLibrary.normalizedName(field.stringValue)
        return name.isEmpty ? nil : name
    }

    private static func confirm(_ title: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: loc.t("取消", "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func info(_ title: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.runModal()
    }

    private static func unreadable() {
        info(loc.t("workspaces.json 无法读取（损坏或来自更新的版本），为避免覆盖，暂不能修改。",
                   "workspaces.json can't be read (damaged, or from a newer version); it won't be changed so nothing is lost."))
    }
}
