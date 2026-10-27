import SwiftUI
import AppKit
import WirelineCore

/// "Open latest answer in reader": a coding agent's last answer, lifted out of
/// the scrollback (`AgentAnswerExtractor`) and shown as Markdown in its own window.
@Observable
@MainActor
final class AgentReader {
    static let shared = AgentReader()

    struct Document: Equatable {
        var title: String
        var text: String
        var blocks: [ReaderBlock]
        var at: Date
    }

    private(set) var document: Document?
    /// The pane it came from, for Refresh.
    @ObservationIgnored private weak var source: TerminalSession?
    /// Hosted directly, so it opens from the quick terminal with no main window.
    @ObservationIgnored private var window: NSWindow?

    static func open(_ session: TerminalSession?) {
        let loc = Localizer.shared
        guard let session, session.rdp == nil else { return }
        guard shared.load(session) else {
            ConfigStore.shared.announce(loc.t("没找到 AI 的回答（支持 Claude Code、Codex）",
                                              "No agent answer found (Claude Code, Codex)"), isError: true)
            return
        }
        shared.show()
    }

    private func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 720),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Wireline Reader"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: AgentReaderView().environment(Localizer.shared))
            w.center()
            w.setFrameAutosaveName("WirelineReader")
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func refresh() {
        guard let source else { return }
        _ = load(source)
    }

    @discardableResult
    private func load(_ session: TerminalSession) -> Bool {
        let agent = IslandCenter.shared.agent(in: session.id)
        let rendered = session.terminalView.renderedBuffer
        // Empty on the alternate screen: fall back to the recent output.
        let screen = rendered.isEmpty ? session.recentOutput : String(decoding: rendered, as: UTF8.self)
        guard let text = AgentAnswerExtractor.latestAnswer(in: screen, agent: agent) else { return false }
        source = session
        document = Document(title: [agent?.displayName, session.title].compactMap { $0 }.joined(separator: " · "),
                            text: text, blocks: ReaderBlock.parse(text), at: Date())
        return true
    }
}

/// The main window's paste-confirm card.
struct TerminalAssists: ViewModifier {
    func body(content: Content) -> some View {
        content.modifier(PasteConfirmModal())
    }
}

struct AgentReaderView: View {
    @Environment(Localizer.self) private var loc
    @State private var reader = AgentReader.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            WLFormDivider()
            if let doc = reader.document {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(doc.blocks.enumerated()), id: \.offset) { _, block in
                            ReaderBlockView(block: block)
                        }
                    }
                    .textSelection(.enabled)
                    .padding(20)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            } else {
                Text(loc("在运行 Claude Code / Codex 的终端里右键 → 在阅读器中打开最近回答",
                         "In a terminal running Claude Code / Codex: right-click → Open Latest Answer in Reader"))
                    .font(WL.small).foregroundStyle(WL.textDim)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 420, minHeight: 360)
        .background(WL.bg)
        .preferredColorScheme(WL.colorScheme)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.richtext").foregroundStyle(WL.green)
            VStack(alignment: .leading, spacing: 1) {
                Text(loc("最近回答", "Latest Answer")).font(WL.mono(13, .semibold)).foregroundStyle(WL.textPrimary)
                if let doc = reader.document {
                    Text(doc.title + " · " + doc.at.formatted(date: .omitted, time: .shortened))
                        .font(WL.caption).foregroundStyle(WL.textDim).lineLimit(1)
                }
            }
            Spacer()
            if let doc = reader.document {
                Button { reader.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.wlIcon(size: 26)).help(loc("重新读取", "Reload"))
                Button { copy(doc.text) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.wlIcon(size: 26)).help(loc("复制全文", "Copy all"))
            }
        }
        .padding(.leading, 78).padding(.trailing, 14).frame(height: 44)
    }
}

private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

private struct ReaderBlockView: View {
    @Environment(Localizer.self) private var loc
    let block: ReaderBlock
    @State private var copied = false

    var body: some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text))
                .font(WL.mono(level <= 1 ? 20 : level == 2 ? 17 : 15, .bold))
                .foregroundStyle(WL.textPrimary)
                .padding(.top, 4)
        case .prose(let text):
            Text(inline(text))
                .font(WL.mono(14)).foregroundStyle(WL.textPrimary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .code(let language, let text):
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(language ?? "").font(WL.caption).foregroundStyle(WL.textDim)
                    Spacer()
                    BracketButton(copied ? loc("已复制", "Copied") : loc("复制", "Copy")) {
                        copy(text)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    }
                }
                .padding(.horizontal, 10).padding(.top, 6)
                ScrollView(.horizontal) {
                    Text(text)
                        .font(.system(size: 12.5, design: .monospaced)).foregroundStyle(WL.textPrimary)
                        .fixedSize()
                        .padding(10)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WL.textPrimary.opacity(WL.isLight ? 0.04 : 0.06),
                        in: RoundedRectangle(cornerRadius: WL.radius(10), style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: WL.radius(10), style: .continuous).strokeBorder(WL.hairline, lineWidth: 1))
        }
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}
