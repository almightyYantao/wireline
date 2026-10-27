import SwiftUI
import AppKit

/// When a multi-line ⌘V asks first.
enum PasteConfirmPolicy: String, CaseIterable {
    case always
    /// Not when the program has bracketed paste on (Claude Code, editors):
    /// it gets the text as one paste, so a newline can't run anything.
    case unlessBracketed
    case never

    static let defaultsKey = "pasteConfirm"

    static var current: PasteConfirmPolicy {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(PasteConfirmPolicy.init) ?? .unlessBracketed
    }

    func shouldAsk(_ text: String, bracketed: Bool) -> Bool {
        guard text.contains(where: \.isNewline) else { return false }
        switch self {
        case .always: return true
        case .unlessBracketed: return !bracketed
        case .never: return false
        }
    }
}

extension Notification.Name {
    /// The paste-confirm policy changed (libghostty views rebuild their config).
    static let pasteConfirmPolicyChanged = Notification.Name("wireline.pasteConfirmPolicyChanged")
}

enum PasteChoice { case paste, singleLine, cancel }

struct PasteRequest: Identifiable {
    let id = UUID()
    let text: String
    /// Asked from the quick terminal's panel, not the main window.
    let quick: Bool
    fileprivate let answer: (PasteChoice) -> Void
}

/// One pending multi-line paste at a time; a second ⌘V while one is open is
/// dropped (cancelled).
@Observable
@MainActor
final class PasteConfirmCenter {
    static let shared = PasteConfirmCenter()

    private(set) var current: PasteRequest?

    func ask(_ text: String, from view: NSView, answer: @escaping (PasteChoice) -> Void) {
        guard current == nil else { return answer(.cancel) }
        current = PasteRequest(text: text, quick: view.window is QuickTerminalPanel, answer: answer)
    }

    func answer(_ choice: PasteChoice) {
        guard let r = current else { return }
        current = nil
        r.answer(choice)
    }

    /// Newlines (CRLF included) become single spaces; trailing ones go.
    static func singleLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .newlines)
            .components(separatedBy: .newlines)
            .joined(separator: " ")
    }
}

struct PasteConfirmModal: ViewModifier {
    var quick = false
    @State private var center = PasteConfirmCenter.shared

    func body(content: Content) -> some View {
        content.wlModal(item: Binding(get: { center.current.flatMap { $0.quick == quick ? $0 : nil } },
                                      set: { if $0 == nil { center.answer(.cancel) } })) { r in
            PasteConfirmSheet(text: r.text) { center.answer($0) }
        }
    }
}

private struct PasteConfirmSheet: View {
    @Environment(Localizer.self) private var loc
    let text: String
    let decide: (PasteChoice) -> Void

    private var lineCount: Int {
        text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .newlines)
            .components(separatedBy: .newlines).count
    }

    var body: some View {
        WLSheet(loc("粘贴多行文本？", "Paste multiple lines?"),
                subtitle: loc("共 \(lineCount) 行 · 每个换行都可能被当作回车执行", "\(lineCount) lines · each newline may run as Return"),
                symbol: "doc.on.clipboard", width: 600, scrolls: false, onClose: { decide(.cancel) }) {
            ScrollView([.vertical, .horizontal]) {
                Text(text)
                    .font(WL.mono(12)).foregroundStyle(WL.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize()
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(10)
            }
            .frame(minHeight: 80, maxHeight: 320)
            .background(WL.textPrimary.opacity(WL.isLight ? 0.04 : 0.06),
                        in: RoundedRectangle(cornerRadius: WL.radius(10), style: .continuous))
            .padding(16)
        } footer: {
            Spacer()
            Button(loc("取消", "Cancel")) { decide(.cancel) }
                .buttonStyle(.wlSecondary).keyboardShortcut(.cancelAction)
            Button(loc("粘贴为单行", "Paste as One Line")) { decide(.singleLine) }
                .buttonStyle(.wlSecondary)
            Button(loc("粘贴", "Paste")) { decide(.paste) }
                .buttonStyle(.wlPrimary).keyboardShortcut(.defaultAction)
        }
    }
}
