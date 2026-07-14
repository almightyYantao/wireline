import Foundation
import Observation

/// A local filesystem entry.
struct LocalEntry: Identifiable, Sendable {
    var id: String { url.path }
    let name: String
    let isDir: Bool
    let size: UInt64
    let url: URL
}

/// Drives the local (right-hand) pane of the file browser.
@Observable
@MainActor
final class LocalBrowserModel {
    private(set) var url: URL
    private(set) var entries: [LocalEntry] = []

    init(start: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.url = start
        reload()
    }

    func reload() {
        let dir = url
        // Read the directory off the main thread so navigation stays snappy.
        Task {
            let items = await Task.detached(priority: .userInitiated) { Self.scan(dir) }.value
            if url == dir { entries = items }
        }
    }

    nonisolated private static func scan(_ dir: URL) -> [LocalEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        let items = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return items.map { u in
            let vals = try? u.resourceValues(forKeys: Set(keys))
            return LocalEntry(name: u.lastPathComponent,
                              isDir: vals?.isDirectory ?? false,
                              size: UInt64(vals?.fileSize ?? 0),
                              url: u)
        }
        .sorted { ($0.isDir ? 0 : 1, $0.name.lowercased()) < ($1.isDir ? 0 : 1, $1.name.lowercased()) }
    }

    func open(_ entry: LocalEntry) {
        guard entry.isDir else { return }
        url = entry.url
        reload()
    }

    func goUp() {
        let parent = url.deletingLastPathComponent()
        if parent.path != url.path { url = parent; reload() }
    }

    func go(to newURL: URL) { url = newURL; reload() }

    var breadcrumbs: [(name: String, url: URL)] {
        var result: [(String, URL)] = []
        var comps = url.pathComponents
        var acc = URL(fileURLWithPath: "/")
        result.append(("/", acc))
        comps.removeFirst()   // drop leading "/"
        for c in comps {
            acc.appendPathComponent(c)
            result.append((c, acc))
        }
        return result
    }
}
