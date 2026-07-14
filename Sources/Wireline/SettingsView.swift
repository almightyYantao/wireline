import SwiftUI
import AppKit
import UniformTypeIdentifiers
import WirelineCore

struct SettingsView: View {
    @Environment(HostStore.self) private var store
    @Environment(Localizer.self) private var loc

    var body: some View {
        @Bindable var store = store
        @Bindable var loc = loc
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                section(loc("语言 / Language", "Language")) {
                    Picker("", selection: $loc.language) {
                        ForEach(AppLanguage.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }.labelsHidden().pickerStyle(.segmented)
                }

                section(loc("终端", "Terminal")) {
                    Toggle(isOn: $store.useBuiltInTerminal) {
                        Text(loc("使用内置终端", "Use built-in terminal")).font(WL.body).foregroundStyle(WL.textPrimary)
                    }.toggleStyle(.checkbox).tint(WL.green)
                    hint(loc("内置会话在应用内真实 PTY 中运行，启动登录 shell，prompt/主题/配色与平时终端一致。",
                            "Built-in sessions run in a real PTY, launching your login shell so prompt, theme, and colors match your normal terminal."))
                    row(loc("否则打开于", "Otherwise open in")) {
                        Picker("", selection: $store.terminalApp) {
                            ForEach(TerminalApp.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }.labelsHidden().disabled(store.useBuiltInTerminal).fixedSize()
                    }
                }

                section(loc("终端配色", "Terminal Colors")) {
                    row(loc("配色方案", "Color scheme")) {
                        Text(store.terminalTheme?.name ?? loc("Wireline (默认)", "Wireline (default)"))
                            .font(WL.small).foregroundStyle(WL.textDim).lineLimit(1)
                        BracketButton(loc("导入 iTerm2…", "Import iTerm2…")) { importTheme() }
                        if store.terminalTheme != nil { BracketButton(loc("默认", "Default")) { store.terminalTheme = nil } }
                    }
                    hint(loc("支持 iTerm2 的 .itermcolors 主题（iterm2-color-schemes 有数百个）。",
                            "Supports iTerm2 .itermcolors themes (hundreds in iterm2-color-schemes)."))
                }

                section(loc("终端字体", "Terminal Font")) {
                    row(loc("字体", "Font")) {
                        Picker("", selection: $store.terminalFontName) {
                            Text(loc("自动 (Nerd Font)", "Auto (Nerd Font)")).tag(String?.none)
                            ForEach(Self.monoFamilies, id: \.self) { Text($0).tag(String?.some($0)) }
                        }.labelsHidden().fixedSize()
                    }
                    row(loc("字号", "Size")) {
                        Stepper(value: $store.terminalFontSize, in: 9...24, step: 1) {
                            Text("\(Int(store.terminalFontSize))").font(WL.body).foregroundStyle(WL.textPrimary)
                        }.fixedSize()
                    }
                }

                section(loc("终端背景", "Terminal Background")) {
                    row(loc("不透明度", "Opacity")) {
                        Slider(value: $store.terminalOpacity, in: 0.2...1.0).frame(width: 160).tint(WL.green)
                        Text(String(format: "%.0f%%", store.terminalOpacity * 100))
                            .font(WL.small).monospacedDigit().foregroundStyle(WL.textDim)
                    }
                    row(loc("背景图片", "Background image")) {
                        Text(store.terminalBgImagePath.map { ($0 as NSString).lastPathComponent } ?? loc("无", "None"))
                            .font(WL.small).foregroundStyle(WL.textDim).lineLimit(1)
                        BracketButton(loc("选择…", "Choose…")) { pickImage() }
                        if store.terminalBgImagePath != nil { BracketButton(loc("清除", "Clear")) { store.terminalBgImagePath = nil } }
                    }
                }

                section(loc("连通性", "Connectivity")) {
                    Toggle(isOn: $store.autoCheckOnLaunch) {
                        Text(loc("启动时检测所有主机", "Check all hosts on launch")).font(WL.body).foregroundStyle(WL.textPrimary)
                    }.toggleStyle(.checkbox).tint(WL.green)
                }

                section(loc("配置文件", "Config File")) {
                    Text(store.repository.url.path).font(WL.small).foregroundStyle(WL.textDim).textSelection(.enabled)
                    hint(loc("Wireline 直接读写这份标准 OpenSSH 配置；卸载后它在命令行下依然完全可用。",
                            "Wireline reads/writes this standard OpenSSH config; it stays fully usable from the CLI after uninstall."))
                }
            }
            .padding(22)
        }
        .frame(width: 500, height: 520)
        .background(WL.bg)
        .preferredColorScheme(.dark)
    }

    private func section<V: View>(_ title: String, @ViewBuilder _ content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("// \(title)").font(WL.small.weight(.semibold)).foregroundStyle(WL.green)
            content()
        }
    }

    private func row<V: View>(_ label: String, @ViewBuilder _ trailing: () -> V) -> some View {
        HStack(spacing: 10) {
            Text(label).font(WL.body).foregroundStyle(WL.textPrimary)
            Spacer()
            trailing()
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(WL.caption).foregroundStyle(WL.textDim)
    }

    private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .image]
        if panel.runModal() == .OK, let url = panel.url {
            store.terminalBgImagePath = url.path
        }
    }

    private func importTheme() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if let t = UTType(filenameExtension: "itermcolors") {
            panel.allowedContentTypes = [t, .data]
        }
        if panel.runModal() == .OK, let url = panel.url,
           let theme = ITermColorParser.parse(url: url) {
            store.terminalTheme = theme
        }
    }

    /// Installed monospaced font families, computed once.
    static let monoFamilies: [String] = NSFontManager.shared.availableFontFamilies
        .filter { NSFont(name: $0, size: 12)?.isFixedPitch == true }
        .sorted()
}
