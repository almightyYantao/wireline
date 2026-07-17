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
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(loc("快捷指令", "Snippets"))
                    .font(WL.body.weight(.semibold)).foregroundStyle(WL.green)
                Spacer()
                BracketButton(loc("新建", "New")) { openEditor(nil) }
            }
            .padding(.horizontal, 20).padding(.top, 22).padding(.bottom, 14)
            Rectangle().fill(WL.border).frame(height: 1)

            if let snippet = filling {
                fillForm(snippet)
            } else if isEditorOpen {
                editorForm
            } else {
                list
            }
        }
        .frame(width: 460, height: 480)
        .background(WL.bg)
        .preferredColorScheme(.dark)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(store.snippets) { snippet in
                    SnippetRow(snippet: snippet,
                               onRun: { run(snippet) },
                               onEdit: { openEditor(snippet) },
                               onDelete: { store.remove(snippet) })
                    Rectangle().fill(WL.border.opacity(0.5)).frame(height: 1)
                }
                if store.snippets.isEmpty {
                    Text(loc("暂无片段，点「新建」添加。", "No snippets yet — tap New."))
                        .font(WL.small).foregroundStyle(WL.textDim)
                        .padding(20)
                }
            }
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
        VStack(alignment: .leading, spacing: 14) {
            Text(loc("填写参数", "Fill in parameters"))
                .font(WL.small).foregroundStyle(WL.textDim)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(names, id: \.self) { name in
                        field(name) {
                            multilineInput(Binding(
                                get: { fillValues[name] ?? "" },
                                set: { fillValues[name] = $0 }
                            ), height: 60)
                        }
                    }
                }
            }
            Text(snippet.filled(with: fillValues))
                .font(WL.mono(11)).foregroundStyle(WL.green.opacity(0.8))
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(WL.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: WL.radius(5)))
                .textSelection(.enabled)
            HStack(spacing: 18) {
                Spacer()
                BracketButton(loc("取消", "Cancel")) { filling = nil }
                Button {
                    onRun(snippet.filled(with: fillValues)); dismiss()
                } label: {
                    Text("[\(loc("运行", "Run"))]").font(WL.small).foregroundStyle(WL.green)
                }.buttonStyle(.plain)
            }
        }
        .padding(20)
    }

    private var editorForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            field(loc("名称", "Name")) {
                input(loc("如 查看磁盘", "e.g. Disk usage"), $draftName)
            }
            field(loc("命令（可多行）", "Command (multi-line)")) {
                multilineInput($draftCommand)
            }
            Text(loc("每行一条命令，按顺序执行。用 {{参数名}} 作为占位符，运行时会弹窗让你填写。",
                     "One command per line, run in order. Use {{name}} as a placeholder — you'll be prompted to fill it in."))
                .font(WL.caption).foregroundStyle(WL.textDim)
            Spacer()
            HStack(spacing: 18) {
                Spacer()
                BracketButton(loc("取消", "Cancel")) { isEditorOpen = false }
                Button(action: saveDraft) {
                    Text("[\(loc("保存", "Save"))]").font(WL.small)
                        .foregroundStyle(canSave ? WL.green : WL.textDim)
                }.buttonStyle(.plain).disabled(!canSave)
            }
        }
        .padding(20)
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

    private func field<V: View>(_ label: String, @ViewBuilder _ content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(WL.small).foregroundStyle(WL.textDim)
            content()
        }
    }

    private func input(_ prompt: String, _ text: Binding<String>) -> some View {
        TextField("", text: text, prompt: Text(prompt).foregroundStyle(WL.textDim))
            .textFieldStyle(.plain).font(WL.body).foregroundStyle(WL.textPrimary)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(WL.surface, in: RoundedRectangle(cornerRadius: WL.radius(5)))
            .overlay(RoundedRectangle(cornerRadius: WL.radius(5)).stroke(WL.border, lineWidth: WL.borderWidth))
    }

    private func multilineInput(_ text: Binding<String>, height: CGFloat = 130) -> some View {
        TextEditor(text: text)
            .textEditorStyle(.plain)
            .font(WL.mono(12))
            .foregroundStyle(WL.textPrimary)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 6).padding(.vertical, 5)
            .frame(height: height)
            .background(WL.surface, in: RoundedRectangle(cornerRadius: WL.radius(5)))
            .overlay(RoundedRectangle(cornerRadius: WL.radius(5)).stroke(WL.border, lineWidth: WL.borderWidth))
    }
}

private struct SnippetRow: View {
    let snippet: Snippet
    var onRun: () -> Void
    var onEdit: () -> Void
    var onDelete: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "bolt.fill").font(.system(size: 10)).foregroundStyle(WL.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(snippet.name).font(WL.body).foregroundStyle(WL.textPrimary)
                Text(snippet.command).font(WL.caption).foregroundStyle(WL.textDim).lineLimit(1)
            }
            Spacer()
            if hover {
                BracketButton("✎") { onEdit() }
                BracketButton("×") { onDelete() }
            }
            BracketButton("▸") { onRun() }
        }
        .padding(.horizontal, 18).padding(.vertical, 9)
        .background(hover ? WL.surface : .clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: onRun)   // single click runs immediately
    }
}
