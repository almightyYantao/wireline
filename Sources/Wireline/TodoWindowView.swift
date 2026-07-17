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
            Rectangle().fill(WL.border).frame(height: 1)
            inputRow
            Rectangle().fill(WL.border).frame(height: 1)
            if !store.todos.isEmpty { filterBar }
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
            Text(loc("待办", "TODO")).font(WL.body.weight(.semibold)).foregroundStyle(WL.green)
            Text("[\(store.activeCount)]").font(WL.small).foregroundStyle(WL.textDim)
            Spacer()
            ForEach(TodoFilter.allCases, id: \.self) { f in
                Button { filter = f } label: {
                    Text(f.title(loc)).font(WL.small)
                        .foregroundStyle(filter == f ? WL.greenBright : WL.textDim)
                }
                .buttonStyle(.plain)
            }
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
            Text(aiBusy ? loc("AI…", "AI…") : "AI ▾").font(WL.small).foregroundStyle(WL.purple)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(aiBusy)
    }

    private var filterBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(WL.small).foregroundStyle(WL.textDim)
                TextField(loc("搜索…", "Search…"), text: $search)
                    .textFieldStyle(.plain).font(WL.small).foregroundStyle(WL.textPrimary)
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(WL.small).foregroundStyle(WL.textDim)
                    }.buttonStyle(.plain)
                }
            }
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
        .padding(.horizontal, 18).padding(.vertical, 8)
        .background(WL.surface.opacity(0.25))
    }

    private func tagChip(_ text: String, active: Bool, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            Text(text).font(WL.caption)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(active ? WL.green.opacity(0.2) : WL.surface.opacity(0.6), in: Capsule())
                .foregroundStyle(active ? WL.greenBright : WL.textDim)
                .overlay(Capsule().stroke(active ? WL.green.opacity(0.5) : WL.border, lineWidth: WL.borderWidth))
        }
        .buttonStyle(.plain)
    }

    private var inputRow: some View {
        HStack(spacing: 8) {
            Text(smartAdd ? "✨" : ">").font(WL.body).foregroundStyle(smartAdd ? WL.purple : WL.green)
            TextField(smartAdd ? loc("如：明天下午3点交周报", "e.g. submit report tomorrow 3pm")
                               : loc("添加一条待办…", "Add a to-do…"), text: $draft)
                .textFieldStyle(.plain)
                .font(WL.body)
                .foregroundStyle(WL.textPrimary)
                .focused($inputFocused)
                .onSubmit(commit)
            BracketButton(loc("添加", "Add"), action: commit)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
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
                        Rectangle().fill(WL.border.opacity(0.4)).frame(height: 1)
                            .padding(.leading, 18)
                    }
                }
            }
            .padding(.vertical, 4)
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
        VStack(alignment: .leading, spacing: 14) {
            Text(r.title).font(WL.body.weight(.semibold)).foregroundStyle(WL.purple)
            ScrollView {
                Text(r.body.isEmpty ? loc("(AI 没有返回内容)", "(no response)") : r.body)
                    .font(WL.small).foregroundStyle(WL.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            HStack {
                Spacer()
                BracketButton(loc("关闭", "Close")) { recap = nil }
            }
        }
        .padding(20).frame(width: 460, height: 360)
        .background(WL.bg).preferredColorScheme(.dark)
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

/// One row: bracketed checkbox, star, title (struck through when done), a due-date
/// badge, and a delete affordance on hover.
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
                Text(todo.done ? "[✓]" : "[ ]")
                    .font(WL.body)
                    .foregroundStyle(todo.done ? WL.green : WL.textDim)
            }
            .buttonStyle(.plain)

            Button {
                var t = todo; t.priority.toggle(); store.update(t)
            } label: {
                Text(todo.priority ? "★" : "☆")
                    .font(WL.body)
                    .foregroundStyle(todo.priority ? WL.amber : WL.textDim.opacity(0.6))
            }
            .buttonStyle(.plain)

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
                    Text(loc("编辑", "edit")).font(WL.caption).foregroundStyle(WL.textDim)
                }
                .buttonStyle(.plain)
                Button { store.remove(todo) } label: {
                    Text("✕").font(WL.small).foregroundStyle(WL.red)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 9)
        .background(rowBackground)
        .overlay(alignment: .leading) {
            if selected { Rectangle().fill(WL.green).frame(width: 2) }
        }
        .onHover { hover = $0 }
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
        if hover || expanded { return WL.surface.opacity(0.6) }
        return .clear
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
                .toggleStyle(.checkbox)
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
                Picker("", selection: $recurrence) {
                    Text(loc("不重复", "None")).tag(Recurrence.none)
                    Text(loc("每天", "Daily")).tag(Recurrence.daily)
                    Text(loc("每周", "Weekly")).tag(Recurrence.weekly)
                    Text(loc("每月", "Monthly")).tag(Recurrence.monthly)
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
            }

            subtasksSection

            HStack {
                Spacer()
                BracketButton(loc("完成", "Done")) { commit(); onClose() }
            }
        }
        .padding(.horizontal, 18).padding(.top, 4).padding(.bottom, 14)
        .background(WL.surface.opacity(0.35))
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
                        Text(sub.done ? "[✓]" : "[ ]").font(WL.small)
                            .foregroundStyle(sub.done ? WL.green : WL.textDim)
                    }.buttonStyle(.plain)
                    Text(sub.title).font(WL.small)
                        .foregroundStyle(sub.done ? WL.textDim : WL.textPrimary)
                        .strikethrough(sub.done, color: WL.textDim)
                    Spacer()
                    Button { removeSubtask(sub.id) } label: {
                        Text("✕").font(WL.caption).foregroundStyle(WL.red)
                    }.buttonStyle(.plain)
                }
                .padding(.leading, 52)
            }
            HStack(spacing: 8) {
                Text(loc("子任务", "Subtasks")).font(WL.small).foregroundStyle(WL.textDim)
                    .frame(width: 44, alignment: .leading)
                TextField(loc("添加子任务…", "Add subtask…"), text: $newSubtask)
                    .textFieldStyle(.plain).font(WL.small).foregroundStyle(WL.textPrimary)
                    .onSubmit(addSubtask)
                    .padding(6)
                    .background(WL.bg.opacity(0.6), in: RoundedRectangle(cornerRadius: WL.radius(5)))
                    .overlay(RoundedRectangle(cornerRadius: WL.radius(5)).stroke(WL.border, lineWidth: WL.borderWidth))
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
                .textFieldStyle(.plain)
                .font(WL.small).foregroundStyle(WL.textPrimary)
                .lineLimit(1...4)
                .padding(6)
                .background(WL.bg.opacity(0.6), in: RoundedRectangle(cornerRadius: WL.radius(5)))
                .overlay(RoundedRectangle(cornerRadius: WL.radius(5)).stroke(WL.border, lineWidth: WL.borderWidth))
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
