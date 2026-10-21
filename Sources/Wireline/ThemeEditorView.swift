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
        WLSheet(loc("主题", "Themes"),
                subtitle: loc("修改实时预览到整个应用；保存后成为自定义主题，关闭不保存则还原",
                              "Edits preview live across the app; save to keep them, close to revert"),
                symbol: "paintpalette", width: 640, height: 600, scrolls: false,
                onClose: { dismiss() }) {
            HStack(alignment: .top, spacing: 16) {
                library
                    .frame(width: 190)
                    .frame(maxHeight: .infinity)
                    .wlCard()
                editor
            }
            .frame(maxHeight: .infinity)
        } footer: {
            Button(loc("导入主题包", "Import")) { importPack() }
                .buttonStyle(.wlSecondary)
            Button(loc("导出主题包", "Export")) { exportPack() }
                .buttonStyle(.wlSecondary)
            Spacer()
            if draft.isBuiltIn {
                Text(loc("内置主题——编辑将另存为自定义", "Built-in — saving forks a custom copy"))
                    .font(WL.caption).foregroundStyle(WL.textDim)
            }
            Button(loc("关闭", "Close")) { dismiss() }
                .buttonStyle(.wlSecondary).keyboardShortcut(.cancelAction)
            Button(draft.isBuiltIn ? loc("另存为自定义", "Save as custom") : loc("保存", "Save")) { save() }
                .buttonStyle(.wlPrimary).keyboardShortcut(.defaultAction)
        }
        .onAppear { draft = store.activeTheme }
        // Live-preview across the whole app as the draft changes.
        .onChange(of: draft) { applyLive() }
        .onDisappear { store.applyActiveTheme() }   // revert any unsaved preview
    }

    // MARK: library

    private var library: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    libGroup(loc("内置", "Built-in"), AppTheme.builtIns)
                    if !store.customThemes.isEmpty {
                        libGroup(loc("自定义", "Custom"), store.customThemes)
                    }
                }
                .padding(6)
            }
            WLFormDivider()
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
                .textCase(.uppercase).tracking(0.6).padding(.top, 6).padding(.leading, 10)
            ForEach(themes) { t in libRow(t) }
        }
    }

    private func libRow(_ t: AppTheme) -> some View {
        ThemeLibraryRow(theme: t, selected: t.name == draft.name,
                        active: store.selectedThemeName == t.name) {
            draft = t; dirty = false
        }
    }

    // MARK: editor

    private var editor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                nameSection
                colorSection
                shapeSection
                typeSection
                backgroundSection
            }
            .padding(.trailing, 2)
        }
    }

    private var nameSection: some View {
        WLFormSection("") {
            WLFormRow(loc("名称", "Name"), detail: draft.isBuiltIn ? loc("内置只读", "read-only") : nil) {
                TextField("", text: Binding(get: { draft.name }, set: { draft.name = $0 }))
                    .wlField(font: WL.body)
                    .frame(width: 200)
                    .disabled(draft.isBuiltIn)
            }
        }
    }

    private var colorSection: some View {
        WLFormSection(loc("颜色", "Colors"),
                      footer: loc("改这三色即可；16 色 ANSI 会自动推导。",
                                  "Pick these three — the 16 ANSI colors are derived automatically.")) {
            HStack(spacing: 18) {
                colorWell(loc("背景", "Background"), bind(\.background))
                colorWell(loc("前景", "Foreground"), bind(\.foreground))
                colorWell(loc("强调", "Accent"), bind(\.cursor))
                Spacer()
            }
            .padding(.vertical, 10)
            WLFormDivider()
            ansiStrip.padding(.vertical, 10)
            WLFormDivider()
            DisclosureGroup(isExpanded: $advanced) {
                ansiGrid.padding(.top, 8)
            } label: {
                Text(loc("高级：逐个 ANSI 颜色", "Advanced: per-ANSI colors"))
                    .font(WL.small).foregroundStyle(WL.green)
            }
            .tint(WL.green)
            .padding(.vertical, 10)
        }
    }

    private var ansiStrip: some View {
        HStack(spacing: 3) {
            ForEach(0..<draft.colors.ansi.count, id: \.self) { i in
                RoundedRectangle(cornerRadius: WL.radius(2)).fill(color(draft.colors.ansi[i])).frame(height: 14)
            }
        }
        .padding(4)
        .background(color(draft.colors.background), in: RoundedRectangle(cornerRadius: WL.radius(6), style: .continuous))
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
        WLFormSection(loc("形状与密度", "Shape & density")) {
            slider(loc("圆角", "Corner radius"), bindD(\.shape.radiusScale), 0, 2, "\(pct(draft.shape.radiusScale))")
            WLFormDivider()
            slider(loc("边框粗细", "Border width"), bindD(\.shape.borderWidth), 0, 3, String(format: "%.1f", draft.shape.borderWidth))
            WLFormDivider()
            WLFormRow(loc("密度", "Density")) {
                WLSegmented(selection: Binding(get: { draft.shape.density }, set: { draft.shape.density = $0 }),
                            options: AppTheme.Shape.Density.allCases.map { WLOption($0, loc($0.label.0, $0.label.1)) },
                            fill: false)
            }
        }
    }

    private var typeSection: some View {
        WLFormSection(loc("字体", "Typography")) {
            WLFormRow(loc("字型", "Design")) {
                WLMenuPicker(selection: Binding(get: { draft.type.design }, set: { draft.type.design = $0 }),
                             options: AppTheme.Typography.Design.allCases.map { WLOption($0, loc($0.label.0, $0.label.1)) })
                    .disabled(draft.type.fontName != nil)
            }
            WLFormDivider()
            WLFormRow(loc("字体", "Font")) {
                WLMenuPicker(selection: Binding(get: { draft.type.fontName }, set: { draft.type.fontName = $0 }),
                             options: [WLOption(String?.none, loc("跟随字型", "Follow design"))]
                                + FontCatalog.shared.allFamilies().map { WLOption(String?.some($0), $0) },
                             minWidth: 160)
            }
            WLFormDivider()
            slider(loc("字号缩放", "Size scale"), bindD(\.type.sizeScale), 0.8, 1.4, "\(pct(draft.type.sizeScale))")
        }
    }

    private var backgroundSection: some View {
        WLFormSection(loc("背景", "Background")) {
            WLFormRow(loc("壁纸", "Wallpaper")) {
                HStack(spacing: 10) {
                    Text(draft.background.imagePath.map { ($0 as NSString).lastPathComponent } ?? loc("无", "None"))
                        .font(WL.small).foregroundStyle(WL.textDim).lineLimit(1).truncationMode(.middle)
                    BracketButton(loc("选择…", "Choose…")) { pickWallpaper() }
                    if draft.background.imagePath != nil {
                        BracketButton(loc("清除", "Clear")) { draft.background.imagePath = nil }
                    }
                }
            }
            WLFormDivider()
            slider(loc("面板不透明度", "Panel opacity"), bindD(\.background.chromeOpacity), 0.2, 1.0, "\(pct(draft.background.chromeOpacity))")
        }
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

    private func colorWell(_ label: String, _ binding: Binding<Color>) -> some View {
        VStack(spacing: 5) {
            ColorPicker("", selection: binding, supportsOpacity: false).labelsHidden()
            Text(label).font(WL.caption).foregroundStyle(WL.textDim)
        }
    }

    private func slider(_ label: String, _ value: Binding<Double>, _ lo: Double, _ hi: Double, _ readout: String) -> some View {
        WLFormRow(label) {
            HStack(spacing: 10) {
                WLSlider(value: value, range: lo...hi, width: 150)
                Text(readout).font(WL.small).monospacedDigit().foregroundStyle(WL.textDim)
                    .frame(width: 40, alignment: .trailing)
            }
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

}

/// A theme in the editor's library: swatches, name, a check on the active one;
/// an inset rounded highlight on hover / selection, like the host drawer.
private struct ThemeLibraryRow: View {
    let theme: AppTheme
    let selected: Bool
    let active: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                HStack(spacing: -3) {
                    swatch(theme.colors.background)
                    swatch(theme.colors.cursor)
                }
                Text(theme.name).font(WL.small).foregroundStyle(selected ? WL.greenBright : WL.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if active {
                    Image(systemName: "checkmark").font(.system(size: 9)).foregroundStyle(WL.green)
                }
            }
            .wlRowHighlight(hover: hover, selected: selected)
        }
        .buttonStyle(.wlPlain)
        .wlHover($hover)
    }

    private func swatch(_ c: [Double]) -> some View {
        Circle().fill(Color(.sRGB, red: c[0], green: c[1], blue: c[2])).frame(width: 12, height: 12)
            .overlay(Circle().strokeBorder(WL.hairline, lineWidth: 1))
    }
}
