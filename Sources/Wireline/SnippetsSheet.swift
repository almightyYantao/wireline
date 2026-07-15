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

            if isEditorOpen {
                editorForm
            } else {
                list
            }
        }
        .frame(width: 460, height: 420)
        .background(WL.bg)
        .preferredColorScheme(.dark)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(store.snippets) { snippet in
                    SnippetRow(snippet: snippet,
                               onRun: { onRun(snippet.command); dismiss() },
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

    private var editorForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            field(loc("名称", "Name")) {
                input(loc("如 查看磁盘", "e.g. Disk usage"), $draftName)
            }
            field(loc("命令", "Command")) {
                input("df -h", $draftCommand)
            }
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
            .background(WL.surface, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(WL.border, lineWidth: 1))
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
