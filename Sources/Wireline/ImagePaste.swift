import AppKit

/// ⌘V with a screenshot on the clipboard: the image becomes a PNG file and the
/// terminal gets its path — what coding agents (Claude Code, Codex) read.
/// Local shells get a file under Caches; SSH sessions get one uploaded to the
/// host's /tmp over SFTP.
@MainActor
enum ImagePaste {
    /// The clipboard's image as PNG — only when it carries no text, so copying
    /// from a rich-text app still pastes the text.
    static func png(from pb: NSPasteboard = .general) -> Data? {
        guard pb.string(forType: .string) == nil else { return nil }
        if let png = pb.data(forType: .png) { return png }
        guard let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    static func fileName(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return "wireline-paste-\(f.string(from: date)).png"
    }

    static var localDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wireline/Pasted", isDirectory: true)
    }

    static func saveLocal(_ png: Data) throws -> String {
        let dir = localDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(fileName())
        try png.write(to: url)
        return url.path
    }

    /// `path` as one shell word, plus a space to keep typing after it.
    static func typed(_ path: String) -> String {
        let safe = path.allSatisfy { $0.isLetter || $0.isNumber || "/._-+@:".contains($0) }
        let word = safe ? path : "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return word + " "
    }
}
