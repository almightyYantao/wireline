import SwiftUI
import WirelineCore

/// A library of command snippets: click one to run it in the active terminal,
/// or manage (add / edit / delete) them.
struct SnippetsSheet: View {
    @Environment(SnippetStore.self) private var store
    @Environment(Localizer.self) private var loc
    @Environment(\.dismiss) private var dismiss
    /// Called with the chosen command to run in the active session.
    var onRun: (String) -> Void

    @State private var editing: Snippet?
    @State private var draftName = ""
    @State private var draftCommand = ""
    @State private var isEditorOpen = false
    /// The snippet awaiting placeholder input, plus the values typed so far.
    @State private var filling: Snippet?
    @State private var fillValues: [String: String] = [:]

    var body: some View {
        WLSheet(sheetTitle, subtitle: sheetSubtitle, symbol: sheetSymbol,
                width: 460, height: 480, onClose: { dismiss() }) {
            if let snippet = filling {
                fillForm(snippet)
            } else if isEditorOpen {
                editorForm
            } else {
                list
            }
        } footer: {
            if let snippet = filling {
                Spacer()
                Button(loc("取消", "Cancel")) { filling = nil }
                    .buttonStyle(.wlSecondary).keyboardShortcut(.cancelAction)
                // ⌘↩ rather than ↩: Return has to insert newlines in the fields.
                Button(loc("运行", "Run")) { onRun(snippet.filled(with: fillValues)); dismiss() }
                    .buttonStyle(.wlPrimary).keyboardShortcut(.return, modifiers: .command)
            } else if isEditorOpen {
                Spacer()
                Button(loc("取消", "Cancel")) { isEditorOpen = false }
                    .buttonStyle(.wlSecondary).keyboardShortcut(.cancelAction)
                Button(loc("保存", "Save"), action: saveDraft)
                    .buttonStyle(.wlPrimary).keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canSave)
            } else {
                Spacer()
                Button(loc("关闭", "Close")) { dismiss() }
                    .buttonStyle(.wlSecondary).keyboardShortcut(.cancelAction)
                Button(loc("新建", "New")) { openEditor(nil) }
                    .buttonStyle(.wlPrimary).keyboardShortcut(.defaultAction)
            }
        }
    }

    private var sheetTitle: String {
        if filling != nil { return loc("填写参数", "Fill in parameters") }
        if isEditorOpen { return editing == nil ? loc("新建片段", "New Snippet") : loc("编辑片段", "Edit Snippet") }
        return loc("快捷指令", "Snippets")
    }

    private var sheetSubtitle: String {
        if let filling { return filling.name }
        if isEditorOpen { return loc("一行一条命令，按顺序执行", "One command per line, run in order") }
        return loc("点击即在当前终端运行", "Click one to run it in the active terminal")
    }

    private var sheetSymbol: String {
        if filling != nil { return "text.cursor" }
        if isEditorOpen { return "square.and.pencil" }
        return "bolt"
    }

    @ViewBuilder
    private var list: some View {
        if store.snippets.isEmpty {
            Text(loc("暂无片段，点「新建」添加。", "No snippets yet — tap New."))
                .font(WL.small).foregroundStyle(WL.textDim)
                .frame(maxWidth: .infinity).padding(.vertical, 30)
        } else {
            LazyVStack(spacing: 2) {
                ForEach(store.snippets) { snippet in
                    SnippetRow(snippet: snippet,
                               onRun: { run(snippet) },
                               onEdit: { openEditor(snippet) },
                               onDelete: { store.remove(snippet) })
                }
            }
            .padding(4)
            .wlCard()
        }
    }

    /// Run a snippet — straight through if it has no placeholders, otherwise open
    /// the fill-in form first.
    private func run(_ snippet: Snippet) {
        let names = snippet.placeholders
        if names.isEmpty {
            onRun(snippet.command); dismiss()
        } else {
            fillValues = Dictionary(uniqueKeysWithValues: names.map { ($0, "") })
            filling = snippet
        }
    }

    @ViewBuilder
    private func fillForm(_ snippet: Snippet) -> some View {
        let names = snippet.placeholders
        WLFormSection(loc("参数", "Parameters")) {
            ForEach(Array(names.enumerated()), id: \.element) { i, name in
                if i > 0 { WLFormDivider() }
                stacked(name) {
                    multilineInput(Binding(
                        get: { fillValues[name] ?? "" },
                        set: { fillValues[name] = $0 }
                    ), height: 60)
                }
            }
        }
        WLFormSection(loc("预览", "Preview")) {
            Text(snippet.filled(with: fillValues))
                .font(WL.mono(11)).foregroundStyle(WL.green.opacity(0.8))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
                .textSelection(.enabled)
        }
    }

    private var editorForm: some View {
        WLFormSection("", footer: loc("每行一条命令，按顺序执行。用 «参数名» 作为占位符，运行时会弹窗让你填写（{{}} 留给 Go 模板，如 docker --format）。",
                                      "One command per line, run in order. Use «name» as a placeholder — you'll be prompted to fill it in ({{}} is left to Go templates, e.g. docker --format).")) {
            stacked(loc("名称", "Name")) {
                input(loc("如 查看磁盘", "e.g. Disk usage"), $draftName)
            }
            WLFormDivider()
            stacked(loc("命令（可多行）", "Command (multi-line)")) {
                multilineInput($draftCommand)
            }
        }
    }

    private var canSave: Bool {
        !draftName.trimmingCharacters(in: .whitespaces).isEmpty
            && !draftCommand.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func openEditor(_ snippet: Snippet?) {
        editing = snippet
        draftName = snippet?.name ?? ""
        draftCommand = snippet?.command ?? ""
        isEditorOpen = true
    }

    private func saveDraft() {
        if var s = editing {
            s.name = draftName; s.command = draftCommand
            store.update(s)
        } else {
            store.add(Snippet(name: draftName, command: draftCommand))
        }
        isEditorOpen = false
    }

    /// Label above a full-width field.
    private func stacked<V: View>(_ label: String, @ViewBuilder _ content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(WL.small).foregroundStyle(WL.textDim)
            content()
        }
        .padding(.vertical, 10)
    }

    private func input(_ prompt: String, _ text: Binding<String>) -> some View {
        TextField("", text: text, prompt: Text(prompt).foregroundStyle(WL.textDim))
            .wlField(font: WL.body)
    }

    private func multilineInput(_ text: Binding<String>, height: CGFloat = 130) -> some View {
        TextEditor(text: text)
            .textEditorStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(height: height)
            .wlField(multiline: true)
    }
}

private struct SnippetRow: View {
    @Environment(Localizer.self) private var loc
    let snippet: Snippet
    var onRun: () -> Void
    var onEdit: () -> Void
    var onDelete: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "bolt.fill").font(.system(size: 10)).foregroundStyle(WL.green)
                .frame(width: 22, height: 22)
                .background(WL.green.opacity(0.1), in: RoundedRectangle(cornerRadius: WL.radius(7), style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(snippet.name).font(WL.body).foregroundStyle(WL.textPrimary).lineLimit(1)
                Text(snippet.command).font(WL.caption).foregroundStyle(WL.textDim).lineLimit(1)
            }
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                Button(action: onEdit) { Image(systemName: "pencil").font(.system(size: 11, weight: .medium)) }
                    .buttonStyle(.wlIcon).help(loc("编辑", "Edit"))
                Button(action: onDelete) { Image(systemName: "trash").font(.system(size: 11, weight: .medium)) }
                    .buttonStyle(.wlIcon(tint: WL.red)).help(loc("删除", "Delete"))
            }
            .opacity(hover ? 1 : 0)
            .allowsHitTesting(hover)
            Button(action: onRun) { Image(systemName: "play.fill").font(.system(size: 10)) }
                .buttonStyle(.wlIcon(tint: hover ? WL.green : nil))
                .help(loc("在当前终端运行", "Run in the active terminal"))
        }
        .wlRowHighlight(hover: hover)
        .wlHover($hover)
        .onTapGesture(perform: onRun)   // single click runs immediately
    }
}
