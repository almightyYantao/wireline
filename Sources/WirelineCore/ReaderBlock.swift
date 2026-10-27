import Foundation

/// An agent answer split for display: headings, prose (inline Markdown) and
/// code. Code is a fenced block, or — since Claude Code prints code without
/// its fences — a run of lines indented past the text that isn't a list
/// item's continuation.
public enum ReaderBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case prose(String)
    case code(language: String?, text: String)

    public static func parse(_ text: String) -> [ReaderBlock] {
        var out: [ReaderBlock] = []
        var prose: [String] = []
        var code: [String] = []
        var fence: String?
        var inList = false

        func flushProse() {
            if !prose.isEmpty { out.append(.prose(joinProse(prose))) }
            prose = []
        }
        func flushCode(_ lang: String?) {
            while code.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { code.removeLast() }
            let indent = code.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { $0.prefix { $0 == " " }.count }.min() ?? 0
            if !code.isEmpty {
                out.append(.code(language: lang, text: code.map { String($0.dropFirst(min(indent, $0.count))) }
                    .joined(separator: "\n")))
            }
            code = []
        }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let lang = fence {
                if trimmed.hasPrefix("```") { flushCode(lang.isEmpty ? nil : lang); fence = nil } else { code.append(line) }
                continue
            }
            if trimmed.hasPrefix("```") {
                flushProse()
                flushCode(nil)
                fence = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                continue
            }
            if trimmed.isEmpty {
                if code.isEmpty { flushProse() } else { code.append("") }
                inList = false
                continue
            }
            let indent = line.prefix { $0 == " " }.count
            if indent >= 2, !inList || indent >= 6 {
                flushProse()
                code.append(line)
                continue
            }
            flushCode(nil)
            if indent == 0 { inList = isListItem(trimmed) }
            let hashes = trimmed.prefix { $0 == "#" }.count
            if indent == 0, (1...6).contains(hashes), trimmed.dropFirst(hashes).first == " " {
                flushProse()
                out.append(.heading(level: hashes, text: String(trimmed.dropFirst(hashes + 1))))
                continue
            }
            prose.append(line)
        }
        flushCode(fence.flatMap { $0.isEmpty ? nil : $0 })
        flushProse()
        return out
    }

    static func isListItem(_ s: String) -> Bool {
        s.range(of: #"^([-*+•]|\d+[.)])\s"#, options: .regularExpression) != nil
    }

    /// Hard-wrapped lines back into paragraphs; list items stay on their own lines.
    static func joinProse(_ lines: [String]) -> String {
        var out: [String] = []
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if let last = out.last, !isListItem(t) {
                let cjk = last.unicodeScalars.last.map(isCJK) == true && t.unicodeScalars.first.map(isCJK) == true
                out[out.count - 1] = last + (cjk ? "" : " ") + t
            } else {
                out.append(line.hasPrefix(" ") ? "  " + t : t)
            }
        }
        return out.joined(separator: "\n")
    }

    private static func isCJK(_ u: Unicode.Scalar) -> Bool {
        (0x2E80...0x9FFF).contains(u.value) || (0xFF00...0xFFEF).contains(u.value)
    }
}
