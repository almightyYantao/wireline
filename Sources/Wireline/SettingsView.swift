import SwiftUI
import AppKit
import UniformTypeIdentifiers
import WirelineCore

struct SettingsView: View {
    @Environment(HostStore.self) private var store
    @Environment(Localizer.self) private var loc
    @State private var tab = 0
    @State private var ai = AIConfig.shared
    @State private var aiKeyDraft = ""
    @State private var showThemeEditor = false

    var body: some View {
        ZStack(alignment: .top) {
            // Opaque base covering the whole window, including any strip the window
            // reserves beyond the content (otherwise the translucent window
            // material shows through as a stray band).
            WL.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Rectangle().fill(WL.border).frame(height: 1)
                Group {
                    if tab == 0 { general }
                    else if tab == 1 { ShortcutSettingsView() }
                    else { aiSettings }
                }
            }
        }
        .frame(width: 520, height: 580)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showThemeEditor) { ThemeEditorView() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Text("> settings").font(WL.mono(15, .bold)).foregroundStyle(WL.green)
            Spacer()
            tabButton(loc("常规", "General"), "gearshape", 0)
            tabButton(loc("快捷键", "Shortcuts"), "keyboard", 1)
            tabButton("AI", "sparkles", 2)
        }
        .padding(.horizontal, 18)
        .padding(.top, 32).padding(.bottom, 12)
    }

    private func tabButton(_ title: String, _ symbol: String, _ index: Int) -> some View {
        let active = tab == index
        return Button { tab = index } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10))
                Text(title).font(WL.small)
            }
            .foregroundStyle(active ? WL.green : WL.textDim)
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(active ? WL.green.opacity(0.14) : WL.surface.opacity(0.4),
                        in: RoundedRectangle(cornerRadius: WL.radius(6)))
            .overlay(RoundedRectangle(cornerRadius: WL.radius(6))
                .stroke(active ? WL.green.opacity(0.6) : WL.border, lineWidth: WL.borderWidth))
        }
        .buttonStyle(.plain)
    }

    private var general: some View {
        @Bindable var store = store
        @Bindable var loc = loc
        return ScrollView {
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

                section(loc("主题 / 配色", "Theme")) {
                    row(loc("当前主题", "Active theme")) {
                        Picker("", selection: themeSelection) {
                            ForEach(store.allThemes) { Text($0.name).tag($0.name) }
                        }.labelsHidden().fixedSize()
                        BracketButton(loc("编辑器…", "Editor…")) { showThemeEditor = true }
                    }
                    themeSwatches
                    row("") {
                        BracketButton(loc("导入 iTerm2…", "Import iTerm2…")) { importTheme() }
                        Spacer()
                    }
                    hint(loc("主题不止配色——形状、密度、字体、壁纸都能自定义，可保存多套。编辑器里能导出自包含的 .wltheme 主题包(内嵌壁纸)，发给别人直接导入即用。",
                            "A theme is more than colors — shape, density, font and wallpaper too. Save multiple; the editor exports a self-contained .wltheme pack (wallpaper embedded) others can import directly."))
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
                    row(loc("壁纸 (图片/视频)", "Wallpaper (image/video)")) {
                        Text(store.terminalBgImagePath.map { ($0 as NSString).lastPathComponent } ?? loc("无", "None"))
                            .font(WL.small).foregroundStyle(WL.textDim).lineLimit(1)
                        BracketButton(loc("选择…", "Choose…")) { pickImage() }
                        if store.terminalBgImagePath != nil { BracketButton(loc("清除", "Clear")) { store.terminalBgImagePath = nil } }
                    }
                    hint(loc("支持 png/jpg 图片与 mp4/mov 动态壁纸,作用于整个应用。",
                            "Supports png/jpg images and mp4/mov animated wallpaper, applied app-wide."))
                }

                section(loc("连通性", "Connectivity")) {
                    Toggle(isOn: $store.autoCheckOnLaunch) {
                        Text(loc("启动时检测所有主机", "Check all hosts on launch")).font(WL.body).foregroundStyle(WL.textPrimary)
                    }.toggleStyle(.checkbox).tint(WL.green)
                    Toggle(isOn: $store.backgroundMonitor) {
                        Text(loc("后台定时巡检并通知", "Background monitoring with notifications")).font(WL.body).foregroundStyle(WL.textPrimary)
                    }.toggleStyle(.checkbox).tint(WL.green)
                    if store.backgroundMonitor {
                        row(loc("巡检间隔", "Check interval")) {
                            Stepper(value: $store.monitorInterval, in: 15...600, step: 15) {
                                Text(loc("\(Int(store.monitorInterval)) 秒", "\(Int(store.monitorInterval))s"))
                                    .font(WL.body).foregroundStyle(WL.textPrimary)
                            }.fixedSize()
                        }
                    }
                    hint(loc("主机在线↔离线切换时发系统通知。",
                            "Sends a system notification when a host goes offline or comes back."))
                }

                section(loc("配置文件", "Config File")) {
                    Text(store.repository.url.path).font(WL.small).foregroundStyle(WL.textDim).textSelection(.enabled)
                    hint(loc("Wireline 直接读写这份标准 OpenSSH 配置；卸载后它在命令行下依然完全可用。",
                            "Wireline reads/writes this standard OpenSSH config; it stays fully usable from the CLI after uninstall."))
                }
            }
            .padding(22)
        }
    }

    private var aiSettings: some View {
        @Bindable var ai = ai
        return ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                section(loc("AI 助手", "AI Assistant")) {
                    Toggle(isOn: $ai.enabled) {
                        Text(loc("启用 AI 助手", "Enable AI assistant")).font(WL.body).foregroundStyle(WL.textPrimary)
                    }.toggleStyle(.checkbox).tint(WL.green)
                    hint(loc("在终端右下角显示 ✨ 按钮：自然语言生成命令、诊断报错、解释命令、总结输出。",
                            "Shows a ✨ button by the terminal: NL→command, diagnose errors, explain, summarize."))
                }

                section(loc("后端", "Backend")) {
                    Picker("", selection: $ai.provider) {
                        ForEach(AIProvider.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.labelsHidden().pickerStyle(.segmented)

                    if ai.provider == .relay {
                        aiField(loc("服务地址 (Base URL)", "Base URL"), "https://your-relay.com/v1", $ai.relayBaseURL)
                        aiSecureField(loc("API Key", "API Key"))
                        aiField(loc("主模型", "Model"), "claude-sonnet-4-20250514", $ai.relayModel)
                        aiField(loc("快速模型（可选）", "Fast model (optional)"), "claude-haiku-…", $ai.relayModelFast)
                        hint(loc("填中转站/OpenAI 兼容的 /v1 地址与密钥。填了快速模型后，面板里会出现「快速」开关，用它跑简单任务更省。",
                                "OpenAI-compatible /v1 endpoint + key. Set a fast model to get a “Fast” toggle in the panel for cheap tasks."))
                    } else {
                        aiField(loc("服务地址 (Base URL)", "Base URL"), "http://localhost:11434/v1", $ai.ollamaBaseURL)
                        aiField(loc("主模型", "Model"), "qwen2.5", $ai.ollamaModel)
                        aiField(loc("快速模型（可选）", "Fast model (optional)"), "qwen2.5:3b", $ai.ollamaModelFast)
                        hint(loc("需本地运行 Ollama（ollama serve）。数据不出本机。",
                                "Requires local Ollama (ollama serve). Nothing leaves your machine."))
                    }
                }

                section(loc("用量", "Usage")) {
                    row(loc("单价 / 1K tokens", "Price / 1K tokens")) {
                        TextField("0", value: $ai.pricePer1k, format: .number)
                            .textFieldStyle(.plain).font(WL.mono(12)).foregroundStyle(WL.textPrimary)
                            .frame(width: 80)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(WL.surface, in: RoundedRectangle(cornerRadius: WL.radius(5)))
                            .overlay(RoundedRectangle(cornerRadius: WL.radius(5)).stroke(WL.border, lineWidth: WL.borderWidth))
                    }
                    row(loc("每会话保留条数", "History per chat")) {
                        Stepper(value: $ai.historyLimit, in: 10...500, step: 10) {
                            Text("\(ai.historyLimit)").font(WL.body).foregroundStyle(WL.textPrimary)
                        }.fixedSize()
                    }
                    hint(loc("面板顶部显示本次会话的估算 token 用量；填了单价则一并估算花费（本地估算，非精确计费）。",
                            "The panel shows estimated token usage; set a price to also estimate cost (local estimate, not exact billing)."))
                }

                section(loc("Agent 自动执行", "Agent Execution")) {
                    Picker("", selection: $ai.agentInTerminal) {
                        Text(loc("在终端执行（可见）", "In terminal (visible)")).tag(true)
                        Text(loc("旁路执行（不干扰终端）", "Out-of-band (quiet)")).tag(false)
                    }.labelsHidden().pickerStyle(.segmented)
                    Toggle(isOn: $ai.agentReadOnly) {
                        Text(loc("只读沙盒（仅允许查询命令）", "Read-only sandbox (query commands only)"))
                            .font(WL.body).foregroundStyle(WL.textPrimary)
                    }.toggleStyle(.checkbox).tint(WL.green)
                    hint(loc("开启 AI 面板里的「自动执行」后，AI 生成的命令会真的执行、拿到输出再继续。终端执行让你全程看到在做什么；高危命令执行前一律弹窗二次确认。只读沙盒开启后，任何写/删除/重启类命令都会被直接拒绝，彻底杜绝误操作。",
                            "With Agent mode on, commands actually run and feed back. Terminal mode keeps it visible; risky commands always ask first. Read-only sandbox rejects any write/delete/restart command outright."))
                }

                section(loc("面板", "Panel")) {
                    row(loc("字号", "Font size")) {
                        Stepper(value: $ai.fontSize, in: 10...22, step: 1) {
                            Text("\(Int(ai.fontSize))").font(WL.body).foregroundStyle(WL.textPrimary)
                        }.fixedSize()
                    }
                }

                section(loc("值班", "On-call")) {
                    Toggle(isOn: $ai.alertAttribution) {
                        Text(loc("主机离线时 AI 自动归因", "AI triage when a host goes offline"))
                            .font(WL.body).foregroundStyle(WL.textPrimary)
                    }.toggleStyle(.checkbox).tint(WL.green)
                    hint(loc("需同时开启「连通性 → 后台巡检」。主机掉线时,AI 给出可能原因与排查建议,附在系统通知里。",
                            "Requires background monitoring. When a host drops, AI adds likely causes to the notification."))
                }

                section(loc("桌面宠物", "Desktop Pet")) {
                    Toggle(isOn: $ai.petEnabled) {
                        Text(loc("启用桌面宠物（启动时悬浮显示）", "Enable desktop pet (float on launch)"))
                            .font(WL.body).foregroundStyle(WL.textPrimary)
                    }.toggleStyle(.checkbox).tint(WL.green)
                    hint(loc("一只可拖动的悬浮小精灵,点它就能对话——它操作当前活动的终端标签页,帮你执行命令并总结结果。菜单 窗口 → 桌面宠物 也能随时唤出。",
                            "A draggable floating sprite — click it to chat. It drives your active terminal tab, runs commands, and summarizes. Also summonable from the menu."))
                }

                section(loc("隐私", "Privacy")) {
                    Toggle(isOn: $ai.redact) {
                        Text(loc("发送前脱敏（密码 / token 等）", "Redact secrets before sending"))
                            .font(WL.body).foregroundStyle(WL.textPrimary)
                    }.toggleStyle(.checkbox).tint(WL.green)
                    hint(loc("勾选后，发给模型的终端输出会自动打码明显的密码 / 密钥 / token。",
                            "Terminal output sent to the model has obvious passwords/keys/tokens masked."))
                }
            }
            .padding(22)
        }
        .onAppear { aiKeyDraft = ai.apiKey }
    }

    private func aiField(_ label: String, _ prompt: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(WL.small).foregroundStyle(WL.textDim)
            TextField("", text: text, prompt: Text(prompt).foregroundStyle(WL.textDim))
                .textFieldStyle(.plain).font(WL.mono(12)).foregroundStyle(WL.textPrimary)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(WL.surface, in: RoundedRectangle(cornerRadius: WL.radius(5)))
                .overlay(RoundedRectangle(cornerRadius: WL.radius(5)).stroke(WL.border, lineWidth: WL.borderWidth))
        }
    }

    private func aiSecureField(_ label: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(WL.small).foregroundStyle(WL.textDim)
            SecureField("", text: $aiKeyDraft, prompt: Text("sk-…").foregroundStyle(WL.textDim))
                .textFieldStyle(.plain).font(WL.mono(12)).foregroundStyle(WL.textPrimary)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(WL.surface, in: RoundedRectangle(cornerRadius: WL.radius(5)))
                .overlay(RoundedRectangle(cornerRadius: WL.radius(5)).stroke(WL.border, lineWidth: WL.borderWidth))
                .onChange(of: aiKeyDraft) { ai.apiKey = aiKeyDraft }
        }
    }

    /// Two-way binding between the picker's tag and the active theme name.
    private var themeSelection: Binding<String> {
        Binding(get: { store.selectedThemeName },
                set: { store.selectedThemeName = $0 })
    }

    /// A small strip of the active theme's ANSI colors as a live preview.
    private var themeSwatches: some View {
        let theme = store.activeTheme.colors
        return HStack(spacing: 3) {
            ForEach(Array(theme.ansi.enumerated()), id: \.offset) { _, c in
                RoundedRectangle(cornerRadius: WL.radius(2))
                    .fill(Color(.sRGB, red: c[0], green: c[1], blue: c[2]))
                    .frame(height: 14)
            }
        }
        .padding(4)
        .background(Color(.sRGB, red: theme.background[0], green: theme.background[1], blue: theme.background[2]),
                    in: RoundedRectangle(cornerRadius: WL.radius(4)))
    }

    private func section<V: View>(_ title: String, @ViewBuilder _ content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(WL.small.weight(.semibold)).foregroundStyle(WL.green).textCase(.uppercase)
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
        panel.allowedContentTypes = [.image, .movie, .mpeg4Movie, .quickTimeMovie]
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
            let t = AppTheme(name: store.uniqueThemeName(theme.name), colors: theme)
            store.upsertTheme(t)   // fold the imported scheme into the theme library
        }
    }

    /// Installed monospaced font families, computed once.
    static let monoFamilies: [String] = NSFontManager.shared.availableFontFamilies
        .filter { NSFont(name: $0, size: 12)?.isFixedPitch == true }
        .sorted()
}
