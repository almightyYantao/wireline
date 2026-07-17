import SwiftUI
import AppKit
import UniformTypeIdentifiers
import WirelineCore

/// The theme (skin) manager: a library of built-in + custom skins on the left,
/// and a live editor on the right. Edits apply to the whole app in real time
/// (the window you're looking at re-skins as you drag); "Save" persists them as
/// a custom theme. Closing without saving reverts to the selected theme.
struct ThemeEditorView: View {
    @Environment(HostStore.self) private var store
    @Environment(Localizer.self) private var loc
    @Environment(\.dismiss) private var dismiss

    /// The working copy being previewed/edited (a copy, not yet persisted).
    @State private var draft: AppTheme = .wirelineDefault
    @State private var dirty = false
    @State private var advanced = false

    var body: some View {
        ZStack {
            WL.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Rectangle().fill(WL.border).frame(height: 1)
                HStack(spacing: 0) {
                    library.frame(width: 190)
                    Rectangle().fill(WL.border).frame(width: 1)
                    editor
                }
            }
        }
        .frame(width: 640, height: 600)
        .preferredColorScheme(.dark)
        .onAppear { draft = store.activeTheme }
        // Live-preview across the whole app as the draft changes.
        .onChange(of: draft) { applyLive() }
        .onDisappear { store.applyActiveTheme() }   // revert any unsaved preview
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 12) {
            Text("> theme").font(WL.mono(15, .bold)).foregroundStyle(WL.green)
            Text(loc("自定义主题", "Custom themes")).font(WL.small).foregroundStyle(WL.textDim)
            Spacer()
            BracketButton(loc("导入主题包", "Import")) { importPack() }
            BracketButton(loc("导出主题包", "Export")) { exportPack() }
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(WL.textDim)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 18).padding(.top, 30).padding(.bottom, 12)
    }

    // MARK: library

    private var library: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    libGroup(loc("内置", "Built-in"), AppTheme.builtIns)
                    if !store.customThemes.isEmpty {
                        libGroup(loc("自定义", "Custom"), store.customThemes)
                    }
                }
                .padding(10)
            }
            Rectangle().fill(WL.border).frame(height: 1)
            HStack(spacing: 8) {
                BracketButton(loc("＋ 新建", "＋ New")) { newTheme() }
                Spacer()
                if !draft.isBuiltIn {
                    BracketButton(loc("删除", "Delete")) { deleteDraft() }
                }
            }
            .padding(10)
        }
    }

    private func libGroup(_ title: String, _ themes: [AppTheme]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(WL.caption.weight(.semibold)).foregroundStyle(WL.textDim)
                .textCase(.uppercase).padding(.top, 4)
            ForEach(themes) { t in libRow(t) }
        }
    }

    private func libRow(_ t: AppTheme) -> some View {
        let selected = t.name == draft.name
        return Button {
            draft = t; dirty = false
        } label: {
            HStack(spacing: 8) {
                swatchDot(t)
                Text(t.name).font(WL.small).foregroundStyle(selected ? WL.green : WL.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if store.selectedThemeName == t.name {
                    Image(systemName: "checkmark").font(.system(size: 9)).foregroundStyle(WL.green)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(selected ? WL.green.opacity(0.14) : Color.clear,
                        in: RoundedRectangle(cornerRadius: WL.radius(5)))
        }.buttonStyle(.plain)
    }

    private func swatchDot(_ t: AppTheme) -> some View {
        HStack(spacing: -3) {
            Circle().fill(color(t.colors.background)).frame(width: 12, height: 12)
                .overlay(Circle().stroke(WL.border, lineWidth: WL.borderWidth))
            Circle().fill(color(t.colors.cursor)).frame(width: 12, height: 12)
                .overlay(Circle().stroke(WL.border, lineWidth: WL.borderWidth))
        }
    }

    // MARK: editor

    private var editor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                nameRow
                colorSection
                shapeSection
                typeSection
                backgroundSection
            }
            .padding(18)
        }
        .overlay(alignment: .bottom) { saveBar }
    }

    private var nameRow: some View {
        HStack(spacing: 10) {
            Text(loc("名称", "Name")).font(WL.body).foregroundStyle(WL.textPrimary)
            TextField("", text: Binding(get: { draft.name }, set: { draft.name = $0 }))
                .textFieldStyle(.plain).font(WL.body).foregroundStyle(WL.textPrimary)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(WL.surface, in: RoundedRectangle(cornerRadius: WL.radius(5)))
                .overlay(RoundedRectangle(cornerRadius: WL.radius(5)).stroke(WL.border, lineWidth: WL.borderWidth))
                .disabled(draft.isBuiltIn)
            if draft.isBuiltIn {
                Text(loc("内置只读", "read-only")).font(WL.caption).foregroundStyle(WL.textDim)
            }
        }
    }

    private var colorSection: some View {
        sec(loc("颜色", "Colors")) {
            HStack(spacing: 18) {
                colorWell(loc("背景", "Background"), bind(\.background))
                colorWell(loc("前景", "Foreground"), bind(\.foreground))
                colorWell(loc("强调", "Accent"), bind(\.cursor))
                Spacer()
            }
            hint(loc("改这三色即可；16 色 ANSI 会自动推导。",
                    "Pick these three — the 16 ANSI colors are derived automatically."))
            ansiStrip
            DisclosureGroup(isExpanded: $advanced) {
                ansiGrid.padding(.top, 8)
            } label: {
                Text(loc("高级：逐个 ANSI 颜色", "Advanced: per-ANSI colors"))
                    .font(WL.small).foregroundStyle(WL.green)
            }
            .tint(WL.green)
        }
    }

    private var ansiStrip: some View {
        HStack(spacing: 3) {
            ForEach(0..<draft.colors.ansi.count, id: \.self) { i in
                RoundedRectangle(cornerRadius: WL.radius(2)).fill(color(draft.colors.ansi[i])).frame(height: 14)
            }
        }
        .padding(4)
        .background(color(draft.colors.background), in: RoundedRectangle(cornerRadius: WL.radius(4)))
    }

    private var ansiGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 8), spacing: 8) {
            ForEach(0..<draft.colors.ansi.count, id: \.self) { i in
                VStack(spacing: 3) {
                    ColorPicker("", selection: ansiBinding(i), supportsOpacity: false)
                        .labelsHidden()
                    Text("\(i)").font(WL.caption).foregroundStyle(WL.textDim)
                }
            }
        }
    }

    private var shapeSection: some View {
        sec(loc("形状与密度", "Shape & density")) {
            slider(loc("圆角", "Corner radius"), bindD(\.shape.radiusScale), 0, 2, "\(pct(draft.shape.radiusScale))")
            slider(loc("边框粗细", "Border width"), bindD(\.shape.borderWidth), 0, 3, String(format: "%.1f", draft.shape.borderWidth))
            HStack(spacing: 10) {
                Text(loc("密度", "Density")).font(WL.body).foregroundStyle(WL.textPrimary)
                Spacer()
                Picker("", selection: Binding(get: { draft.shape.density }, set: { draft.shape.density = $0 })) {
                    ForEach(AppTheme.Shape.Density.allCases) { d in
                        Text(loc(d.label.0, d.label.1)).tag(d)
                    }
                }.labelsHidden().fixedSize()
            }
        }
    }

    private var typeSection: some View {
        sec(loc("字体", "Typography")) {
            HStack(spacing: 10) {
                Text(loc("字型", "Design")).font(WL.body).foregroundStyle(WL.textPrimary)
                Spacer()
                Picker("", selection: Binding(get: { draft.type.design }, set: { draft.type.design = $0 })) {
                    ForEach(AppTheme.Typography.Design.allCases) { d in
                        Text(loc(d.label.0, d.label.1)).tag(d)
                    }
                }.labelsHidden().fixedSize().disabled(draft.type.fontName != nil)
            }
            HStack(spacing: 10) {
                Text(loc("字体", "Font")).font(WL.body).foregroundStyle(WL.textPrimary)
                Spacer()
                Picker("", selection: Binding(get: { draft.type.fontName }, set: { draft.type.fontName = $0 })) {
                    Text(loc("跟随字型", "Follow design")).tag(String?.none)
                    ForEach(Self.families, id: \.self) { Text($0).tag(String?.some($0)) }
                }.labelsHidden().fixedSize()
            }
            slider(loc("字号缩放", "Size scale"), bindD(\.type.sizeScale), 0.8, 1.4, "\(pct(draft.type.sizeScale))")
        }
    }

    private var backgroundSection: some View {
        sec(loc("背景", "Background")) {
            HStack(spacing: 10) {
                Text(loc("壁纸", "Wallpaper")).font(WL.body).foregroundStyle(WL.textPrimary)
                Spacer()
                Text(draft.background.imagePath.map { ($0 as NSString).lastPathComponent } ?? loc("无", "None"))
                    .font(WL.small).foregroundStyle(WL.textDim).lineLimit(1)
                BracketButton(loc("选择…", "Choose…")) { pickWallpaper() }
                if draft.background.imagePath != nil {
                    BracketButton(loc("清除", "Clear")) { draft.background.imagePath = nil }
                }
            }
            slider(loc("面板不透明度", "Panel opacity"), bindD(\.background.chromeOpacity), 0.2, 1.0, "\(pct(draft.background.chromeOpacity))")
        }
    }

    private var saveBar: some View {
        HStack(spacing: 10) {
            Spacer()
            if draft.isBuiltIn {
                Text(loc("内置主题——编辑将另存为自定义", "Built-in — saving forks a custom copy"))
                    .font(WL.caption).foregroundStyle(WL.textDim)
            }
            BracketButton(draft.isBuiltIn ? loc("另存为自定义", "Save as custom") : loc("保存", "Save")) { save() }
        }
        .padding(12)
        .background(WL.bg.opacity(0.96))
        .overlay(alignment: .top) { Rectangle().fill(WL.border).frame(height: 1) }
    }

    // MARK: actions

    private func applyLive() {
        Palette.shared.apply(draft)
        let colors: TerminalTheme? = draft.usesDefaultColors ? nil : draft.colors
        if store.terminalTheme != colors { store.terminalTheme = colors }
        dirty = true
    }

    private func newTheme() {
        var t = draft
        t.id = UUID()
        t.isBuiltIn = false
        t.name = store.uniqueThemeName(loc("自定义", "Custom"))
        draft = t
        store.upsertTheme(t)   // persist + select immediately
    }

    private func save() {
        var t = draft
        if t.isBuiltIn {
            t.isBuiltIn = false
            t.id = UUID()
            t.name = store.uniqueThemeName(t.name)
        }
        t.colors.name = t.name
        store.upsertTheme(t)
        draft = t
        dirty = false
    }

    private func deleteDraft() {
        store.deleteTheme(draft)
        draft = store.activeTheme
    }

    // MARK: JSON import / export

    /// Export a self-contained pack (theme + embedded wallpaper) as `.wltheme`.
    private func exportPack() {
        let panel = NSSavePanel()
        var types: [UTType] = [.json]
        if let t = UTType(filenameExtension: "wltheme") { types.insert(t, at: 0) }
        panel.allowedContentTypes = types
        panel.nameFieldStringValue = "\(draft.name).wltheme"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var pack = ThemePack(theme: draft)
        if let path = draft.background.imagePath,
           let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
            pack.wallpaper = data
            pack.wallpaperExt = (path as NSString).pathExtension
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(pack) { try? data.write(to: url) }
    }

    /// Import a `.wltheme` pack (or a bare theme JSON). Embedded wallpapers are
    /// written into local storage so their paths resolve on this machine.
    private func importPack() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        var types: [UTType] = [.json]
        if let t = UTType(filenameExtension: "wltheme") { types.insert(t, at: 0) }
        panel.allowedContentTypes = types
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }

        let dec = JSONDecoder()
        var theme: AppTheme
        if let pack = try? dec.decode(ThemePack.self, from: data) {
            theme = pack.theme
            if let wp = pack.wallpaper {
                let ext = (pack.wallpaperExt?.isEmpty == false) ? pack.wallpaperExt! : "png"
                let dest = ThemeStorage.dir.appendingPathComponent("\(UUID().uuidString).\(ext)")
                theme.background.imagePath = (try? wp.write(to: dest)) != nil ? dest.path : nil
            } else {
                theme.background.imagePath = nil   // sender had no portable wallpaper
            }
        } else if let bare = try? dec.decode(AppTheme.self, from: data) {
            theme = bare
            theme.background.imagePath = nil        // a bare theme can't carry a portable image
        } else {
            return
        }
        theme.id = UUID()
        theme.isBuiltIn = false
        theme.name = store.uniqueThemeName(theme.name)
        store.upsertTheme(theme)
        draft = theme
    }

    private func pickWallpaper() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK, let url = panel.url { draft.background.imagePath = url.path }
    }

    // MARK: small builders

    private func sec<V: View>(_ title: String, @ViewBuilder _ content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(WL.small.weight(.semibold)).foregroundStyle(WL.green).textCase(.uppercase)
            content()
        }
    }

    private func hint(_ t: String) -> some View {
        Text(t).font(WL.caption).foregroundStyle(WL.textDim)
    }

    private func colorWell(_ label: String, _ binding: Binding<Color>) -> some View {
        VStack(spacing: 5) {
            ColorPicker("", selection: binding, supportsOpacity: false).labelsHidden()
            Text(label).font(WL.caption).foregroundStyle(WL.textDim)
        }
    }

    private func slider(_ label: String, _ value: Binding<Double>, _ lo: Double, _ hi: Double, _ readout: String) -> some View {
        HStack(spacing: 10) {
            Text(label).font(WL.body).foregroundStyle(WL.textPrimary).frame(width: 110, alignment: .leading)
            Slider(value: value, in: lo...hi).tint(WL.green)
            Text(readout).font(WL.small).foregroundStyle(WL.textDim).frame(width: 44, alignment: .trailing)
        }
    }

    private func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

    // MARK: color bindings / conversion

    private func bind(_ key: WritableKeyPath<TerminalTheme, [Double]>) -> Binding<Color> {
        Binding(get: { color(draft.colors[keyPath: key]) },
                set: { newColor in
                    draft.colors[keyPath: key] = comps(newColor)
                    // Re-derive ANSI from the three simple picks (unless advanced editing).
                    if !advanced {
                        draft.colors = TerminalTheme.derived(
                            name: draft.name,
                            bg: draft.colors.background,
                            fg: draft.colors.foreground,
                            accent: draft.colors.cursor)
                    }
                })
    }

    private func ansiBinding(_ i: Int) -> Binding<Color> {
        Binding(get: { color(draft.colors.ansi[i]) },
                set: { draft.colors.ansi[i] = comps($0) })
    }

    private func bindD(_ key: WritableKeyPath<AppTheme, Double>) -> Binding<Double> {
        Binding(get: { draft[keyPath: key] }, set: { draft[keyPath: key] = $0 })
    }

    private func color(_ c: [Double]) -> Color {
        Color(.sRGB, red: c.count > 0 ? c[0] : 0, green: c.count > 1 ? c[1] : 0, blue: c.count > 2 ? c[2] : 0)
    }

    private func comps(_ c: Color) -> [Double] {
        let ns = (NSColor(c).usingColorSpace(.sRGB)) ?? .black
        return [Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent)]
    }

    /// All installed font families, for the custom-font picker.
    static let families: [String] = NSFontManager.shared.availableFontFamilies.sorted()
}
