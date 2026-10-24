import SwiftUI
import AppKit
import WirelineCore

/// Dual-pane SFTP browser: remote host on the left, local filesystem on the
/// right. Drag a row to the other pane (or double-click a file) to transfer.
struct FileBrowserView: View {
    @Environment(HostStore.self) private var store
    @Environment(SessionStore.self) private var sessions
    @Environment(Localizer.self) private var loc
    let host: Host
    var onClose: () -> Void

    @State private var model: FileBrowserModel?
    @State private var local = LocalBrowserModel()
    @State private var password = ""
    @State private var remoteSel: String?
    @State private var localSel: String?
    @State private var showMkdir = false
    @State private var renaming: SFTPEntry?
    @State private var aiEditEntry: SFTPEntry?

    var body: some View {
        VStack(spacing: 0) {
            // The two sides are cards side by side, like split panes.
            HStack(spacing: wlPaneGap) {
                remotePane.frame(maxWidth: .infinity).fileCard()
                localPane.frame(maxWidth: .infinity).fileCard()
            }
            .padding([.horizontal, .top], 12)
            .padding(.bottom, hasFooter ? 0 : 12)
            if let s = model?.status {
                Text(s).font(WL.small).foregroundStyle(WL.textDim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18).padding(.vertical, 7)
            }
            if !edits.isEmpty { RemoteEditStrip(edits: edits).padding(.horizontal, 12).padding(.top, 8) }
            if let model, !model.transfers.items.isEmpty {
                TransferPanel(queue: model.transfers).padding(.horizontal, 12).padding(.top, 8)
            }
            if hasFooter { Spacer().frame(height: 12) }
        }
        .task(id: host.alias) {
            let m = FileBrowserModel.obtain(host: host, store: store)
            m.onTransferComplete = { local.reload() }
            model = m
            // Open where the terminal on this host is (unless something asked
            // for a specific path, like a ⌘-clicked one).
            if FileBrowserModel.pendingPath[host.alias] == nil, !m.connected, let dir = terminalDirectory {
                FileBrowserModel.pendingPath[host.alias] = dir
            }
            m.connect()
        }
        .onDisappear { model?.release() }
        .wlModal(isPresented: $showMkdir) {
            WLPromptSheet(title: loc("新建文件夹", "New Folder"), subtitle: host.alias + " · " + (model?.path ?? ""),
                          symbol: "folder.badge.plus", label: loc("名称", "Name"),
                          confirmTitle: loc("创建", "Create")) { name in
                model?.makeDirectory(name)
            }
        }
        .wlModal(item: $renaming) { entry in
            WLPromptSheet(title: loc("重命名", "Rename"), subtitle: host.alias + " · " + entry.name,
                          symbol: "pencil", label: loc("新名称", "New name"),
                          confirmTitle: loc("重命名", "Rename"), initial: entry.name) { name in
                model?.rename(entry, to: name)
            }
        }
        .wlModal(item: $aiEditEntry) { entry in
            if let m = model {
                AIFileEditView(model: m, entry: entry, hostName: host.alias) {
                    wlAnimate(Motion.flipOut) { aiEditEntry = nil }
                }
            }
        }
    }

    private var edits: [RemoteEditStore.Edit] { RemoteEditStore.shared.edits(for: host.alias) }
    private var hasFooter: Bool {
        model?.status != nil || !edits.isEmpty || !(model?.transfers.items.isEmpty ?? true)
    }

    /// Where a terminal on this host is right now (the focused one first).
    private var terminalDirectory: String? {
        let onHost = sessions.sessions.filter { s in
            if case .ssh = s.kind { return s.alias == host.alias && s.remoteDirectory != nil }
            return false
        }
        let active = onHost.first { $0.id == sessions.activeID }
        return (active ?? onHost.first)?.remoteDirectory
    }

    // MARK: Remote pane

    private var remotePane: some View {
        VStack(spacing: 0) {
            paneHeader(title: loc("远程 · \(host.alias)", "Remote · \(host.alias)"), symbol: "server.rack", crumbs: model?.breadcrumbs.map { ($0.name, $0.path) } ?? [],
                       onCrumb: { model?.go(to: $0) }, onUp: { model?.goUp() }) {
                if let dir = terminalDirectory, model?.connected == true {
                    BracketButton(loc("终端目录", "Terminal Dir")) { model?.reveal(dir) }
                        .help(loc("跳到终端当前所在的目录：\(dir)", "Go to the terminal's directory: \(dir)"))
                }
                BracketButton(loc("新建文件夹", "New Folder")) { showMkdir = true }
                BracketButton(loc("刷新", "Refresh")) { model?.refresh() }
                BracketButton(loc("断开", "Disconnect")) { model?.disconnect(); onClose() }
            }
            WLFormDivider()
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
                    LazyVStack(spacing: 1) {
                        ForEach(model.entries) { entry in remoteRow(entry, model: model) }
                    }
                    .padding(6)
                }
            }
        }
    }

    private func remoteMenu(_ entry: SFTPEntry, model: FileBrowserModel) -> [WLMenuItem] {
        let download = WLMenuItem.item(loc("下载到本地 →", "Download →"), systemImage: "arrow.down.circle") {
            model.download(entry, toDirectory: local.url)
        }
        var items: [WLMenuItem]
        if entry.isDir {
            items = [.item(loc("打开", "Open"), systemImage: "folder") { model.open(entry) }, download]
        } else {
            let editors = RemoteEditStore.installedEditors()
            let preferred = RemoteEditStore.preferredEditor
            items = [
                download,
                .item(loc("用本地编辑器打开", "Edit Locally"), systemImage: "square.and.pencil") {
                    model.editLocally(entry, with: nil)
                },
            ]
            if !editors.isEmpty {
                items.append(.submenu(loc("打开方式", "Open With"), systemImage: "app", editors.map { editor in
                    .item(editor.name, checked: editor == preferred) { model.editLocally(entry, with: editor) }
                }))
            }
            items.append(.item(loc("AI 改…", "AI edit…"), systemImage: "sparkles") { aiEditEntry = entry })
        }
        return items + [
            .item(loc("重命名…", "Rename…"), systemImage: "pencil") { renaming = entry },
            .divider,
            .item(loc("删除", "Delete"), systemImage: "trash", destructive: true) { model.delete(entry) },
        ]
    }

    @ViewBuilder
    private func remoteRow(_ entry: SFTPEntry, model: FileBrowserModel) -> some View {
        let row = EntryRow(icon: entry.isDir ? "folder.fill" : "doc",
                           iconColor: entry.isDir ? WL.purple : WL.textDim,
                           name: entry.name,
                           detail: entry.isDir ? "" : humanSize(entry.size),
                           selected: remoteSel == entry.id)
            .draggable("R:\(entry.name)")
            .wlContextMenu(remoteMenu(entry, model: model))
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
            paneHeader(title: loc("本地", "Local"), symbol: "desktopcomputer", crumbs: local.breadcrumbs.map { ($0.name, $0.url.path) },
                       onCrumb: { local.go(to: URL(fileURLWithPath: $0)) }, onUp: { local.goUp() }) {
                BracketButton(loc("刷新", "Refresh")) { local.reload() }
            }
            WLFormDivider()
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(local.entries) { entry in localRow(entry) }
                }
                .padding(6)
            }
        }
        .dropDestination(for: String.self) { items, _ in
            var handled = false
            for item in items where item.hasPrefix("R:") {
                let name = String(item.dropFirst(2))
                if let e = model?.entries.first(where: { $0.name == name }) {
                    model?.download(e, toDirectory: local.url); handled = true
                }
            }
            return handled
        }
    }

    private func localMenu(_ entry: LocalEntry) -> [WLMenuItem] {
        let open: [WLMenuItem] = entry.isDir ? [.item(loc("打开", "Open"), systemImage: "folder") { local.open(entry) }] : []
        return open + [
            .item(loc("上传到远程 ←", "Upload ←"), systemImage: "arrow.up.circle") { model?.upload(from: entry.url) },
            .item(loc("在 Finder 中显示", "Reveal in Finder"), systemImage: "magnifyingglass") {
                NSWorkspace.shared.activateFileViewerSelecting([entry.url])
            },
        ]
    }

    @ViewBuilder
    private func localRow(_ entry: LocalEntry) -> some View {
        let row = EntryRow(icon: entry.isDir ? "folder.fill" : "doc",
                           iconColor: entry.isDir ? WL.teal : WL.textDim,
                           name: entry.name,
                           detail: entry.isDir ? "" : humanSize(entry.size),
                           selected: localSel == entry.id)
            .draggable("L:\(entry.url.path)")
            .wlContextMenu(localMenu(entry))
        row.onTapGesture { localSel = entry.id }
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                localSel = entry.id
                if entry.isDir { local.open(entry) } else { model?.upload(from: entry.url) }
            })
    }

    // MARK: Shared pieces

    private func paneHeader<Trailing: View>(title: String, symbol: String, crumbs: [(String, String)],
                                            onCrumb: @escaping (String) -> Void,
                                            onUp: @escaping () -> Void,
                                            @ViewBuilder trailing: () -> Trailing) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(WL.textDim)
                Text(title).font(WL.small.weight(.semibold)).foregroundStyle(WL.textPrimary).lineLimit(1)
                Spacer()
                trailing()
            }
            HStack(spacing: 6) {
                Button(action: onUp) {
                    Image(systemName: "arrow.up").font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.wlIcon(size: 22))
                .help(Localizer.shared.t("上一级", "Up one level"))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 3) {
                        ForEach(crumbs, id: \.1) { crumb in
                            Button { onCrumb(crumb.1) } label: {
                                Text(crumb.0).font(WL.small).foregroundStyle(WL.textPrimary)
                            }.buttonStyle(.wlPlain)
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
                .frame(width: 196)
                .wlField(font: WL.body)
                .onSubmit { model.connect(withPassword: password); password = "" }
            Button(loc("连接", "Connect")) { model.connect(withPassword: password); password = "" }
                .buttonStyle(.wlPrimary)
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
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        // An inset rounded highlight, like the host drawer's rows.
        .background(
            RoundedRectangle(cornerRadius: WL.radius(8), style: .continuous)
                .fill(selected ? WL.green.opacity(0.14) : WL.textPrimary.opacity(hover ? 0.055 : 0))
        )
        .contentShape(Rectangle())
        .animation(Motion.hover, value: hover)
        .wlHover($hover)
    }
}

private extension View {
    /// One side of the file browser: a raised card, its list clipped to it.
    func fileCard() -> some View {
        let shape = RoundedRectangle(cornerRadius: WL.radius(12), style: .continuous)
        return clipShape(shape).wlCard()
    }
}

/// Remote files open in a local editor, syncing on save.
private struct RemoteEditStrip: View {
    let edits: [RemoteEditStore.Edit]
    @Environment(Localizer.self) private var loc

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(edits) { e in
                HStack(spacing: 8) {
                    Image(systemName: "square.and.pencil").font(.system(size: 11)).foregroundStyle(WL.green)
                    Text(e.remotePath).font(WL.small).foregroundStyle(WL.textPrimary).lineLimit(1).truncationMode(.middle)
                    Text(state(e)).font(WL.caption).foregroundStyle(e.error == nil ? WL.textDim : WL.red).lineLimit(1)
                    Spacer()
                    BracketButton(loc("停止同步", "Stop")) { RemoteEditStore.shared.stop(e.id) }
                        .help(loc("不再把本地保存写回服务器（本地副本会删除）", "Stop copying saves back (the local copy is deleted)"))
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .wlCard()
    }

    private func state(_ e: RemoteEditStore.Edit) -> String {
        if e.syncing { return loc("同步中…", "Saving…") }
        if e.error != nil { return loc("写回失败", "Save failed") }
        if let t = e.lastSynced {
            return loc("已同步 ", "Saved ") + t.formatted(date: .omitted, time: .shortened)
        }
        return loc("保存后自动写回", "Saves sync back")
    }
}

/// The transfer queue under the panes.
private struct TransferPanel: View {
    let queue: TransferQueue
    @Environment(Localizer.self) private var loc

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                let running = queue.items.filter { $0.state == .running || $0.state == .queued }.count
                Text(running > 0 ? loc("传输 · \(running) 个进行中", "Transfers · \(running) active")
                                 : loc("传输", "Transfers"))
                    .font(WL.small.weight(.semibold)).foregroundStyle(WL.textPrimary)
                Spacer()
                if queue.items.contains(where: { $0.state == .done }) {
                    BracketButton(loc("清除已完成", "Clear Finished")) { queue.clearFinished() }
                }
            }
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(queue.items) { item in row(item) }
                }
            }
            .frame(maxHeight: 150)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .wlCard()
    }

    private func row(_ item: TransferQueue.Item) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.direction == .upload ? "arrow.up" : "arrow.down")
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(WL.textDim).frame(width: 12)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(item.name).font(WL.small).foregroundStyle(WL.textPrimary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(detail(item)).font(WL.caption)
                        .foregroundStyle(isFailed(item) ? WL.red : WL.textDim).lineLimit(1)
                }
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(WL.textPrimary.opacity(0.08))
                        Capsule().fill(isFailed(item) ? WL.red : WL.green)
                            .frame(width: max(0, g.size.width * item.fraction))
                    }
                }
                .frame(height: 3)
                .animation(Motion.state, value: item.fraction)
            }
            switch item.state {
            case .queued, .running:
                Button { queue.pause(item.id) } label: { Image(systemName: "pause.fill").font(.system(size: 9)) }
                    .buttonStyle(.wlIcon).help(loc("暂停", "Pause"))
            case .paused, .failed:
                Button { queue.resume(item.id) } label: { Image(systemName: "play.fill").font(.system(size: 9)) }
                    .buttonStyle(.wlIcon).help(loc("继续（从断点）", "Resume"))
            case .done:
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(WL.green)
                    .frame(width: 22)
            }
            Button { queue.remove(item.id) } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                .buttonStyle(.wlIcon).help(loc("移除", "Remove"))
        }
    }

    private func isFailed(_ item: TransferQueue.Item) -> Bool {
        if case .failed = item.state { return true }
        return false
    }

    private func detail(_ item: TransferQueue.Item) -> String {
        let bytes = ByteCountFormatter.string(fromByteCount: Int64(item.done), countStyle: .file)
            + " / " + ByteCountFormatter.string(fromByteCount: Int64(item.total), countStyle: .file)
        switch item.state {
        case .queued:          return loc("等待中", "Queued")
        case .running:         return bytes
        case .paused:          return loc("已暂停 · ", "Paused · ") + bytes
        case .done:            return ByteCountFormatter.string(fromByteCount: Int64(item.total), countStyle: .file)
        case .failed(let msg): return msg
        }
    }
}
