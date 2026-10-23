import SwiftUI
import AppKit
import UniformTypeIdentifiers
import WirelineCore

struct SettingsView: View {
    @Environment(HostStore.self) private var store
    @Environment(TodoStore.self) private var todos
    @Environment(Localizer.self) private var loc
    @State private var tab = 0
    @State private var ai = AIConfig.shared
    @State private var aiKeyDraft = ""
    @State private var showThemeEditor = false
    @State private var showMCP = false
    @State private var showSkills = false
    @State private var config = ConfigStore.shared

    var body: some View {
        ZStack(alignment: .top) {
            // Opaque base covering the whole window, including any strip the window
            // reserves beyond the content (otherwise the translucent window
            // material shows through as a stray band).
            WL.bg.ignoresSafeArea()
            // The whole window is the canvas the setting cards are raised on.
            WL.paneCanvas.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                WLFormDivider()
                Group {
                    if tab == 0 { general }
                    else if tab == 1 { ShortcutSettingsView() }
                    else { aiSettings }
                }
                .id(tab)
                .transition(.opacity.animation(Motion.fade))
            }
        }
        .frame(width: 600, height: 660)
        // The system's document-window zoom-in when Settings opens.
        .background(WindowAccessor { $0.animationBehavior = .documentWindow })
        .preferredColorScheme(WL.colorScheme)
        // In-window cards that flip in over the settings (see Modal.swift),
        // not system sheets sliding out of the title bar.
        .wlModal(isPresented: $showThemeEditor) { ThemeEditorView() }
        .wlModal(isPresented: $showMCP) {
            MCPSettingsView(onClose: { wlAnimate(Motion.flipOut) { showMCP = false } })
        }
        .wlModal(isPresented: $showSkills) {
            SkillSettingsView(onClose: { wlAnimate(Motion.flipOut) { showSkills = false } })
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Text(loc("设置", "Settings")).font(WL.mono(13, .semibold)).foregroundStyle(WL.textPrimary)
            Spacer()
            WLSegmented(selection: $tab, options: [
                WLOption(0, loc("常规", "General"), symbol: "gearshape"),
                WLOption(1, loc("快捷键", "Shortcuts"), symbol: "keyboard"),
                WLOption(2, "AI", symbol: "sparkles"),
            ], fill: false)
        }
        // Sits in the title-bar band, level with the traffic lights.
        .padding(.leading, 84).padding(.trailing, 16)
        .frame(height: 52)
        .blocksWindowDrag()   // title-bar band: see WLPageHeader
    }

    private var general: some View {
        @Bindable var store = store
        @Bindable var todos = todos
        @Bindable var loc = loc
        return ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                section(loc("语言", "Language")) {
                    WLFormRow(loc("界面语言", "Interface language")) {
                        WLSegmented(selection: $loc.language,
                                    options: AppLanguage.allCases.map { WLOption($0, $0.shortName) }, fill: false)
                            .wlConfigLocked("language")
                    }
                }

                section(loc("终端", "Terminal"),
                        footer: loc("内置会话在应用内真实 PTY 中运行，启动登录 shell，prompt/主题/配色与平时终端一致。",
                                    "Built-in sessions run in a real PTY, launching your login shell so prompt, theme, and colors match your normal terminal.")) {
                    Toggle(isOn: $store.useBuiltInTerminal) { rowLabel(loc("使用内置终端", "Use built-in terminal")) }
                        .toggleStyle(.wlSwitch).frame(minHeight: 38).wlConfigLocked("builtin-terminal")
                    WLFormDivider()
                    WLFormRow(loc("终端内核", "Terminal engine"),
                              detail: loc("对新开的标签和分屏生效；SwiftTerm 为备用内核", "Applies to new tabs and splits; SwiftTerm is the fallback")) {
                        WLSegmented(selection: $store.terminalEngine, options: [
                            WLOption(TerminalEngineKind.swiftterm, "SwiftTerm"),
                            WLOption(TerminalEngineKind.ghostty, "libghostty"),
                        ], fill: false)
                        .wlConfigLocked("terminal-engine")
                    }
                    WLFormDivider()
                    Toggle(isOn: $store.terminalGPU) {
                        WLFormRow(loc("GPU 渲染", "GPU rendering"),
                                  detail: loc("用 Metal 绘制终端，大量输出时更流畅、更省 CPU", "Draw terminals with Metal — smoother, lighter on the CPU under heavy output")) { EmptyView() }
                    }
                    .toggleStyle(.wlSwitch).wlConfigLocked("gpu-rendering")
                    WLFormDivider()
                    Toggle(isOn: $store.inheritWorkingDirectory) { rowLabel(loc("新标签继承当前目录", "New tabs inherit the directory")) }
                        .toggleStyle(.wlSwitch).frame(minHeight: 38).wlConfigLocked("window-inherit-working-directory")
                    WLFormDivider()
                    WLFormRow(loc("命令完成提醒", "Command-finished alert"),
                              detail: loc("Wireline 不在前台时，耗时超过这个时长的命令结束会发通知", "When Wireline is in the background, notify for commands that ran at least this long")) {
                        WLStepper(value: $store.notifyCommandAfter, range: 1...600, step: 5,
                                  format: { loc("\(Int($0)) 秒", "\(Int($0))s") })
                            .wlConfigLocked("notify-on-command-finish-after")
                    }
                    WLFormDivider()
                    WLFormRow(loc("否则打开于", "Otherwise open in")) {
                        WLMenuPicker(selection: $store.terminalApp,
                                     options: TerminalApp.allCases.map { WLOption($0, $0.displayName) })
                            .disabled(store.useBuiltInTerminal)
                            .wlConfigLocked("external-terminal")
                    }
                }

                section(loc("主题", "Theme"),
                        footer: loc("主题不止配色——形状、密度、字体、壁纸都能自定义，可保存多套。编辑器里能导出自包含的 .wltheme 主题包（内嵌壁纸），发给别人直接导入即用。",
                                    "A theme is more than colors — shape, density, font and wallpaper too. Save multiple; the editor exports a self-contained .wltheme pack (wallpaper embedded) others can import directly.")) {
                    Toggle(isOn: followSystemBinding) {
                        rowLabel(loc("跟随系统深浅色", "Match system appearance"))
                    }
                    .toggleStyle(.wlSwitch).frame(minHeight: 38).wlConfigLocked("theme")
                    WLFormDivider()
                    if store.followsSystemAppearance {
                        WLFormRow(loc("浅色时", "Light")) {
                            WLMenuPicker(selection: Binding(get: { store.themeForLight ?? "" },
                                                            set: { store.themeForLight = $0 }),
                                         options: store.allThemes.map { WLOption($0.name, $0.name) }, minWidth: 150)
                                .wlConfigLocked("theme")
                        }
                        WLFormDivider()
                        WLFormRow(loc("深色时", "Dark")) {
                            WLMenuPicker(selection: Binding(get: { store.themeForDark ?? "" },
                                                            set: { store.themeForDark = $0 }),
                                         options: store.allThemes.map { WLOption($0.name, $0.name) }, minWidth: 150)
                                .wlConfigLocked("theme")
                        }
                    } else {
                        WLFormRow(loc("当前主题", "Active theme")) {
                            WLMenuPicker(selection: themeSelection,
                                         options: store.allThemes.map { WLOption($0.name, $0.name) }, minWidth: 150)
                                .wlConfigLocked("theme")
                        }
                    }
                    themeSwatches.padding(.bottom, 8)
                    WLFormDivider()
                    WLFormRow(loc("管理", "Manage")) {
                        Button(loc("导入 iTerm2…", "Import iTerm2…")) { importTheme() }.buttonStyle(.wlSecondary)
                        Button(loc("主题编辑器…", "Theme Editor…")) { showThemeEditor = true }.buttonStyle(.wlSecondary)
                    }
                }

                section(loc("终端字体与光标", "Terminal Font & Cursor")) {
                    WLFormRow(loc("字体", "Font")) {
                        WLMenuPicker(selection: $store.terminalFontName, options: fontOptions, minWidth: 170)
                            .wlConfigLocked("font-family")
                    }
                    WLFormDivider()
                    WLFormRow(loc("字号", "Size")) {
                        WLStepper(value: $store.terminalFontSize, range: 6...72).wlConfigLocked("font-size")
                    }
                    WLFormDivider()
                    WLFormRow(loc("光标", "Cursor")) {
                        WLSegmented(selection: $store.terminalCursorShape, options: [
                            WLOption(CursorShape.block, loc("方块", "Block")),
                            WLOption(CursorShape.bar, loc("竖线", "Bar")),
                            WLOption(CursorShape.underline, loc("下划线", "Underline")),
                        ], fill: false)
                        .wlConfigLocked("cursor-style")
                    }
                    WLFormDivider()
                    WLFormRow(loc("内边距", "Padding"), detail: loc("终端文字与面板边缘的距离（左右 / 上下）", "Space between the text and the panel edges (sides / top & bottom)")) {
                        HStack(spacing: 8) {
                            WLStepper(value: $store.terminalPaddingX, range: 0...80, step: 2)
                                .wlConfigLocked("window-padding-x")
                            WLStepper(value: $store.terminalPaddingY, range: 0...80, step: 2)
                                .wlConfigLocked("window-padding-y")
                        }
                    }
                    WLFormDivider()
                    Toggle(isOn: $store.terminalCursorBlink) { rowLabel(loc("光标闪烁", "Blinking cursor")) }
                        .toggleStyle(.wlSwitch).frame(minHeight: 38).wlConfigLocked("cursor-style-blink")
                    WLFormDivider()
                    WLFormRow(loc("未聚焦分屏", "Unfocused panes"),
                              detail: loc("分屏时非当前窗格的可见度，100% 为不变暗", "How visible non-focused split panes stay; 100% = no dimming")) {
                        HStack(spacing: 10) {
                            WLSlider(value: $store.unfocusedSplitOpacity, range: 0.15...1, width: 120)
                            Text(String(format: "%.0f%%", store.unfocusedSplitOpacity * 100))
                                .font(WL.small).monospacedDigit().foregroundStyle(WL.textDim)
                                .frame(width: 38, alignment: .trailing)
                        }
                        .wlConfigLocked("unfocused-split-opacity")
                    }
                }

                section(loc("背景", "Background"),
                        footer: loc("支持 png/jpg 图片与 mp4/mov 动态壁纸，作用于整个应用。",
                                    "Supports png/jpg images and mp4/mov animated wallpaper, applied app-wide.")) {
                    WLFormRow(loc("不透明度", "Opacity")) {
                        HStack(spacing: 10) {
                            WLSlider(value: $store.terminalOpacity, range: 0.2...1.0)
                            Text(String(format: "%.0f%%", store.terminalOpacity * 100))
                                .font(WL.small).monospacedDigit().foregroundStyle(WL.textDim)
                                .frame(width: 38, alignment: .trailing)
                        }
                        .wlConfigLocked("background-opacity")
                    }
                    WLFormDivider()
                    WLFormRow(loc("壁纸", "Wallpaper"),
                              detail: store.terminalBgImagePath.map { ($0 as NSString).lastPathComponent } ?? loc("无", "None")) {
                        HStack(spacing: 8) {
                            if store.terminalBgImagePath != nil {
                                Button(loc("清除", "Clear")) { store.terminalBgImagePath = nil }.buttonStyle(.wlSecondary)
                            }
                            Button(loc("选择…", "Choose…")) { pickImage() }.buttonStyle(.wlSecondary)
                        }
                        .wlConfigLocked("background-image")
                    }
                }

                section(loc("快捷终端", "Quick Terminal"),
                        footer: loc("在任意 App 里按 \(KeyBindingStore.shared.shortcut(for: .toggleQuickTerminal).display) 从屏幕顶部呼出一个本地终端，再按一次收起。快捷键可在「快捷键」里修改。",
                                    "Press \(KeyBindingStore.shared.shortcut(for: .toggleQuickTerminal).display) in any app to drop down a local terminal from the top of the screen; press again to put it away. Rebind it under Shortcuts.")) {
                    WLFormRow(loc("高度", "Height")) {
                        HStack(spacing: 10) {
                            WLSlider(value: $store.quickTerminalHeight, range: 0.15...1, width: 140)
                            Text(String(format: "%.0f%%", store.quickTerminalHeight * 100))
                                .font(WL.small).monospacedDigit().foregroundStyle(WL.textDim)
                                .frame(width: 38, alignment: .trailing)
                        }
                        .wlConfigLocked("quick-terminal-size")
                    }
                    WLFormDivider()
                    Toggle(isOn: $store.quickTerminalAutohide) { rowLabel(loc("失去焦点时自动收起", "Hide when it loses focus")) }
                        .toggleStyle(.wlSwitch).frame(minHeight: 38).wlConfigLocked("quick-terminal-autohide")
                }

                section(loc("连通性", "Connectivity"),
                        footer: loc("主机在线↔离线切换时发系统通知。",
                                    "Sends a system notification when a host goes offline or comes back.")) {
                    Toggle(isOn: $store.autoCheckOnLaunch) { rowLabel(loc("启动时检测所有主机", "Check all hosts on launch")) }
                        .toggleStyle(.wlSwitch).frame(minHeight: 38).wlConfigLocked("check-on-launch")
                    WLFormDivider()
                    Toggle(isOn: $store.backgroundMonitor) { rowLabel(loc("后台定时巡检并通知", "Background monitoring with notifications")) }
                        .toggleStyle(.wlSwitch).frame(minHeight: 38).wlConfigLocked("background-monitor")
                    if store.backgroundMonitor {
                        WLFormDivider()
                        WLFormRow(loc("巡检间隔", "Check interval")) {
                            WLStepper(value: $store.monitorInterval, range: 15...600, step: 15,
                                      format: { loc("\(Int($0)) 秒", "\(Int($0))s") })
                                .wlConfigLocked("monitor-interval")
                        }
                        .transition(.wlDisclose)
                    }
                }
                .animation(Motion.disclose, value: store.backgroundMonitor)

                section(loc("待办", "To-Do"),
                        footer: loc("开启后在菜单栏显示待办图标（含未完成计数），并启用「待办清单」菜单与快捷键；关闭则完全隐藏，不占用菜单栏。",
                                    "Adds a menu-bar icon with an open-item count and enables the To-Do menu and shortcut; off hides it entirely, freeing the menu bar.")) {
                    Toggle(isOn: $todos.enabled) { rowLabel(loc("启用待办清单", "Enable to-do list")) }
                        .toggleStyle(.wlSwitch).frame(minHeight: 38)
                }

                section(loc("更新", "Updates"),
                        footer: loc("通过 Sparkle 检查签名后的更新（appcast 托管在项目站点，无服务端）。",
                                    "Signed updates via Sparkle (appcast hosted on the project site, no backend).")) {
                    WLFormRow(loc("当前版本", "Version"),
                              detail: "v" + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")) {
                        Button(loc("检查更新", "Check for Updates")) { Updater.shared.checkForUpdates() }
                            .buttonStyle(.wlSecondary)
                    }
                    WLFormDivider()
                    Toggle(isOn: Binding(get: { Updater.shared.automaticChecks },
                                         set: { Updater.shared.automaticChecks = $0 })) {
                        rowLabel(loc("自动检查更新", "Check for updates automatically"))
                    }.toggleStyle(.wlSwitch).frame(minHeight: 38)
                }

                configFileSection

                section(loc("SSH 配置", "SSH Config"),
                        footer: loc("Wireline 直接读写这份标准 OpenSSH 配置；卸载后它在命令行下依然完全可用。",
                                    "Wireline reads/writes this standard OpenSSH config; it stays fully usable from the CLI after uninstall.")) {
                    WLFormRow(store.repository.url.path) {
                        Button(loc("在访达中显示", "Show in Finder")) {
                            NSWorkspace.shared.activateFileViewerSelecting([store.repository.url])
                        }.buttonStyle(.wlSecondary)
                    }
                }
            }
            .padding(22)
        }
    }

    /// The Ghostty-style text config: where it is, open / reload, and any issues.
    private var configFileSection: some View {
        section(loc("Wireline 配置文件", "Wireline Config File"),
                footer: loc("像 Ghostty 一样用纯文本配置：font-size = 14、theme = Dracula、keybind = cmd+shift+t=new_local_terminal。文件里写了的项会锁定此处的控件；保存即生效，⌘⇧, 手动重载。",
                            "Plain-text config, Ghostty-style: font-size = 14, theme = Dracula, keybind = cmd+shift+t=new_local_terminal. Keys set there lock the controls here; saving applies instantly, ⌘⇧, reloads.")) {
            WLFormRow((config.url.path as NSString).abbreviatingWithTildeInPath,
                      detail: config.loadedFiles.isEmpty ? loc("尚未创建", "Not created yet")
                            : loc("接管 \(config.lockedKeys.count) 项设置", "Overrides \(config.lockedKeys.count) setting(s)")) {
                HStack(spacing: 8) {
                    if !config.loadedFiles.isEmpty {
                        Button(loc("重新加载", "Reload")) { config.reload() }.buttonStyle(.wlSecondary)
                    }
                    Button(config.loadedFiles.isEmpty ? loc("创建并打开", "Create & Open") : loc("打开", "Open")) {
                        config.openInEditor()
                    }.buttonStyle(.wlSecondary)
                }
            }
            if !config.issues.isEmpty {
                WLFormDivider()
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(config.issues.enumerated()), id: \.offset) { _, issue in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9))
                                .foregroundStyle(WL.amber).padding(.top, 2)
                            Text(issue.description).font(WL.mono(11)).foregroundStyle(WL.textPrimary)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(.vertical, 10)
            }
        }
    }

    private func rowLabel(_ text: String) -> some View {
        Text(text).font(WL.body).foregroundStyle(WL.textPrimary)
    }

    private var aiSettings: some View {
        @Bindable var ai = ai
        return ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                section(loc("AI 助手", "AI Assistant"),
                        footer: loc("自然语言生成命令、诊断报错、解释命令、总结输出。",
                                    "NL→command, diagnose errors, explain, summarize.")) {
                    Toggle(isOn: $ai.enabled) { rowLabel(loc("启用 AI 助手", "Enable AI assistant")) }
                        .toggleStyle(.wlSwitch).frame(minHeight: 38).wlConfigLocked("ai-enabled")
                }

                section(loc("后端", "Backend"),
                        footer: ai.provider == .relay
                            ? loc("填中转站/OpenAI 兼容的 /v1 地址与密钥。填了快速模型后，面板里会出现「快速」开关，用它跑简单任务更省。",
                                  "OpenAI-compatible /v1 endpoint + key. Set a fast model to get a “Fast” toggle in the panel for cheap tasks.")
                            : loc("需本地运行 Ollama（ollama serve）。数据不出本机。",
                                  "Requires local Ollama (ollama serve). Nothing leaves your machine.")) {
                    WLFormRow(loc("服务", "Provider")) {
                        WLSegmented(selection: $ai.provider,
                                    options: AIProvider.allCases.map { WLOption($0, $0.title) }, fill: false)
                            .wlConfigLocked("ai-provider")
                    }
                    WLFormDivider()
                    VStack(alignment: .leading, spacing: 12) {
                        if ai.provider == .relay {
                            aiField(loc("服务地址 (Base URL)", "Base URL"), "https://your-relay.com/v1", $ai.relayBaseURL)
                                .wlConfigLocked("ai-base-url")
                            aiSecureField(loc("API Key", "API Key"))
                            aiField(loc("主模型", "Model"), "claude-sonnet-4-20250514", $ai.relayModel)
                                .wlConfigLocked("ai-model")
                            aiField(loc("快速模型（可选）", "Fast model (optional)"), "claude-haiku-…", $ai.relayModelFast)
                                .wlConfigLocked("ai-model-fast")
                        } else {
                            aiField(loc("服务地址 (Base URL)", "Base URL"), "http://localhost:11434/v1", $ai.ollamaBaseURL)
                                .wlConfigLocked("ai-ollama-url")
                            aiField(loc("主模型", "Model"), "qwen2.5", $ai.ollamaModel)
                                .wlConfigLocked("ai-ollama-model")
                            aiField(loc("快速模型（可选）", "Fast model (optional)"), "qwen2.5:3b", $ai.ollamaModelFast)
                                .wlConfigLocked("ai-ollama-model-fast")
                        }
                    }
                    .padding(.vertical, 12)
                }

                section(loc("用量", "Usage"),
                        footer: loc("面板顶部显示本次会话的估算 token 用量；填了单价则一并估算花费（本地估算，非精确计费）。",
                                    "The panel shows estimated token usage; set a price to also estimate cost (local estimate, not exact billing).")) {
                    WLFormRow(loc("单价 / 1K tokens", "Price / 1K tokens")) {
                        TextField("0", value: $ai.pricePer1k, format: .number)
                            .frame(width: 80)
                            .wlField()
                    }
                    WLFormDivider()
                    WLFormRow(loc("每会话保留条数", "History per chat")) {
                        WLStepper(value: $ai.historyLimit, range: 10...500, step: 10).wlConfigLocked("ai-history-limit")
                    }
                }

                section(loc("Agent 自动执行", "Agent Execution"),
                        footer: loc("开启 AI 面板里的「自动执行」后，AI 生成的命令会真的执行、拿到输出再继续。终端执行让你全程看到在做什么；高危命令执行前一律弹窗二次确认。只读沙盒开启后，任何写/删除/重启类命令都会被直接拒绝。",
                                    "With Agent mode on, commands actually run and feed back. Terminal mode keeps it visible; risky commands always ask first. Read-only sandbox rejects any write/delete/restart command outright.")) {
                    WLFormRow(loc("执行位置", "Run commands")) {
                        WLSegmented(selection: $ai.agentInTerminal, options: [
                            WLOption(true, loc("终端（可见）", "Terminal (visible)")),
                            WLOption(false, loc("旁路（安静）", "Out-of-band")),
                        ], fill: false)
                        .wlConfigLocked("ai-agent-in-terminal")
                    }
                    WLFormDivider()
                    Toggle(isOn: $ai.agentReadOnly) { rowLabel(loc("只读沙盒（仅允许查询命令）", "Read-only sandbox (query commands only)")) }
                        .toggleStyle(.wlSwitch).frame(minHeight: 38).wlConfigLocked("ai-agent-read-only")
                }

                section(loc("面板", "Panel")) {
                    WLFormRow(loc("字号", "Font size")) {
                        WLStepper(value: $ai.fontSize, range: 10...22).wlConfigLocked("ai-font-size")
                    }
                }

                section(loc("值班", "On-call"),
                        footer: loc("需同时开启「连通性 → 后台巡检」。主机掉线时，AI 给出可能原因与排查建议，附在系统通知里。",
                                    "Requires background monitoring. When a host drops, AI adds likely causes to the notification.")) {
                    Toggle(isOn: $ai.alertAttribution) { rowLabel(loc("主机离线时 AI 自动归因", "AI triage when a host goes offline")) }
                        .toggleStyle(.wlSwitch).frame(minHeight: 38)
                }

                section(loc("桌面宠物", "Desktop Pet"),
                        footer: loc("一只可拖动的悬浮小精灵，点它就能对话——它操作当前活动的终端标签页，帮你执行命令并总结结果。菜单 窗口 → 桌面宠物 也能随时唤出。",
                                    "A draggable floating sprite — click it to chat. It drives your active terminal tab, runs commands, and summarizes. Also summonable from the menu.")) {
                    Toggle(isOn: $ai.petEnabled) { rowLabel(loc("启动时显示桌面宠物", "Show desktop pet on launch")) }
                        .toggleStyle(.wlSwitch).frame(minHeight: 38)
                }

                section(loc("扩展", "Extensions"),
                        footer: loc("运维技能：内置的排查流程（负载/磁盘/服务/容器/安全），AI 按需载入。MCP：接入外部工具，密钥存 Keychain，写操作二次确认。",
                                    "Ops skills: built-in playbooks (load / disk / services / containers / security) loaded on demand. MCP: external tools, secrets in Keychain, mutating calls confirmed.")) {
                    WLFormRow(loc("运维技能", "Ops Skills")) {
                        Button(loc("管理…", "Manage…")) { showSkills = true }.buttonStyle(.wlSecondary)
                    }
                    WLFormDivider()
                    WLFormRow(loc("MCP 工具", "MCP Tools")) {
                        Button(loc("管理…", "Manage…")) { showMCP = true }.buttonStyle(.wlSecondary)
                    }
                }

                section(loc("隐私", "Privacy"),
                        footer: loc("开启后，发给模型的终端输出会自动打码明显的密码 / 密钥 / token。",
                                    "Terminal output sent to the model has obvious passwords/keys/tokens masked.")) {
                    Toggle(isOn: $ai.redact) { rowLabel(loc("发送前脱敏（密码 / token 等）", "Redact secrets before sending")) }
                        .toggleStyle(.wlSwitch).frame(minHeight: 38).wlConfigLocked("ai-redact")
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
                .wlField()
        }
    }

    private func aiSecureField(_ label: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(WL.small).foregroundStyle(WL.textDim)
            SecureField("", text: $aiKeyDraft, prompt: Text("sk-…").foregroundStyle(WL.textDim))
                .wlField()
                .onChange(of: aiKeyDraft) { ai.apiKey = aiKeyDraft }
        }
    }

    /// On: pair the current theme with a sensible counterpart for the other
    /// appearance. Off: keep whatever is showing now.
    private var followSystemBinding: Binding<Bool> {
        Binding(get: { store.followsSystemAppearance }, set: { on in
            if on {
                let current = store.selectedThemeName
                let names = Set(store.allThemes.map(\.name))
                if WL.isLight {
                    store.themeForLight = current
                    store.themeForDark = names.contains("Wireline") ? "Wireline" : current
                } else {
                    store.themeForDark = current
                    store.themeForLight = names.contains("Wireline Light") ? "Wireline Light" : current
                }
            } else {
                store.themeForLight = nil
                store.themeForDark = nil
            }
        })
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
                    in: RoundedRectangle(cornerRadius: WL.radius(6), style: .continuous))
    }

    private func section<V: View>(_ title: String, footer: String? = nil,
                                  @ViewBuilder _ content: () -> V) -> some View {
        WLFormSection(title, footer: footer, content: content)
    }

    private func row<V: View>(_ label: String, @ViewBuilder _ trailing: () -> V) -> some View {
        HStack(spacing: 10) {
            Text(label).font(WL.body).foregroundStyle(WL.textPrimary)
            Spacer()
            trailing()
        }
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

    /// Monospaced families from the background-scanned catalog, icon-capable
    /// (Nerd Font) ones first and marked, so it's obvious which render prompt icons.
    private var fontOptions: [WLOption<String?>] {
        [WLOption(String?.none, loc("自动 (Nerd Font)", "Auto (Nerd Font)"))]
            + FontCatalog.shared.monoFamilies().map {
                WLOption(String?.some($0.name), $0.hasIcons ? $0.name + loc("  · 含图标", "  · icons") : $0.name)
            }
    }
}
