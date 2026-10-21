import SwiftUI
import WirelineCore

/// Which subset of to-dos the list shows.
private enum TodoFilter: CaseIterable {
    case all, active, done
    @MainActor
    func title(_ loc: Localizer) -> String {
        switch self {
        case .all:    return loc("全部", "All")
        case .active: return loc("未完成", "Active")
        case .done:   return loc("已完成", "Done")
        }
    }
}

/// A recap produced by the AI, shown in a sheet.
private struct Recap: Identifiable {
    let id = UUID()
    let title: String
    let body: String
}

/// A standalone, keyboard-invokable to-do window. A generic daily checklist —
/// not tied to any host — that composites over the same wallpaper backdrop as
/// the main window (see `wlWallpaperBackground()`).
struct TodoWindowView: View {
    @Environment(TodoStore.self) private var store
    @Environment(HostStore.self) private var hosts
    @Environment(Localizer.self) private var loc

    @State private var draft = ""
    @State private var filter: TodoFilter = .all
    @State private var search = ""
    @State private var tagFilter: String?
    @State private var editingID: UUID?
    @State private var selectedID: UUID?
    @State private var smartAdd = false
    @State private var recap: Recap?
    @State private var aiBusy = false
    @FocusState private var inputFocused: Bool
    @FocusState private var searchFocused: Bool

    private var opacity: Double { hosts.terminalOpacity }

    private var visible: [Todo] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return store.ordered.filter { t in
            switch filter {
            case .all: break
            case .active: if t.done { return false }
            case .done: if !t.done { return false }
            }
            if let tag = tagFilter, !t.tags.contains(tag) { return false }
            if !q.isEmpty {
                let hay = ([t.title, t.note] + t.tags + t.subtasks.map(\.title)).joined(separator: " ").lowercased()
                if !hay.contains(q) { return false }
            }
            return true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            inputRow
            if !store.todos.isEmpty { filterBar }
            WLFormDivider()
            list
        }
        .frame(minWidth: 400, minHeight: 440)
        .background(WL.bg.opacity(opacity))
        .wlWallpaperBackground()
        .background(undoHotkey)
        .onAppear { inputFocused = true }
        .sheet(item: $recap) { r in recapSheet(r) }
    }

    // A zero-size button just to bind ⌘Z to undo, active whenever there's
    // something to undo.
    private var undoHotkey: some View {
        Button("") { store.undo() }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(!store.canUndo)
            .opacity(0).frame(width: 0, height: 0)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(loc("待办", "TODO")).font(WL.mono(13, .semibold)).foregroundStyle(WL.textPrimary)
            Text("\(store.activeCount)").font(WL.caption.monospacedDigit()).foregroundStyle(WL.textDim)
                .contentTransition(.numericText())
                .animation(Motion.state, value: store.activeCount)
            Spacer()
            WLSegmented(selection: $filter,
                        options: TodoFilter.allCases.map { WLOption($0, $0.title(loc)) }, fill: false)
            if TodoAI.isAvailable { aiMenu }
            if store.canUndo {
                BracketButton(loc("撤销", "Undo")) { store.undo() }
            }
            if store.todos.contains(where: { $0.done }) {
                BracketButton(loc("清除已完成", "Clear Done")) { store.clearCompleted() }
            }
        }
        .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 12)
    }

    private var aiMenu: some View {
        Menu {
            Button(loc("今日总结", "Today's recap")) { runRecap(.today, loc("今日总结", "Today's recap")) }
            Button(loc("本月总结", "This month's recap")) { runRecap(.month, loc("本月总结", "This month")) }
            Divider()
            Toggle(loc("智能添加(AI 解析时间)", "Smart add (AI parses dates)"), isOn: $smartAdd)
        } label: {
            HStack(spacing: 4) {
                Text(aiBusy ? loc("AI…", "AI…") : "AI")
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
            }
        }
        .menuStyle(.button).buttonStyle(.wlChip(on: true, tint: WL.purple)).menuIndicator(.hidden)
        .fixedSize()
        .disabled(aiBusy)
    }

    private var filterBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(WL.small).foregroundStyle(WL.textDim)
                TextField(loc("搜索…", "Search…"), text: $search)
                    .textFieldStyle(.plain).font(WL.small).foregroundStyle(WL.textPrimary)
                    .focused($searchFocused)
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(WL.small).foregroundStyle(WL.textDim)
                    }.buttonStyle(.wlPlain)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .wlSearchCapsule(focused: searchFocused)
            if !store.allTags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        tagChip(loc("全部", "All"), active: tagFilter == nil) { tagFilter = nil }
                        ForEach(store.allTags, id: \.self) { tag in
                            tagChip("#\(tag)", active: tagFilter == tag) {
                                tagFilter = (tagFilter == tag) ? nil : tag
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 18).padding(.bottom, 10)
    }

    private func tagChip(_ text: String, active: Bool, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) { Text(text) }
            .buttonStyle(.wlChip(on: active))
    }

    private var inputRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: smartAdd ? "sparkles" : "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(smartAdd ? WL.purple : WL.green)
                TextField(smartAdd ? loc("如：明天下午3点交周报", "e.g. submit report tomorrow 3pm")
                                   : loc("添加一条待办…", "Add a to-do…"), text: $draft)
                    .textFieldStyle(.plain)
                    .font(WL.body)
                    .foregroundStyle(WL.textPrimary)
                    .focused($inputFocused)
                    .onSubmit(commit)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .wlSearchCapsule(focused: inputFocused)
            Button(loc("添加", "Add"), action: commit)
                .buttonStyle(.wlPill())
        }
        .padding(.horizontal, 18).padding(.bottom, 10)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if visible.isEmpty {
                    Text(store.todos.isEmpty
                         ? loc("暂无待办。", "Nothing to do — yet.")
                         : loc("这个筛选下没有条目。", "Nothing under this filter."))
                        .font(WL.small).foregroundStyle(WL.textDim)
                        .padding(.horizontal, 18).padding(.top, 20)
                } else {
                    ForEach(visible) { todo in
                        TodoRow(todo: todo,
                                selected: selectedID == todo.id,
                                expanded: editingID == todo.id,
                                onSelect: { selectedID = todo.id },
                                onEdit: { toggleEditor(todo.id) })
                        if editingID == todo.id {
                            TodoEditor(todo: todo) { editingID = nil }
                        }
                    }
                }
            }
            .padding(.vertical, 6)
        }
        // Only grab keys for list navigation when no inline editor is open —
        // otherwise space/return/etc. would fight the editor's text fields
        // (e.g. typing a space in a note, or IME candidate selection).
        .focusable(!visible.isEmpty && editingID == nil)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { guard editingID == nil else { return .ignored }; moveSelection(-1); return .handled }
        .onKeyPress(.downArrow) { guard editingID == nil else { return .ignored }; moveSelection(1); return .handled }
        .onKeyPress(.space) { guard editingID == nil else { return .ignored }; toggleSelected(); return .handled }
        .onKeyPress(.return) { guard editingID == nil, let id = selectedID else { return .ignored }; toggleEditor(id); return .handled }
        .onKeyPress(.delete) { guard editingID == nil else { return .ignored }; removeSelected(); return .handled }
        .onKeyPress(.deleteForward) { guard editingID == nil else { return .ignored }; removeSelected(); return .handled }
    }

    private func recapSheet(_ r: Recap) -> some View {
        WLSheet(r.title, subtitle: loc("AI 根据待办生成", "Generated by AI from your to-dos"),
                symbol: "sparkles", width: 460, height: 360,
                onClose: { recap = nil }) {
            Text(r.body.isEmpty ? loc("(AI 没有返回内容)", "(no response)") : r.body)
                .font(WL.small).foregroundStyle(WL.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        } footer: {
            Spacer()
            Button(loc("关闭", "Close")) { recap = nil }
                .buttonStyle(.wlPrimary).keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Actions

    private func commit() {
        let text = draft
        draft = ""
        inputFocused = true
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if smartAdd && TodoAI.isAvailable {
            Task { store.add(await TodoAI.smartAdd(text, now: Date())) }
        } else {
            store.add(title: text)
        }
    }

    private func toggleEditor(_ id: UUID) {
        editingID = (editingID == id) ? nil : id
        selectedID = id
    }

    private func moveSelection(_ delta: Int) {
        let ids = visible.map(\.id)
        guard !ids.isEmpty else { return }
        guard let cur = selectedID, let i = ids.firstIndex(of: cur) else {
            selectedID = delta > 0 ? ids.first : ids.last
            return
        }
        let next = min(max(i + delta, 0), ids.count - 1)
        selectedID = ids[next]
    }

    private func toggleSelected() {
        if let id = selectedID, let t = store.todos.first(where: { $0.id == id }) { store.toggle(t) }
    }

    private func removeSelected() {
        guard let id = selectedID, let t = store.todos.first(where: { $0.id == id }) else { return }
        moveSelection(1)
        if selectedID == id { selectedID = nil }
        store.remove(t)
    }

    private func runRecap(_ scope: TodoAI.Scope, _ title: String) {
        aiBusy = true
        Task {
            let text = await TodoAI.recap(scope, store: store, now: Date())
            aiBusy = false
            recap = Recap(title: title, body: text)
        }
    }
}

// MARK: - Row

/// One row: checkbox, star, title (struck through when done), a due-date
/// badge, and edit / delete affordances on hover.
private struct TodoRow: View {
    @Environment(TodoStore.self) private var store
    @Environment(Localizer.self) private var loc
    let todo: Todo
    let selected: Bool
    let expanded: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Button { store.toggle(todo) } label: {
                Image(systemName: todo.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(todo.done ? WL.green : WL.textDim)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.wlPlain)

            Button {
                var t = todo; t.priority.toggle(); store.update(t)
            } label: {
                Image(systemName: todo.priority ? "star.fill" : "star")
                    .font(.system(size: 12))
                    .foregroundStyle(todo.priority ? WL.amber : WL.textDim.opacity(0.6))
            }
            .buttonStyle(.wlPlain)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(todo.title.isEmpty ? loc("(无标题)", "(untitled)") : todo.title)
                        .font(WL.body)
                        .foregroundStyle(todo.done ? WL.textDim : WL.textPrimary)
                        .strikethrough(todo.done, color: WL.textDim)
                        .lineLimit(2)
                    if todo.recurrence != .none {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(WL.caption).foregroundStyle(WL.teal)
                    }
                }
                metaLine
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: onEdit)
            .onTapGesture(perform: onSelect)

            if hover {
                Button(action: onEdit) {
                    Image(systemName: "pencil").font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.wlIcon(size: 22))
                .help(loc("编辑", "Edit"))
                Button { store.remove(todo) } label: {
                    Image(systemName: "trash").font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.wlIcon(tint: WL.red, size: 22))
                .help(loc("删除", "Delete"))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        // An inset rounded highlight, like the host drawer's rows.
        .background(rowBackground, in: RoundedRectangle(cornerRadius: WL.radius(10), style: .continuous))
        .animation(Motion.hover, value: hover)
        .animation(Motion.state, value: selected)
        .padding(.horizontal, 8).padding(.vertical, 1)
        .wlHover($hover)
    }

    /// Due-date badge · subtask progress · tag chips, on one line under the title.
    @ViewBuilder private var metaLine: some View {
        let progress = todo.subtaskProgress
        if todo.dueDate != nil || progress != nil || !todo.tags.isEmpty {
            HStack(spacing: 8) {
                if let due = todo.dueDate {
                    Text(dueText(due)).font(WL.caption).foregroundStyle(dueColor)
                }
                if let p = progress {
                    Text("☑ \(p.done)/\(p.total)").font(WL.caption)
                        .foregroundStyle(p.done == p.total ? WL.green : WL.textDim)
                }
                ForEach(todo.tags, id: \.self) { tag in
                    Text("#\(tag)").font(WL.caption).foregroundStyle(WL.purple)
                }
            }
        }
    }

    private var rowBackground: Color {
        if selected { return WL.green.opacity(0.12) }
        return WL.textPrimary.opacity(hover || expanded ? 0.055 : 0)
    }

    private var dueColor: Color {
        if todo.done { return WL.textDim }
        return todo.isOverdue(now: Date()) ? WL.red : WL.teal
    }

    private func dueText(_ due: Date) -> String {
        let prefix = todo.isOverdue(now: Date()) ? loc("逾期 ", "overdue · ") : ""
        return prefix + Self.formatter.string(from: due)
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()
}

// MARK: - Inline editor

/// Expanded editor beneath a row: title, note, and an optional due date/time.
private struct TodoEditor: View {
    @Environment(TodoStore.self) private var store
    @Environment(Localizer.self) private var loc
    let todo: Todo
    let onClose: () -> Void

    @State private var title = ""
    @State private var note = ""
    @State private var tags = ""
    @State private var hasDue = false
    @State private var due = Date()
    @State private var recurrence: Recurrence = .none
    @State private var newSubtask = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            field(loc("标题", "Title"), text: $title)
            field(loc("备注", "Note"), text: $note)
            field(loc("标签", "Tags"), text: $tags, placeholder: loc("逗号分隔，如 工作, 紧急", "comma-separated"))

            HStack(spacing: 10) {
                Toggle(isOn: $hasDue) {
                    Text(loc("截止时间", "Due")).font(WL.small).foregroundStyle(WL.textDim)
                }
                .toggleStyle(.wlCheckbox)
                if hasDue {
                    DatePicker("", selection: $due, displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                        .datePickerStyle(.field)
                        .font(WL.small)
                }
                Spacer()
            }

            HStack(spacing: 8) {
                Text(loc("重复", "Repeat")).font(WL.small).foregroundStyle(WL.textDim)
                    .frame(width: 44, alignment: .leading)
                WLSegmented(selection: $recurrence, options: [
                    WLOption(Recurrence.none, loc("不重复", "None")),
                    WLOption(Recurrence.daily, loc("每天", "Daily")),
                    WLOption(Recurrence.weekly, loc("每周", "Weekly")),
                    WLOption(Recurrence.monthly, loc("每月", "Monthly")),
                ], fill: false)
            }

            subtasksSection

            HStack {
                Spacer()
                BracketButton(loc("完成", "Done")) { commit(); onClose() }
            }
        }
        .padding(14)
        .wlCard()
        .padding(.horizontal, 12).padding(.top, 2).padding(.bottom, 8)
        .onAppear {
            title = todo.title
            note = todo.note
            tags = todo.tags.joined(separator: ", ")
            hasDue = todo.dueDate != nil
            due = todo.dueDate ?? Date()
            recurrence = todo.recurrence
        }
        // Persist as the user edits, so nothing is lost if they just collapse it.
        .onChange(of: title) { commit() }
        .onChange(of: note) { commit() }
        .onChange(of: tags) { commit() }
        .onChange(of: hasDue) { commit() }
        .onChange(of: due) { commit() }
        .onChange(of: recurrence) { commit() }
    }

    private var subtasksSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(todo.subtasks) { sub in
                HStack(spacing: 8) {
                    Button { store.toggleSubtask(sub.id, in: todo) } label: {
                        Image(systemName: sub.done ? "checkmark.circle.fill" : "circle").font(.system(size: 12))
                            .foregroundStyle(sub.done ? WL.green : WL.textDim)
                    }.buttonStyle(.wlPlain)
                    Text(sub.title).font(WL.small)
                        .foregroundStyle(sub.done ? WL.textDim : WL.textPrimary)
                        .strikethrough(sub.done, color: WL.textDim)
                    Spacer()
                    Button { removeSubtask(sub.id) } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .semibold))
                    }.buttonStyle(.wlIcon(tint: WL.red, size: 20))
                }
                .padding(.leading, 52)
            }
            HStack(spacing: 8) {
                Text(loc("子任务", "Subtasks")).font(WL.small).foregroundStyle(WL.textDim)
                    .frame(width: 44, alignment: .leading)
                TextField(loc("添加子任务…", "Add subtask…"), text: $newSubtask)
                    .onSubmit(addSubtask)
                    .wlField(font: WL.small)
            }
        }
    }

    private func addSubtask() {
        let t = newSubtask.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        var updated = todo
        updated.subtasks.append(Subtask(title: t))
        store.update(updated)
        newSubtask = ""
    }

    private func removeSubtask(_ id: UUID) {
        var updated = todo
        updated.subtasks.removeAll { $0.id == id }
        store.update(updated)
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String = "") -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label).font(WL.small).foregroundStyle(WL.textDim)
                .frame(width: 44, alignment: .leading)
            TextField(placeholder, text: text, axis: .vertical)
                .lineLimit(1...4)
                .wlField(font: WL.small, multiline: true)
        }
    }

    private func commit() {
        var t = todo
        t.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        t.note = note
        t.tags = tags.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        t.dueDate = hasDue ? due : nil
        t.recurrence = recurrence
        store.update(t)
    }
}
