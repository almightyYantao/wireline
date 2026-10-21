import SwiftUI

/// Management UI for ops skills: toggle built-ins, view their steps, add/edit
/// custom skills. Presented as a sheet from Settings → AI.
struct SkillSettingsView: View {
    @Environment(Localizer.self) private var loc
    @State private var store = SkillStore.shared
    @State private var editing: WLSkill?
    var onClose: () -> Void = {}

    var body: some View {
        WLSheet(loc("运维技能", "Ops Skills"),
                subtitle: loc("AI 按需载入的运维流程", "Ops playbooks the AI loads on demand"),
                symbol: "book.pages", width: 560, height: 580,
                onClose: onClose) {
            WLFormSection(loc("技能", "Skills"),
                          footer: loc("技能是策展好的运维流程。AI 会按需载入某个技能的详细步骤，多为只读排查；涉及更改仍走确认。",
                                      "Skills are curated ops playbooks. The AI loads a skill's steps on demand — mostly read-only investigation; changes still require confirmation.")) {
                ForEach(Array(store.skills.enumerated()), id: \.element.id) { i, s in
                    if i > 0 { WLFormDivider() }
                    skillRow(s)
                }
            }
        } footer: {
            Button {
                editing = WLSkill(id: "custom-\(UUID().uuidString.prefix(6))", name: "", description: "", body: "", builtin: false, enabled: true)
            } label: {
                Label(loc("添加自定义技能", "Add Custom Skill"), systemImage: "plus")
            }
            .buttonStyle(.wlSecondary)
            Spacer()
            Button(loc("完成", "Done")) { onClose() }
                .buttonStyle(.wlPrimary).keyboardShortcut(.defaultAction)
        }
        .sheet(item: $editing) { s in
            SkillEditor(skill: s) { saved in store.upsert(saved); editing = nil } onCancel: { editing = nil }
                .environment(loc)
        }
    }

    private func skillRow(_ s: WLSkill) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(get: { s.enabled }, set: { store.setEnabled($0, id: s.id) }))
                    .toggleStyle(.wlCheckbox).labelsHidden()
                Text(s.name.isEmpty ? s.id : s.name).font(WL.body.weight(.semibold)).foregroundStyle(WL.textPrimary)
                if s.builtin { Text(loc("内置", "built-in")).font(WL.caption).foregroundStyle(WL.textDim) }
                Spacer()
                Text(s.id).font(WL.mono(10)).foregroundStyle(WL.textDim)
            }
            Text(s.description).font(WL.caption).foregroundStyle(WL.textDim)
            DisclosureGroup {
                Text(s.body).font(WL.mono(11)).foregroundStyle(WL.textDim)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4).textSelection(.enabled)
            } label: {
                Text(loc("查看步骤", "View steps")).font(WL.caption).foregroundStyle(WL.green)
            }.tint(WL.green)
            HStack(spacing: 14) {
                if !s.builtin {
                    Button(loc("编辑", "Edit")) { editing = s }
                    Button(loc("删除", "Delete"), role: .destructive) { store.remove(s) }
                }
                Spacer()
            }.font(WL.caption).buttonStyle(.wlPlain).foregroundStyle(WL.green)
        }
        .padding(.vertical, 10)
    }
}

/// Add/edit a custom skill.
private struct SkillEditor: View {
    @Environment(Localizer.self) private var loc
    @State var skill: WLSkill
    var onSave: (WLSkill) -> Void
    var onCancel: () -> Void

    var body: some View {
        WLSheet(skill.name.isEmpty ? loc("自定义技能", "Custom Skill") : skill.name,
                subtitle: loc("写清楚何时使用、按什么步骤排查", "Say when to use it and which steps to follow"),
                symbol: "square.and.pencil", width: 540, height: 560, onClose: onCancel) {
            WLFormSection(loc("基本", "General")) {
                stacked(loc("名称", "Name")) { field("重启前健康检查", $skill.name) }
                WLFormDivider()
                stacked(loc("id（唯一，字母数字/连字符）", "id (unique, kebab-case)")) { field("pre-restart-check", $skill.id) }
                WLFormDivider()
                stacked(loc("一句话说明（决定 AI 何时调用）", "One-line description (when the AI should use it)")) {
                    field("重启服务前的健康快检", $skill.description)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(loc("步骤 / 指令", "Steps / instructions")).font(WL.small).foregroundStyle(WL.textDim)
                    .padding(.leading, 4)
                TextEditor(text: $skill.body)
                    .textEditorStyle(.plain).scrollContentBackground(.hidden)
                    .frame(height: 200)
                    .wlField()
            }
        } footer: {
            Spacer()
            Button(loc("取消", "Cancel")) { onCancel() }
                .buttonStyle(.wlSecondary).keyboardShortcut(.cancelAction)
            // ⌘↩ rather than ↩: Return has to insert newlines in the steps editor.
            Button(loc("保存", "Save")) { onSave(skill) }
                .buttonStyle(.wlPrimary).keyboardShortcut(.return, modifiers: .command)
                .disabled(skill.id.trimmingCharacters(in: .whitespaces).isEmpty
                          || skill.name.trimmingCharacters(in: .whitespaces).isEmpty
                          || skill.body.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    /// Label above a full-width field.
    private func stacked<V: View>(_ label: String, @ViewBuilder _ content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(WL.small).foregroundStyle(WL.textDim)
            content()
        }
        .padding(.vertical, 10)
    }

    private func field(_ prompt: String, _ text: Binding<String>) -> some View {
        TextField("", text: text, prompt: Text(prompt).foregroundStyle(WL.textDim))
            .wlField()
    }
}
