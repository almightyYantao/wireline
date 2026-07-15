import SwiftUI
import AppKit
import WirelineCore

/// Dual-pane SFTP browser: remote host on the left, local filesystem on the
/// right. Drag a row to the other pane (or double-click a file) to transfer.
struct FileBrowserView: View {
    @Environment(HostStore.self) private var store
    @Environment(Localizer.self) private var loc
    let host: Host
    var onClose: () -> Void

    @State private var model: FileBrowserModel?
    @State private var local = LocalBrowserModel()
    @State private var password = ""
    @State private var remoteSel: String?
    @State private var localSel: String?
    @State private var showMkdir = false
    @State private var newName = ""
    @State private var renaming: SFTPEntry?
    @State private var renameText = ""
    @State private var aiEditEntry: SFTPEntry?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                remotePane.frame(maxWidth: .infinity)
                Rectangle().fill(WL.border).frame(width: 1)
                localPane.frame(maxWidth: .infinity)
            }
            if let s = model?.status {
                Rectangle().fill(WL.border).frame(height: 1)
                Text(s).font(WL.small).foregroundStyle(WL.textDim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 6)
            }
        }
        .task(id: host.alias) {
            let m = FileBrowserModel(host: host, store: store)
            m.onTransferComplete = { local.reload() }
            model = m
            m.connect()
        }
        .onDisappear { model?.disconnect() }
        .alert(loc("新建文件夹", "New Folder"), isPresented: $showMkdir) {
            TextField(loc("名称", "Name"), text: $newName)
            Button(loc("创建", "Create")) { model?.makeDirectory(newName); newName = "" }
            Button(loc("取消", "Cancel"), role: .cancel) { newName = "" }
        }
        .alert(loc("重命名", "Rename"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(loc("新名称", "New name"), text: $renameText)
            Button(loc("确定", "OK")) { if let e = renaming { model?.rename(e, to: renameText) }; renaming = nil }
            Button(loc("取消", "Cancel"), role: .cancel) { renaming = nil }
        }
        .sheet(item: $aiEditEntry) { entry in
            if let m = model {
                AIFileEditView(model: m, entry: entry, hostName: host.alias) { aiEditEntry = nil }
                    .environment(loc)
            }
        }
    }

    // MARK: Remote pane

    private var remotePane: some View {
        VStack(spacing: 0) {
            paneHeader(title: loc("远程 · \(host.alias)", "Remote · \(host.alias)"), crumbs: model?.breadcrumbs.map { ($0.name, $0.path) } ?? [],
                       onCrumb: { model?.go(to: $0) }, onUp: { model?.goUp() }) {
                BracketButton(loc("新建文件夹", "New Folder")) { newName = ""; showMkdir = true }
                BracketButton(loc("刷新", "Refresh")) { model?.refresh() }
                BracketButton(loc("断开", "Disconnect")) { model?.disconnect(); onClose() }
            }
            Rectangle().fill(WL.border).frame(height: 1)
            remoteBody
        }
        .dropDestination(for: String.self) { items, _ in
            var handled = false
            for item in items where item.hasPrefix("L:") {
                model?.upload(from: URL(fileURLWithPath: String(item.dropFirst(2))))
                handled = true
            }
            return handled
        }
    }

    @ViewBuilder
    private var remoteBody: some View {
        if let model {
            if model.needsPassword {
                passwordPrompt(model).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.connecting && model.entries.isEmpty {
                Text(loc("连接中…", "Connecting…")).font(WL.body).foregroundStyle(WL.textDim)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.entries) { entry in remoteRow(entry, model: model) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func remoteRow(_ entry: SFTPEntry, model: FileBrowserModel) -> some View {
        let row = EntryRow(icon: entry.isDir ? "folder.fill" : "doc",
                           iconColor: entry.isDir ? WL.purple : WL.textDim,
                           name: entry.name,
                           detail: entry.isDir ? "" : humanSize(entry.size),
                           selected: remoteSel == entry.id)
            .draggable("R:\(entry.name)")
            .wlContextMenu([
                entry.isDir
                    ? .item(loc("打开", "Open"), systemImage: "folder") { model.open(entry) }
                    : .item(loc("下载到本地 →", "Download →"), systemImage: "arrow.down.circle") { model.download(entry, toDirectory: local.url) },
                entry.isDir
                    ? .divider
                    : .item(loc("AI 改…", "AI edit…"), systemImage: "sparkles") { aiEditEntry = entry },
                .item(loc("重命名…", "Rename…"), systemImage: "pencil") { renameText = entry.name; renaming = entry },
                .divider,
                .item(loc("删除", "Delete"), systemImage: "trash", destructive: true) { model.delete(entry) }
            ])
        // Single click selects immediately; double click opens (dir) or downloads (file).
        row.onTapGesture { remoteSel = entry.id }
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                remoteSel = entry.id
                if entry.isDir { model.open(entry) } else { model.download(entry, toDirectory: local.url) }
            })
    }

    // MARK: Local pane

    private var localPane: some View {
        VStack(spacing: 0) {
            paneHeader(title: loc("本地", "Local"), crumbs: local.breadcrumbs.map { ($0.name, $0.url.path) },
                       onCrumb: { local.go(to: URL(fileURLWithPath: $0)) }, onUp: { local.goUp() }) {
                BracketButton(loc("刷新", "Refresh")) { local.reload() }
            }
            Rectangle().fill(WL.border).frame(height: 1)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(local.entries) { entry in localRow(entry) }
                }
            }
        }
        .dropDestination(for: String.self) { items, _ in
            var handled = false
            for item in items where item.hasPrefix("R:") {
                let name = String(item.dropFirst(2))
                if let e = model?.entries.first(where: { $0.name == name && !$0.isDir }) {
                    model?.download(e, toDirectory: local.url); handled = true
                }
            }
            return handled
        }
    }

    @ViewBuilder
    private func localRow(_ entry: LocalEntry) -> some View {
        let row = EntryRow(icon: entry.isDir ? "folder.fill" : "doc",
                           iconColor: entry.isDir ? WL.teal : WL.textDim,
                           name: entry.name,
                           detail: entry.isDir ? "" : humanSize(entry.size),
                           selected: localSel == entry.id)
            .draggable("L:\(entry.url.path)")
            .wlContextMenu([
                entry.isDir
                    ? .item(loc("打开", "Open"), systemImage: "folder") { local.open(entry) }
                    : .item(loc("上传到远程 ←", "Upload ←"), systemImage: "arrow.up.circle") { model?.upload(from: entry.url) },
                .item(loc("在 Finder 中显示", "Reveal in Finder"), systemImage: "magnifyingglass") {
                    NSWorkspace.shared.activateFileViewerSelecting([entry.url])
                }
            ])
        row.onTapGesture { localSel = entry.id }
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                localSel = entry.id
                if entry.isDir { local.open(entry) } else { model?.upload(from: entry.url) }
            })
    }

    // MARK: Shared pieces

    private func paneHeader<Trailing: View>(title: String, crumbs: [(String, String)],
                                            onCrumb: @escaping (String) -> Void,
                                            onUp: @escaping () -> Void,
                                            @ViewBuilder trailing: () -> Trailing) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(WL.small.weight(.semibold)).foregroundStyle(WL.green)
                Spacer()
                trailing()
            }
            HStack(spacing: 8) {
                BracketButton("↑") { onUp() }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 3) {
                        ForEach(crumbs, id: \.1) { crumb in
                            Button { onCrumb(crumb.1) } label: {
                                Text(crumb.0).font(WL.small).foregroundStyle(WL.textPrimary)
                            }.buttonStyle(.plain)
                            Text("/").font(WL.small).foregroundStyle(WL.textDim)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    private func passwordPrompt(_ model: FileBrowserModel) -> some View {
        VStack(spacing: 12) {
            Text(loc("需要密码", "Password required")).font(WL.mono(16, .bold)).foregroundStyle(WL.green)
            Text("\(host.user ?? "")@\(host.connectHostname)").font(WL.small).foregroundStyle(WL.textDim)
            SecureField(loc("密码", "Password"), text: $password)
                .textFieldStyle(.plain).font(WL.body).foregroundStyle(WL.textPrimary)
                .padding(.horizontal, 10).padding(.vertical, 8).frame(width: 220)
                .background(WL.surface, in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(WL.border, lineWidth: 1))
                .onSubmit { model.connect(withPassword: password); password = "" }
            Button { model.connect(withPassword: password); password = "" } label: {
                Text("[\(loc("连接", "Connect"))]").font(WL.small).foregroundStyle(WL.green)
            }.buttonStyle(.plain)
        }
    }

    private func humanSize(_ bytes: UInt64) -> String {
        let units = ["B", "K", "M", "G", "T"]
        var v = Double(bytes); var i = 0
        while v >= 1024, i < units.count - 1 { v /= 1024; i += 1 }
        return i == 0 ? "\(bytes)B" : String(format: "%.1f%@", v, units[i])
    }
}

/// A single file/folder row shared by both panes.
struct EntryRow: View {
    let icon: String
    let iconColor: Color
    let name: String
    let detail: String
    let selected: Bool
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(iconColor).font(.system(size: 12))
            Text(name).font(WL.body).foregroundStyle(selected ? WL.greenBright : WL.textPrimary)
                .lineLimit(1)
            Spacer()
            if !detail.isEmpty { Text(detail).font(WL.caption).foregroundStyle(WL.textDim) }
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? WL.green.opacity(0.16) : (hover ? WL.surface : .clear))
        .overlay(alignment: .leading) {
            Rectangle().fill(WL.green).frame(width: 2).opacity(selected ? 1 : 0)
        }
        .overlay(alignment: .bottom) { Rectangle().fill(WL.border.opacity(0.4)).frame(height: 1) }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}
