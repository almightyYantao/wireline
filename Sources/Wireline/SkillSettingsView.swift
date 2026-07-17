import SwiftUI

/// Management UI for ops skills: toggle built-ins, view their steps, add/edit
/// custom skills. Presented as a sheet from Settings → AI.
struct SkillSettingsView: View {
    @Environment(Localizer.self) private var loc
    @State private var store = SkillStore.shared
    @State private var editing: WLSkill?
    var onClose: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(WL.border).frame(height: 1)
            content
        }
        .frame(width: 560, height: 580)
        .background(WL.bg)
        .preferredColorScheme(.dark)
        .sheet(item: $editing) { s in
            SkillEditor(skill: s) { saved in store.upsert(saved); editing = nil } onCancel: { editing = nil }
                .environment(loc)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("> ops skills").font(WL.mono(15, .bold)).foregroundStyle(WL.green)
            Spacer()
            Button(loc("完成", "Done")) { onClose() }.buttonStyle(.plain)
                .font(WL.small).foregroundStyle(WL.green)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(loc("技能是策展好的运维流程。AI 会按需载入某个技能的详细步骤，多为只读排查；涉及更改仍走确认。",
                         "Skills are curated ops playbooks. The AI loads a skill's steps on demand — mostly read-only investigation; changes still require confirmation."))
                    .font(WL.caption).foregroundStyle(WL.textDim)

                ForEach(store.skills) { s in skillRow(s) }

                Button {
                    editing = WLSkill(id: "custom-\(UUID().uuidString.prefix(6))", name: "", description: "", body: "", builtin: false, enabled: true)
                } label: {
                    Label(loc("添加自定义技能", "Add Custom Skill"), systemImage: "plus")
                        .font(WL.small).foregroundStyle(WL.green)
                }
                .buttonStyle(.plain).padding(.top, 4)
            }
            .padding(18)
        }
    }

    private func skillRow(_ s: WLSkill) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(get: { s.enabled }, set: { store.setEnabled($0, id: s.id) }))
                    .toggleStyle(.checkbox).tint(WL.green).labelsHidden()
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
            }.font(WL.caption).buttonStyle(.plain).foregroundStyle(WL.green)
        }
        .padding(12)
        .background(WL.surface, in: RoundedRectangle(cornerRadius: WL.radius(7)))
        .overlay(RoundedRectangle(cornerRadius: WL.radius(7)).stroke(WL.border, lineWidth: WL.borderWidth))
    }
}

/// Add/edit a custom skill.
private struct SkillEditor: View {
    @Environment(Localizer.self) private var loc
    @State var skill: WLSkill
    var onSave: (WLSkill) -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("> skill").font(WL.mono(14, .bold)).foregroundStyle(WL.green); Spacer() }
                .padding(.horizontal, 18).padding(.vertical, 14)
            Rectangle().fill(WL.border).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    field(loc("名称", "Name"), "重启前健康检查", $skill.name)
                    field(loc("id（唯一，字母数字/连字符）", "id (unique, kebab-case)"), "pre-restart-check", $skill.id)
                    field(loc("一句话说明（决定 AI 何时调用）", "One-line description (when the AI should use it)"), "重启服务前的健康快检", $skill.description)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(loc("步骤 / 指令", "Steps / instructions")).font(WL.small).foregroundStyle(WL.textDim)
                        TextEditor(text: $skill.body)
                            .font(WL.mono(12)).foregroundStyle(WL.textPrimary).scrollContentBackground(.hidden)
                            .frame(height: 200).padding(8)
                            .background(WL.surface, in: RoundedRectangle(cornerRadius: WL.radius(5)))
                            .overlay(RoundedRectangle(cornerRadius: WL.radius(5)).stroke(WL.border, lineWidth: WL.borderWidth))
                    }
                }.padding(18)
            }
            Rectangle().fill(WL.border).frame(height: 1)
            HStack {
                Spacer()
                Button(loc("取消", "Cancel")) { onCancel() }.buttonStyle(.plain).foregroundStyle(WL.textDim)
                Button(loc("保存", "Save")) { onSave(skill) }.buttonStyle(.plain).foregroundStyle(WL.green)
                    .disabled(skill.id.trimmingCharacters(in: .whitespaces).isEmpty
                              || skill.name.trimmingCharacters(in: .whitespaces).isEmpty
                              || skill.body.trimmingCharacters(in: .whitespaces).isEmpty)
            }.font(WL.small).padding(.horizontal, 18).padding(.vertical, 12)
        }
        .frame(width: 540, height: 520)
        .background(WL.bg)
    }

    private func field(_ label: String, _ prompt: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(WL.small).foregroundStyle(WL.textDim)
            TextField("", text: text, prompt: Text(prompt).foregroundStyle(WL.textDim))
                .textFieldStyle(.plain).font(WL.mono(12)).foregroundStyle(WL.textPrimary)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(WL.surface, in: RoundedRectangle(cornerRadius: WL.radius(5)))
                .overlay(RoundedRectangle(cornerRadius: WL.radius(5)).stroke(WL.border, lineWidth: WL.borderWidth))
        }
    }
}
