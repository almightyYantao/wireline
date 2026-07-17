import SwiftUI

/// A single documented command: the keys plus what they do.
private struct VimCmd: Identifiable {
    let id = UUID()
    let keys: String
    let zh: String
    let en: String
}

private struct VimGroup: Identifiable {
    let id = UUID()
    let zh: String
    let en: String
    let cmds: [VimCmd]
}

/// Common vim commands, grouped. Deliberately compact — the essentials someone
/// needs when they've unexpectedly landed in vim over SSH.
private let vimGroups: [VimGroup] = [
    VimGroup(zh: "模式", en: "Modes", cmds: [
        VimCmd(keys: "i", zh: "光标前插入", en: "Insert before cursor"),
        VimCmd(keys: "a", zh: "光标后追加", en: "Append after cursor"),
        VimCmd(keys: "o", zh: "下方新开一行", en: "Open line below"),
        VimCmd(keys: "Esc", zh: "回到普通模式", en: "Back to normal mode"),
        VimCmd(keys: "v", zh: "可视选择", en: "Visual select"),
    ]),
    VimGroup(zh: "保存 / 退出", en: "Save / Quit", cmds: [
        VimCmd(keys: ":w", zh: "保存", en: "Save"),
        VimCmd(keys: ":q", zh: "退出", en: "Quit"),
        VimCmd(keys: ":wq", zh: "保存并退出", en: "Save & quit"),
        VimCmd(keys: ":q!", zh: "不保存强制退出", en: "Quit without saving"),
    ]),
    VimGroup(zh: "移动", en: "Move", cmds: [
        VimCmd(keys: "h j k l", zh: "左 下 上 右", en: "Left down up right"),
        VimCmd(keys: "w / b", zh: "下/上一个词", en: "Next / prev word"),
        VimCmd(keys: "0 / $", zh: "行首 / 行尾", en: "Line start / end"),
        VimCmd(keys: "gg / G", zh: "文件首 / 尾", en: "File top / bottom"),
        VimCmd(keys: ":n", zh: "跳到第 n 行", en: "Go to line n"),
    ]),
    VimGroup(zh: "编辑", en: "Edit", cmds: [
        VimCmd(keys: "x", zh: "删除字符", en: "Delete char"),
        VimCmd(keys: "dd", zh: "删除整行", en: "Delete line"),
        VimCmd(keys: "yy / p", zh: "复制行 / 粘贴", en: "Yank line / paste"),
        VimCmd(keys: "u", zh: "撤销", en: "Undo"),
        VimCmd(keys: "Ctrl-r", zh: "重做", en: "Redo"),
    ]),
    VimGroup(zh: "搜索 / 替换", en: "Search / Replace", cmds: [
        VimCmd(keys: "/text", zh: "向下搜索", en: "Search forward"),
        VimCmd(keys: "n / N", zh: "下/上一个匹配", en: "Next / prev match"),
        VimCmd(keys: ":%s/a/b/g", zh: "全局替换 a→b", en: "Replace a→b globally"),
    ]),
]

/// The cheat-sheet overlay shown while vim runs in the terminal. Closing it
/// remembers the choice (persisted); once collapsed only a small floating icon
/// remains, which reopens the panel on tap.
struct VimHintView: View {
    @Environment(Localizer.self) private var loc
    @AppStorage("vimHintCollapsed") private var collapsed = false

    var body: some View {
        Group {
            if collapsed {
                icon
            } else {
                panel
            }
        }
        .padding(12)
        .animation(.easeInOut(duration: 0.18), value: collapsed)
    }

    private var icon: some View {
        Button { collapsed = false } label: {
            Image(systemName: "text.book.closed.fill")
                .font(.system(size: 14))
                .foregroundStyle(WL.green)
                .frame(width: 34, height: 34)
                .background(WL.surface.opacity(0.9), in: RoundedRectangle(cornerRadius: WL.radius(8)))
                .overlay(RoundedRectangle(cornerRadius: WL.radius(8)).stroke(WL.green.opacity(0.5), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(loc("Vim 速查表", "Vim cheat sheet"))
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(loc("VIM 速查表", "VIM CHEAT SHEET"))
                    .font(WL.small.weight(.semibold)).foregroundStyle(WL.green)
                Spacer()
                Button { collapsed = true } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                        .foregroundStyle(WL.textDim)
                }
                .buttonStyle(.plain)
                .help(loc("收起为浮窗图标", "Collapse to a floating icon"))
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            Rectangle().fill(WL.border).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(vimGroups) { group in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(loc(group.zh, group.en))
                                .font(WL.caption.weight(.semibold))
                                .foregroundStyle(WL.textDim).textCase(.uppercase)
                            ForEach(group.cmds) { cmd in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(cmd.keys)
                                        .font(WL.mono(11, .medium)).foregroundStyle(WL.green)
                                        .frame(width: 78, alignment: .leading)
                                    Text(loc(cmd.zh, cmd.en))
                                        .font(WL.caption).foregroundStyle(WL.textPrimary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
                .padding(12)
            }
        }
        .frame(width: 232)
        .frame(maxHeight: 460)
        .background(WL.bg.opacity(0.92), in: RoundedRectangle(cornerRadius: WL.radius(10)))
        .overlay(RoundedRectangle(cornerRadius: WL.radius(10)).stroke(WL.border, lineWidth: WL.borderWidth))
        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
    }
}
