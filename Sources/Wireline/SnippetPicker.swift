import SwiftUI
import AppKit
import WirelineCore

// Snippets ("快捷指令"): a floating panel anchored to the pane's toolbar button,
// and rows in the ⌘P palette. Both share the same flow — Return inserts the
// command (no newline), ⌘Return runs it; parameters open an inline form,
// multi-line scripts and dangerous commands open a preview to confirm.

// MARK: - Flow

enum SnippetSendMode { case insert, run }

/// What happens after a snippet is picked, when it can't go straight in.
enum SnippetStep: Equatable {
    /// Fill in its `{{parameters}}` first.
    case fill(Snippet, SnippetSendMode)
    /// Review a multi-line script / dangerous command before it runs.
    case confirm(Snippet, text: String, values: [String: String], mode: SnippetSendMode)
}

@MainActor
enum SnippetFlow {
    /// The next step for a picked snippet, or nil when it can be sent now.
    static func start(_ s: Snippet, _ mode: SnippetSendMode) -> SnippetStep? {
        if !s.parameters.isEmpty { return .fill(s, mode) }
        return review(s, text: s.command, values: [:], mode: mode)
    }

    /// After the parameters are filled: a multi-line script always gets a
    /// preview (inserting it would run every line but the last anyway); a
    /// dangerous command gets one whenever it would execute.
    static func review(_ s: Snippet, text: String, values: [String: String], mode: SnippetSendMode) -> SnippetStep? {
        if Snippet.commandLines(text).count > 1 || (mode == .run && SnippetSafety.isDangerous(text)) {
            return .confirm(s, text: text, values: values, mode: mode)
        }
        return nil
    }

    /// Put the text into the pane's terminal through the session API (works on
    /// both engines; broadcast is untouched), count the use, focus the pane.
    static func send(_ s: Snippet, text: String, values: [String: String], mode: SnippetSendMode,
                     to session: TerminalSession, store: SnippetStore, sessions: SessionStore) {
        let body = text.trimmingCharacters(in: .newlines)
        if mode == .run || Snippet.commandLines(body).count > 1 {
            session.runInTerminal(body)
        } else {
            session.insertIntoTerminal(body)
        }
        store.recordUse(s.id, values: values)
        sessions.activeID = session.id
        sessions.focusActiveTerminal()
    }
}

// MARK: - Presentation state

/// Which pane's snippet panel is open (at most one).
@Observable
@MainActor
final class SnippetPanel {
    static let shared = SnippetPanel()
    private(set) var sessionID: UUID?
    private var closed: (id: UUID?, at: Date) = (nil, .distantPast)

    func isOpen(for id: UUID) -> Bool { sessionID == id }

    /// The toolbar button. A click outside the panel closes it on mouse-down —
    /// when that click was on this same button, don't reopen it right away.
    func toggle(_ id: UUID) {
        if sessionID == id { close(); return }
        if closed.id == id, Date().timeIntervalSince(closed.at) < 0.3 { return }
        wlAnimate(Motion.popIn) { sessionID = id }
    }

    func close() {
        guard sessionID != nil else { return }
        closed = (sessionID, Date())
        wlAnimate(Motion.popOut) { sessionID = nil }
    }
}

// MARK: - Anchors

/// The toolbar button that opens a pane's snippet panel (info bar, split headers).
struct SnippetToolbarButton: View {
    @Environment(Localizer.self) private var loc
    let session: TerminalSession
    var size: CGFloat = 24

    var body: some View {
        let open = SnippetPanel.shared.isOpen(for: session.id)
        Button { SnippetPanel.shared.toggle(session.id) } label: {
            Image(systemName: "bolt").font(.system(size: size > 22 ? 11 : 10, weight: .medium))
        }
        .buttonStyle(.wlIcon(tint: open ? WL.green : nil, size: size))
        .help(loc("快捷指令（⌘P 也能搜）", "Snippets (also in ⌘P)"))
    }
}

/// Where the panel hangs: the top-trailing corner of the pane, just under its
/// header / info bar, so it sits right below the button.
struct SnippetPanelHost: View {
    let session: TerminalSession
    /// Height of the bar above the terminal.
    let top: CGFloat

    var body: some View {
        if SnippetPanel.shared.isOpen(for: session.id) {
            SnippetPicker(session: session)
                .padding(.top, top + 2).padding(.trailing, 8)
                .transition(.wlPop(anchor: .topTrailing))
        }
    }
}

// MARK: - Panel

/// The snippet panel: a search capsule over the list, sorted by what suits this
/// pane and what you use most. The terminal stays visible around it.
struct SnippetPicker: View {
    @Environment(SnippetStore.self) private var store
    @Environment(HostStore.self) private var hosts
    @Environment(SessionStore.self) private var sessions
    @Environment(Localizer.self) private var loc
    let session: TerminalSession

    @State private var query = ""
    @State private var highlighted = 0
    @State private var keyboardNav = false
    @State private var step: SnippetStep?
    /// nil = the list; `.some(nil)` = a new snippet; `.some(s)` = editing s.
    @State private var editing: Snippet??
    /// Browsing one folder (and its subfolder); nil = everything.
    @State private var folder: String?
    @State private var selecting = false
    @State private var selection: Set<UUID> = []
    @State private var batchRun: [Snippet]?
    @State private var notice: String?
    @FocusState private var searchFocused: Bool

    private var platform: PanePlatform { store.platform(for: session) }
    private var hostGroup: String? { hosts.hosts.first { $0.alias == session.alias }?.group }

    private var results: [Snippet] {
        var ranked = Snippet.ranked(store.snippets, platform: platform, hostGroup: hostGroup)
        if let folder { ranked = ranked.filter { SnippetFolders.contains(folder, $0.folder) } }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return ranked }
        return ranked.filter { SearchText.matches(q, in: $0.allTitles + " " + $0.command + " " + ($0.folder ?? "")) }
    }

    /// Rows plus the trailing "+ New snippet" row.
    private var rowCount: Int { results.count + 1 }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: WL.radius(14), style: .continuous)
        VStack(spacing: 0) {
            if let editing {
                SnippetEditorCard(original: editing, groups: hosts.groups, folders: store.folders,
                                  defaultFolder: folder,
                                  onSave: save, onCancel: { closeEditor() })
            } else if let batchRun {
                SnippetBatchRunView(snippets: batchRun, current: session,
                                    onBack: { self.batchRun = nil; focusSearch() },
                                    onDone: { endSelecting(); SnippetPanel.shared.close() })
            } else if let step {
                SnippetStepView(step: step, session: session,
                                onStep: { self.step = $0 },
                                onBack: { self.step = nil; focusSearch() },
                                onDone: { SnippetPanel.shared.close() })
            } else {
                searchBar
                WLFormDivider()
                list
                WLFormDivider()
                footer
            }
        }
        .frame(width: 400)
        .background(ClickOutsideMonitor { SnippetPanel.shared.close() })
        .clipShape(shape)
        .wlFloating(shape, shadow: 0.35, radius: 18, y: 6)
        .wlOccludesTerminal()
        .onAppear {
            store.probePlatform(of: session)
            focusSearch()
        }
        .onDisappear { if sessions.activeID == session.id { sessions.focusActiveTerminal() } }
        .onExitCommand {
            if editing != nil { closeEditor() }
            else if batchRun != nil { batchRun = nil; focusSearch() }
            else if step != nil { step = nil; focusSearch() }
            else if selecting { endSelecting() }
            else { SnippetPanel.shared.close() }
        }
    }

    private func focusSearch() { DispatchQueue.main.async { searchFocused = true } }

    // MARK: Search

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(WL.textDim)
            TextField(loc("搜索快捷指令", "Search snippets"), text: $query)
                .textFieldStyle(.plain).font(WL.body).foregroundStyle(WL.textPrimary)
                .focused($searchFocused)
                .onSubmit { activate(highlighted, .insert) }
                .onChange(of: query) { highlighted = 0 }
                .onKeyPress(.downArrow) {
                    keyboardNav = true
                    highlighted = min(highlighted + 1, rowCount - 1); return .handled
                }
                .onKeyPress(.upArrow) {
                    keyboardNav = true
                    highlighted = max(highlighted - 1, 0); return .handled
                }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(WL.textDim)
                }
                .buttonStyle(.wlPlain).transition(.opacity)
            }
            folderMenu
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .wlSearchCapsule(focused: searchFocused)
        .padding(8)
        .animation(Motion.hover, value: query.isEmpty)
        // ⌘↩ runs the highlighted snippet (a key equivalent, so it beats the field).
        .background {
            Button("") { activate(highlighted, .run) }
                .keyboardShortcut(.return, modifiers: .command)
                .opacity(0).allowsHitTesting(false).accessibilityHidden(true)
        }
    }

    // MARK: List

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { i, s in
                        SnippetRow(snippet: s,
                                   matches: s.matches(platform: platform, hostGroup: hostGroup),
                                   highlighted: i == highlighted,
                                   showFolder: folder == nil,
                                   checked: selecting ? selection.contains(s.id) : nil,
                                   onEdit: selecting ? nil : { openEditor(s) },
                                   onDelete: selecting ? nil : { store.remove(s) })
                            .onContinuousHover { phase in
                                if case .active = phase, highlighted != i, !keyboardNav { highlighted = i }
                            }
                            .onTapGesture { selecting ? toggle(s.id) : activate(i, .insert) }
                            .wlContextMenu(menu(for: s, index: i))
                            .id(s.id)
                    }
                    if results.isEmpty, !query.isEmpty {
                        Text(loc("没有匹配的快捷指令", "No matching snippets"))
                            .font(WL.small).foregroundStyle(WL.textDim)
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                            .transition(.opacity)
                    }
                    if !selecting { newRow
                        .onContinuousHover { phase in
                            if case .active = phase, !keyboardNav { highlighted = results.count }
                        }
                        .onTapGesture { openEditor(nil) }
                        .id("new")
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 340)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: highlighted) {
                guard keyboardNav else { return }
                if results.indices.contains(highlighted) { proxy.scrollTo(results[highlighted].id) }
                else { proxy.scrollTo("new") }
            }
        }
        .animation(Motion.state, value: results.isEmpty)
        .background(MouseMoveWatcher { keyboardNav = false })
    }

    private var newRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(WL.green)
                .frame(width: 26, height: 26)
            Text(loc("新建快捷指令", "New snippet")).font(WL.body).foregroundStyle(WL.textPrimary)
            Spacer()
        }
        .wlResultHighlight(highlighted == results.count)
    }

    @ViewBuilder
    private var footer: some View {
        if selecting { selectionBar } else {
            HStack(spacing: 10) {
                Text(notice ?? scopeLabel).font(WL.caption).foregroundStyle(notice == nil ? WL.textDim : WL.green)
                    .lineLimit(1)
                Spacer(minLength: 8)
                KeyHint(keys: "↩", label: loc("插入", "Insert"))
                KeyHint(keys: "⌘↩", label: loc("运行", "Run"))
                Menu {
                    Button(loc("多选…", "Select…")) { selecting = true; selection = [] }
                    Divider()
                    Button(loc("恢复内置模板", "Restore Built-in Templates")) {
                        let n = store.restoreDefaults()
                        notice = n == 0 ? loc("内置模板都在", "All built-ins present")
                                        : loc("已恢复 \(n) 个内置模板", "Restored \(n) built-ins")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 12)).foregroundStyle(WL.textDim)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help(loc("更多", "More"))
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
    }

    private var selectedSnippets: [Snippet] { results.filter { selection.contains($0.id) } }

    private var selectionBar: some View {
        HStack(spacing: 8) {
            Button(selection.count == results.count && !results.isEmpty ? loc("全不选", "None") : loc("全选", "All")) {
                selection = selection.count == results.count ? [] : Set(results.map(\.id))
            }
            .buttonStyle(.wlSecondary)
            Text(loc("已选 \(selection.count)", "\(selection.count) selected")).font(WL.caption).foregroundStyle(WL.textDim)
            Spacer(minLength: 4)
            Menu {
                Button(loc("顶层（无文件夹）", "Top level (no folder)")) { moveSelection(to: nil) }
                if !store.folders.isEmpty { Divider() }
                ForEach(store.folders, id: \.self) { f in
                    Button(f.replacingOccurrences(of: "/", with: " › ")) { moveSelection(to: f) }
                }
            } label: { Text(loc("移动到", "Move to")).font(WL.caption) }
            .menuStyle(.borderlessButton).fixedSize().disabled(selection.isEmpty)
            Button(loc("执行…", "Run…")) { batchRun = selectedSnippets }
                .buttonStyle(.wlSecondary).disabled(selection.isEmpty)
            Button(loc("删除", "Delete")) { store.remove(ids: selection); selection = [] }
                .buttonStyle(.wlDestructive).disabled(selection.isEmpty)
            Button(loc("完成", "Done")) { endSelecting() }.buttonStyle(.wlPrimary)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
    }

    private var folderMenu: some View {
        Menu {
            Button(loc("全部文件夹", "All folders")) { folder = nil }
            if !store.folders.isEmpty { Divider() }
            ForEach(store.folders, id: \.self) { f in
                Button((SnippetFolders.parent(of: f) == nil ? "" : "    ") + (f.split(separator: "/").last.map(String.init) ?? f)) {
                    folder = f
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "folder").font(.system(size: 10))
                if let folder { Text(folder.split(separator: "/").last.map(String.init) ?? folder).font(WL.caption) }
            }
            .foregroundStyle(folder == nil ? WL.textDim : WL.green)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(loc("按文件夹筛选", "Filter by folder"))
        .onChange(of: folder) { highlighted = 0 }
    }

    private func toggle(_ id: UUID) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    private func moveSelection(to f: String?) {
        store.move(ids: selection, to: f)
        if let folder, !SnippetFolders.contains(folder, f) { selection = [] }
    }

    private func endSelecting() { selecting = false; selection = []; focusSearch() }

    /// "macOS · 本机" / "Linux · prod" / "未识别（按 Linux）".
    private var scopeLabel: String {
        let p: String = switch platform {
        case .macos: "macOS"
        case .linux: "Linux"
        case .otherUnix: "Unix"
        case .unknown: loc("未识别系统（按 Linux）", "Unknown OS (as Linux)")
        }
        if case .localShell = session.kind { return p + loc(" · 本机", " · this Mac") }
        return [p, hostGroup].compactMap { $0 }.joined(separator: " · ")
    }

    private func menu(for s: Snippet, index i: Int) -> [WLMenuItem] {
        [
            .item(loc("插入", "Insert"), systemImage: "text.insert") { activate(i, .insert) },
            .item(loc("运行", "Run"), systemImage: "play") { activate(i, .run) },
            .divider,
            .item(loc("编辑…", "Edit…"), systemImage: "pencil") { openEditor(s) },
            .item(loc("复制命令", "Copy Command"), systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(s.command, forType: .string)
            },
            .submenu(loc("移动到", "Move to"), systemImage: "folder",
                     [.item(loc("顶层（无文件夹）", "Top level (no folder)")) { store.move(ids: [s.id], to: nil) }]
                     + store.folders.map { f in .item(f.replacingOccurrences(of: "/", with: " › ")) {
                         store.move(ids: [s.id], to: f) } }),
            .item(loc("多选…", "Select…"), systemImage: "checklist") { selecting = true; selection = [s.id] },
            .divider,
            .item(loc("删除", "Delete"), systemImage: "trash", destructive: true) { store.remove(s) },
        ]
    }

    // MARK: Actions

    private func activate(_ index: Int, _ mode: SnippetSendMode) {
        guard results.indices.contains(index) else {
            if index == results.count { openEditor(nil) }
            return
        }
        let s = results[index]
        if let next = SnippetFlow.start(s, mode) {
            step = next
        } else {
            SnippetFlow.send(s, text: s.command, values: [:], mode: mode, to: session, store: store, sessions: sessions)
            SnippetPanel.shared.close()
        }
    }

    private func openEditor(_ s: Snippet?) { wlAnimate(Motion.state) { editing = .some(s) } }

    private func closeEditor() {
        wlAnimate(Motion.state) { editing = nil }
        focusSearch()
    }

    private func save(_ s: Snippet) {
        if store.snippets.contains(where: { $0.id == s.id }) { store.update(s) } else { store.add(s) }
        closeEditor()
    }
}

/// "↩ 插入" — a key and what it does.
struct KeyHint: View {
    let keys: String
    let label: String
    var body: some View {
        HStack(spacing: 4) {
            Text(keys).font(WL.caption.weight(.semibold)).foregroundStyle(WL.textPrimary.opacity(0.75))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(WL.textPrimary.opacity(0.07), in: RoundedRectangle(cornerRadius: WL.radius(4), style: .continuous))
            Text(label).font(WL.caption).foregroundStyle(WL.textDim)
        }
    }
}

// MARK: - Row

/// One snippet: category icon, title in the UI language, the command, badges.
/// Snippets that don't suit this pane are dimmed (never hidden).
struct SnippetRow: View {
    @Environment(Localizer.self) private var loc
    let snippet: Snippet
    let matches: Bool
    let highlighted: Bool
    var showFolder = false
    /// Non-nil in multi-select mode.
    var checked: Bool? = nil
    var onEdit: (() -> Void)?
    var onDelete: (() -> Void)?
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            if let checked {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13)).foregroundStyle(checked ? WL.green : WL.textDim)
            }
            SnippetIcon(category: snippet.category, highlighted: highlighted)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(snippet.title(chinese: loc.isChinese)).font(WL.body).foregroundStyle(WL.textPrimary)
                        .lineLimit(1)
                    SnippetBadges(snippet: snippet)
                    if showFolder, let f = snippet.folder {
                        Text(f.replacingOccurrences(of: "/", with: " › ")).font(WL.caption)
                            .foregroundStyle(WL.textDim).lineLimit(1)
                    }
                }
                Text(Snippet.commandLines(snippet.command).first ?? "")
                    .font(WL.mono(11)).foregroundStyle(WL.textDim).lineLimit(1).truncationMode(.tail)
            }
            .opacity(matches ? 1 : 0.5)
            Spacer(minLength: 6)
            if onEdit != nil || onDelete != nil {
                HStack(spacing: 0) {
                    if let onEdit {
                        Button(action: onEdit) { Image(systemName: "pencil").font(.system(size: 10, weight: .medium)) }
                            .buttonStyle(.wlIcon(size: 22)).help(loc("编辑", "Edit"))
                    }
                    if let onDelete {
                        Button(action: onDelete) { Image(systemName: "trash").font(.system(size: 10, weight: .medium)) }
                            .buttonStyle(.wlIcon(tint: hover ? WL.red : nil, size: 22)).help(loc("删除", "Delete"))
                    }
                }
                .opacity(hover ? 1 : 0)
                .allowsHitTesting(hover)
                .animation(Motion.hover, value: hover)
            }
        }
        .wlResultHighlight(highlighted)
        .wlHover($hover)
        .help(snippet.command)
    }
}

/// The category's SF Symbol in a subtly tinted tile.
struct SnippetIcon: View {
    let category: SnippetCategory
    var highlighted = false
    var body: some View {
        let tint = category.tint
        Image(systemName: category.symbol)
            .font(.system(size: 11, weight: .medium)).foregroundStyle(tint.opacity(0.9))
            .frame(width: 26, height: 26)
            .background(tint.opacity(highlighted ? 0.16 : 0.1),
                        in: RoundedRectangle(cornerRadius: WL.radius(8), style: .continuous))
    }
}

/// Platform / host group / script / danger badges after a title.
struct SnippetBadges: View {
    @Environment(Localizer.self) private var loc
    let snippet: Snippet
    var body: some View {
        HStack(spacing: 4) {
            switch snippet.platform {
            case .linux: badge("Linux")
            case .macos: badge("macOS")
            case .any: EmptyView()
            }
            if let g = snippet.hostGroup, !g.isEmpty { badge(g, symbol: "folder") }
            if snippet.isMultiLine {
                badge(loc("脚本 · \(snippet.lineCount) 行", "Script · \(snippet.lineCount) lines"), tint: WL.teal)
            }
            if SnippetSafety.isDangerous(snippet.command) {
                badge(loc("高危", "Risky"), symbol: "exclamationmark.triangle.fill", tint: WL.red)
            }
        }
        .fixedSize()
    }

    private func badge(_ text: String, symbol: String? = nil, tint: Color? = nil) -> some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: 7, weight: .semibold)) }
            Text(text).font(.system(size: 9.5, weight: .medium))
        }
        .foregroundStyle(tint ?? WL.textDim)
        .padding(.horizontal, 5).padding(.vertical, 1)
        .background((tint ?? WL.textPrimary).opacity(tint == nil ? 0.07 : 0.12), in: Capsule(style: .continuous))
    }
}

extension SnippetCategory {
    var tint: Color {
        switch self {
        case .disk, .logs, .package: WL.amber
        case .memory, .git: WL.purple
        case .cpu, .process, .script: WL.green
        case .network, .docker: WL.teal
        case .systemd, .generic: WL.textDim
        }
    }

    @MainActor func name(_ loc: Localizer) -> String {
        switch self {
        case .disk: loc("磁盘", "Disk")
        case .memory: loc("内存", "Memory")
        case .cpu: loc("CPU / 负载", "CPU / load")
        case .network: loc("网络 / 端口", "Network / ports")
        case .process: loc("进程", "Processes")
        case .logs: loc("日志", "Logs")
        case .docker: "Docker"
        case .git: "Git"
        case .package: loc("软件包", "Packages")
        case .systemd: loc("服务", "Services")
        case .script: loc("脚本", "Script")
        case .generic: loc("通用", "Generic")
        }
    }
}

// MARK: - Fill & confirm

/// The inline step after picking: the parameter form or the run preview.
/// Shared by the panel and the ⌘P palette.
struct SnippetStepView: View {
    @Environment(SnippetStore.self) private var store
    @Environment(SessionStore.self) private var sessions
    let step: SnippetStep
    let session: TerminalSession
    var onStep: (SnippetStep) -> Void
    var onBack: () -> Void
    var onDone: () -> Void

    var body: some View {
        switch step {
        case let .fill(s, mode):
            SnippetFillForm(snippet: s, mode: mode, onBack: onBack) { values, mode in
                let text = s.filled(with: values)
                if let next = SnippetFlow.review(s, text: text, values: values, mode: mode) {
                    onStep(next)
                } else {
                    send(s, text, values, mode)
                }
            }
            .id(s.id)
        case let .confirm(s, text, values, mode):
            SnippetConfirmView(snippet: s, text: text, mode: mode, onBack: onBack) {
                send(s, text, values, mode)
            }
            .id(s.id.uuidString + text)
        }
    }

    private func send(_ s: Snippet, _ text: String, _ values: [String: String], _ mode: SnippetSendMode) {
        onDone()
        SnippetFlow.send(s, text: text, values: values, mode: mode, to: session, store: store, sessions: sessions)
    }
}

/// Title row for a step: back, the snippet's title, and its badges.
private struct StepHeader: View {
    @Environment(Localizer.self) private var loc
    let snippet: Snippet
    let subtitle: String
    var onBack: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Button(action: onBack) { Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold)) }
                .buttonStyle(.wlIcon(size: 22)).help(loc("返回（Esc）", "Back (Esc)"))
            SnippetIcon(category: snippet.category)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(snippet.title(chinese: loc.isChinese)).font(WL.body.weight(.semibold))
                        .foregroundStyle(WL.textPrimary).lineLimit(1)
                    SnippetBadges(snippet: snippet)
                }
                Text(subtitle).font(WL.caption).foregroundStyle(WL.textDim).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 8)
    }
}

/// Capsule fields for each `{{parameter}}`; Tab moves between them, Return
/// inserts, ⌘Return runs. Starts from last time's values, else the defaults.
struct SnippetFillForm: View {
    @Environment(Localizer.self) private var loc
    let snippet: Snippet
    let mode: SnippetSendMode
    var onBack: () -> Void
    var onConfirm: ([String: String], SnippetSendMode) -> Void
    @State private var values: [String: String]

    init(snippet: Snippet, mode: SnippetSendMode, onBack: @escaping () -> Void,
         onConfirm: @escaping ([String: String], SnippetSendMode) -> Void) {
        self.snippet = snippet; self.mode = mode; self.onBack = onBack; self.onConfirm = onConfirm
        _values = State(initialValue: snippet.initialValues())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(snippet: snippet, subtitle: loc("填写参数", "Fill in parameters"), onBack: onBack)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(snippet.parameters, id: \.name) { p in
                    HStack(spacing: 10) {
                        Text(p.name).font(WL.small).foregroundStyle(WL.textDim)
                            .lineLimit(1).frame(width: 90, alignment: .trailing)
                        ParamField(text: binding(p.name), prompt: p.defaultValue ?? "",
                                   autofocus: p.name == firstBlank) { onConfirm(values, mode) }
                    }
                }
                Text(snippet.filled(with: values))
                    .font(WL.mono(11)).foregroundStyle(WL.green.opacity(0.85))
                    .lineLimit(4).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(WL.fieldFill, in: RoundedRectangle(cornerRadius: WL.radius(10), style: .continuous))
                    .textSelection(.enabled)
                    .padding(.top, 2)
            }
            .padding(.horizontal, 12).padding(.bottom, 10)
            WLFormDivider()
            HStack(spacing: 10) {
                KeyHint(keys: "Tab", label: loc("下一项", "Next"))
                Spacer()
                Button { onConfirm(values, .insert) } label: { Text(loc("插入 ↩", "Insert ↩")) }
                    .buttonStyle(.wlChip(on: mode == .insert))
                Button { onConfirm(values, .run) } label: { Text(loc("运行 ⌘↩", "Run ⌘↩")) }
                    .buttonStyle(.wlChip(on: mode == .run))
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }

    /// Where the caret starts: the first blank not already filled in.
    private var firstBlank: String? {
        let initial = snippet.initialValues()
        return (snippet.parameters.first { (initial[$0.name] ?? "").isEmpty } ?? snippet.parameters.first)?.name
    }

    private func binding(_ name: String) -> Binding<String> {
        Binding(get: { values[name] ?? "" }, set: { values[name] = $0 })
    }
}

/// One parameter's capsule field (Tab moves on through the key-view loop).
private struct ParamField: View {
    @Binding var text: String
    let prompt: String
    let autofocus: Bool
    var onSubmit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text, prompt: Text(prompt).foregroundStyle(WL.textDim.opacity(0.6)))
            .wlField(font: WL.mono(12), focus: $focused)
            .onSubmit(onSubmit)
            .onAppear { if autofocus { DispatchQueue.main.async { focused = true } } }
    }
}

/// Preview of what will run, with a warning for dangerous commands. Return /
/// ⌘Return confirms, Esc goes back. Long scripts collapse to their first lines.
struct SnippetConfirmView: View {
    @Environment(Localizer.self) private var loc
    let snippet: Snippet
    let text: String
    let mode: SnippetSendMode
    var onBack: () -> Void
    var onConfirm: () -> Void
    @State private var expanded = false
    @FocusState private var focused: Bool

    private static let collapsedLines = 6
    private var lines: [String] { text.trimmingCharacters(in: .newlines).components(separatedBy: "\n") }
    private var reasons: [String] { SnippetSafety.dangerReasons(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(snippet: snippet,
                       subtitle: lines.count > 1 ? loc("确认后逐行执行", "Runs line by line once confirmed")
                                                 : loc("确认后执行", "Runs once confirmed"),
                       onBack: onBack)
            VStack(alignment: .leading, spacing: 8) {
                if !reasons.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10))
                        Text(loc("包含高危操作：", "Contains risky operations: ") + reasons.joined(separator: loc("、", ", ")))
                            .font(WL.small)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(WL.red)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(WL.red.opacity(0.1), in: RoundedRectangle(cornerRadius: WL.radius(10), style: .continuous))
                }
                preview
            }
            .padding(.horizontal, 12).padding(.bottom, 10)
            WLFormDivider()
            HStack(spacing: 10) {
                KeyHint(keys: "esc", label: loc("返回", "Back"))
                Spacer()
                Button(action: onConfirm) {
                    Text(lines.count > 1 ? loc("运行 \(lines.count) 行 ↩", "Run \(lines.count) lines ↩")
                                         : loc("运行 ↩", "Run ↩"))
                }
                .buttonStyle(.wlChip(on: true, tint: reasons.isEmpty ? WL.green : WL.red))
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.return) { onConfirm(); return .handled }
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    private var preview: some View {
        let shown = expanded ? lines : Array(lines.prefix(Self.collapsedLines))
        return VStack(alignment: .leading, spacing: 6) {
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { i, line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            if lines.count > 1 {
                                Text("\(i + 1)").font(WL.mono(10)).foregroundStyle(WL.textDim.opacity(0.6))
                                    .frame(minWidth: 14, alignment: .trailing)
                            }
                            Text(line.isEmpty ? " " : line).font(WL.mono(11)).foregroundStyle(WL.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            .frame(maxHeight: 220)
            .fixedSize(horizontal: false, vertical: true)
            if lines.count > Self.collapsedLines {
                Button {
                    wlAnimate(Motion.disclose) { expanded.toggle() }
                } label: {
                    Text(expanded ? loc("收起", "Collapse")
                                  : loc("展开全部 \(lines.count) 行", "Show all \(lines.count) lines"))
                }
                .buttonStyle(.wlChip())
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WL.fieldFill, in: RoundedRectangle(cornerRadius: WL.radius(10), style: .continuous))
    }
}

// MARK: - Editor

/// Create / edit a snippet in place (a card in the panel, not a sheet).
struct SnippetEditorCard: View {
    @Environment(Localizer.self) private var loc
    let original: Snippet?
    let groups: [String]
    var folders: [String] = []
    var onSave: (Snippet) -> Void
    var onCancel: () -> Void

    @State private var titleZh: String
    @State private var titleEn: String
    @State private var command: String
    @State private var platform: SnippetPlatform
    @State private var group: String
    @State private var icon: String
    @State private var folder: String
    @FocusState private var titleFocused: Bool

    init(original: Snippet?, groups: [String], folders: [String] = [], defaultFolder: String? = nil,
         onSave: @escaping (Snippet) -> Void, onCancel: @escaping () -> Void) {
        self.original = original; self.groups = groups; self.folders = folders
        self.onSave = onSave; self.onCancel = onCancel
        _folder = State(initialValue: original.map { $0.folder ?? "" } ?? defaultFolder ?? "")
        _titleZh = State(initialValue: original?.titleZh ?? "")
        _titleEn = State(initialValue: original?.titleEn ?? "")
        _command = State(initialValue: original?.command ?? "")
        _platform = State(initialValue: original?.platform ?? .any)
        _group = State(initialValue: original?.hostGroup ?? "")
        _icon = State(initialValue: original?.categoryOverride?.rawValue ?? "")
    }

    private var canSave: Bool {
        !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !(titleZh + titleEn).trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var inferred: SnippetCategory { SnippetCategory.infer(from: command) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                SnippetIcon(category: SnippetCategory(rawValue: icon) ?? inferred)
                Text(original == nil ? loc("新建快捷指令", "New snippet") : loc("编辑快捷指令", "Edit snippet"))
                    .font(WL.body.weight(.semibold)).foregroundStyle(WL.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        labeled(loc("中文标题", "Chinese title")) {
                            TextField("", text: $titleZh, prompt: Text("磁盘占用").foregroundStyle(WL.textDim.opacity(0.6)))
                                .wlField(font: WL.body, focus: $titleFocused)
                        }
                        labeled(loc("英文标题", "English title")) {
                            TextField("", text: $titleEn, prompt: Text("Disk usage").foregroundStyle(WL.textDim.opacity(0.6)))
                                .wlField(font: WL.body)
                        }
                    }
                    labeled(loc("命令（可多行，逐行执行）", "Command (multi-line runs line by line)")) {
                        TextEditor(text: $command)
                            .font(WL.mono(12))
                            .textEditorStyle(.plain)
                            .scrollContentBackground(.hidden)
                            .frame(height: 86)
                            .wlField(font: WL.mono(12), multiline: true)
                    }
                    Text(loc("参数写成 {{名称}} 或 {{名称:默认值}}（也认 «名称»），插入前会让你填写；Go 模板如 {{.Names}} 不受影响。",
                             "Write parameters as {{name}} or {{name:default}} (or «name»); you fill them in before inserting. Go templates like {{.Names}} are left alone."))
                        .font(WL.caption).foregroundStyle(WL.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                    labeled(loc("文件夹（可写 父/子，最多两级）", "Folder (parent/child, two levels max)")) {
                        HStack(spacing: 6) {
                            TextField("", text: $folder, prompt: Text(loc("无", "None")).foregroundStyle(WL.textDim.opacity(0.6)))
                                .wlField(font: WL.body)
                            if !folders.isEmpty {
                                Menu {
                                    Button(loc("无", "None")) { folder = "" }
                                    ForEach(folders, id: \.self) { f in Button(f) { folder = f } }
                                } label: { Image(systemName: "folder").font(.system(size: 11)) }
                                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                            }
                        }
                    }
                    labeled(loc("适用系统", "Platform")) {
                        WLSegmented(selection: $platform, options: [
                            WLOption(.any, loc("通用", "Any")),
                            WLOption(.linux, "Linux"),
                            WLOption(.macos, "macOS"),
                        ])
                    }
                    HStack(spacing: 12) {
                        labeled(loc("主机分组", "Host group")) {
                            WLMenuPicker(selection: $group,
                                         options: [WLOption("", loc("任意主机", "Any host"))] + groupOptions,
                                         minWidth: 150)
                        }
                        labeled(loc("图标", "Icon")) {
                            WLMenuPicker(selection: $icon,
                                         options: [WLOption("", loc("自动：", "Auto: ") + inferred.name(loc))]
                                             + SnippetCategory.allCases.map { WLOption($0.rawValue, $0.name(loc)) },
                                         minWidth: 150)
                        }
                        Spacer(minLength: 0)
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 12)
            }
            .frame(maxHeight: 380)
            .fixedSize(horizontal: false, vertical: true)

            WLFormDivider()
            HStack(spacing: 10) {
                KeyHint(keys: "⌘↩", label: loc("保存", "Save"))
                Spacer()
                Button(loc("取消", "Cancel"), action: onCancel).buttonStyle(.wlSecondary)
                Button(loc("保存", "Save"), action: save).buttonStyle(.wlPrimary)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canSave)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
        }
        .onAppear { DispatchQueue.main.async { titleFocused = true } }
    }

    /// The group list, plus a bound group that no longer exists (kept, not lost).
    private var groupOptions: [WLOption<String>] {
        var names = groups
        if !group.isEmpty, !names.contains(group) { names.append(group) }
        return names.map { WLOption($0, $0) }
    }

    private func labeled<V: View>(_ label: String, @ViewBuilder _ content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(WL.caption).foregroundStyle(WL.textDim).padding(.leading, 4)
            content()
        }
    }

    private func save() {
        guard canSave else { return }
        var s = original ?? Snippet(titleZh: "", titleEn: "", command: "")
        s.titleZh = titleZh.trimmingCharacters(in: .whitespaces)
        s.titleEn = titleEn.trimmingCharacters(in: .whitespaces)
        s.command = command.trimmingCharacters(in: .newlines)
        s.platform = platform
        s.hostGroup = group.isEmpty ? nil : group
        s.categoryOverride = SnippetCategory(rawValue: icon)
        s.folder = SnippetFolders.normalize(folder)
        onSave(s)
    }
}

// MARK: - Batch run

/// Run several snippets, in order, in several open terminal panes. Parameters
/// take last time's value or their default; dangerous ones are listed first.
struct SnippetBatchRunView: View {
    @Environment(SnippetStore.self) private var store
    @Environment(SessionStore.self) private var sessions
    @Environment(Localizer.self) private var loc
    let snippets: [Snippet]
    let current: TerminalSession
    var onBack: () -> Void
    var onDone: () -> Void

    @State private var targets: Set<UUID> = []

    private var panes: [TerminalSession] {
        sessions.sessions.filter { s in
            guard s.isRunning else { return false }
            switch s.kind { case .localShell, .ssh: return true; case .sftp, .rdp: return false }
        }
    }

    private func text(_ s: Snippet) -> String { s.filled(with: s.initialValues()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button(action: onBack) { Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold)) }
                    .buttonStyle(.wlIcon(size: 22))
                Text(loc("批量执行 \(snippets.count) 条", "Run \(snippets.count) snippets"))
                    .font(WL.body.weight(.semibold)).foregroundStyle(WL.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            WLFormDivider()
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(snippets) { s in
                        let reasons = SnippetSafety.dangerReasons(text(s))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.title(chinese: loc.isChinese)).font(WL.caption).foregroundStyle(WL.textPrimary)
                            Text(text(s)).font(WL.mono(11)).foregroundStyle(WL.textDim).lineLimit(2)
                            if !reasons.isEmpty {
                                Text("⚠︎ " + reasons.joined(separator: ", ")).font(WL.caption).foregroundStyle(WL.red)
                            }
                        }
                    }
                    Text(loc("执行到", "Run in")).font(WL.caption).foregroundStyle(WL.textDim).padding(.top, 6)
                    ForEach(panes) { p in
                        Button {
                            if targets.contains(p.id) { targets.remove(p.id) } else { targets.insert(p.id) }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: targets.contains(p.id) ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(targets.contains(p.id) ? WL.green : WL.textDim)
                                Text(p.title).font(WL.body).foregroundStyle(WL.textPrimary).lineLimit(1)
                                if p.id == current.id {
                                    Text(loc("当前", "current")).font(WL.caption).foregroundStyle(WL.textDim)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.wlPlain)
                    }
                }
                .padding(12)
            }
            .frame(maxHeight: 340)
            .fixedSize(horizontal: false, vertical: true)
            WLFormDivider()
            HStack {
                Button(loc("全部会话", "All panes")) { targets = Set(panes.map(\.id)) }.buttonStyle(.wlSecondary)
                Spacer()
                Button(loc("取消", "Cancel"), action: onBack).buttonStyle(.wlSecondary)
                Button(loc("执行到 \(targets.count) 个会话", "Run in \(targets.count)")) { run() }
                    .buttonStyle(.wlPrimary).disabled(targets.isEmpty)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
        }
        .onAppear { targets = [current.id] }
    }

    private func run() {
        for p in panes where targets.contains(p.id) {
            for s in snippets { p.runInTerminal(text(s).trimmingCharacters(in: .newlines)) }
        }
        for s in snippets { store.recordUse(s.id) }
        onDone()
    }
}

// MARK: - Search

/// Query matching shared by the palette and the snippet panel: every word must
/// appear in the text, or in the pinyin of its Chinese (full "cipan" or
/// initials "cp").
@MainActor
enum SearchText {
    private static var cache: [String: String] = [:]

    static func matches(_ query: String, in text: String) -> Bool {
        let hay = haystack(text)
        return query.lowercased().split(separator: " ").allSatisfy { hay.contains($0) }
    }

    static func haystack(_ text: String) -> String {
        if let hit = cache[text] { return hit }
        var out = text.lowercased()
        if text.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) {
            let latin = text.applyingTransform(.mandarinToLatin, reverse: false)?
                .applyingTransform(.stripDiacritics, reverse: false)?.lowercased() ?? ""
            let words = latin.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            out += " " + words.joined() + " " + String(words.compactMap(\.first))
        }
        if cache.count > 2000 { cache.removeAll() }
        cache[text] = out
        return out
    }
}

// MARK: - Click outside

/// Calls back on a mouse-down in the same window outside this view's frame —
/// how the floating panel closes when you click back into the terminal.
private struct ClickOutsideMonitor: NSViewRepresentable {
    let onOutside: () -> Void
    func makeNSView(context: Context) -> MonitorView { MonitorView(onOutside: onOutside) }
    func updateNSView(_ nsView: MonitorView, context: Context) { nsView.onOutside = onOutside }

    final class MonitorView: NSView {
        var onOutside: () -> Void
        private var monitor: Any?

        init(onOutside: @escaping () -> Void) { self.onOutside = onOutside; super.init(frame: .zero) }
        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] e in
                guard let self, let w = self.window, e.window === w else { return e }
                if !self.bounds.contains(self.convert(e.locationInWindow, from: nil)) {
                    DispatchQueue.main.async { self.onOutside() }
                }
                return e
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
