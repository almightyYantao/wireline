import Foundation
import Observation
import WirelineCore

// The model (`Snippet`) and its pure logic — placeholders, danger detection,
// platform scope, categories, ranking, migration — live in WirelineCore.

/// Stores command snippets, persisted to Application Support as JSON, and
/// knows which platform each pane is on.
@Observable
@MainActor
final class SnippetStore {
    private(set) var snippets: [Snippet] = []
    private let fileURL: URL

    /// `uname -s` per SSH alias, cached across launches.
    private(set) var hostPlatforms: [String: PanePlatform] = [:]
    private var probing: Set<String> = []
    private static let platformsKey = "snippetHostPlatforms"

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wireline", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.fileURL = base.appendingPathComponent("snippets.json")
        if let raw = UserDefaults.standard.dictionary(forKey: Self.platformsKey) as? [String: String] {
            hostPlatforms = raw.compactMapValues(PanePlatform.init(rawValue:))
        }
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            snippets = Snippet.defaults
            save()
            return
        }
        do {
            let (loaded, migrated) = try SnippetMigration.load(data)
            snippets = loaded
            if migrated {
                // Keep the pre-redesign file next to the new one, just in case.
                let backup = fileURL.deletingPathExtension().appendingPathExtension("v1.json")
                if !FileManager.default.fileExists(atPath: backup.path) { try? data.write(to: backup) }
                save()
            }
        } catch {
            // Unreadable: show the defaults, but never overwrite the user's file
            // with them — `canSave` stays false until they change something.
            snippets = Snippet.defaults
            canSave = false
        }
    }

    /// False while the file on disk couldn't be read (so we don't clobber it
    /// just by opening the list); any edit by the user turns it back on.
    private var canSave = true

    private func save() {
        guard canSave else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(snippets) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func add(_ snippet: Snippet) { canSave = true; snippets.append(snippet); save() }

    func update(_ snippet: Snippet) {
        canSave = true
        if let i = snippets.firstIndex(where: { $0.id == snippet.id }) { snippets[i] = snippet; save() }
    }

    func remove(_ snippet: Snippet) { canSave = true; snippets.removeAll { $0.id == snippet.id }; save() }

    /// Count a use (for the recent / frequent ordering) and remember the values
    /// typed into its parameters.
    func recordUse(_ id: UUID, values: [String: String] = [:]) {
        guard let i = snippets.firstIndex(where: { $0.id == id }) else { return }
        snippets[i].useCount += 1
        snippets[i].lastUsed = Date()
        if !values.isEmpty { snippets[i].lastValues = values.filter { !$0.value.isEmpty } }
        save()
    }

    /// Find a snippet by either title (the AI's `run_snippet` action).
    func find(named name: String) -> Snippet? {
        snippets.first { $0.titleZh == name || $0.titleEn == name || $0.allTitles == name }
            ?? snippets.first { $0.allTitles.localizedCaseInsensitiveContains(name) }
    }

    // MARK: - Pane scope

    /// The platform a session's pane is on: a local shell is this Mac; an SSH
    /// host is whatever `uname -s` said last time, else unknown (= Linux).
    func platform(for session: TerminalSession) -> PanePlatform {
        switch session.kind {
        case .localShell: return .macos
        case .ssh, .sftp: return hostPlatforms[session.alias] ?? .unknown
        }
    }

    /// Ask an SSH host what it is, once, over the session's ControlMaster
    /// socket (no new login, nothing typed into the terminal).
    func probePlatform(of session: TerminalSession) {
        guard case .ssh = session.kind, session.connectionState == .connected else { return }
        let alias = session.alias
        guard hostPlatforms[alias] == nil, !probing.contains(alias) else { return }
        probing.insert(alias)
        Task {
            let out = await session.runCapturing("uname -s")
            probing.remove(alias)
            let p = PanePlatform.fromUname(out)
            guard p != .unknown else { return }
            hostPlatforms[alias] = p
            UserDefaults.standard.set(hostPlatforms.mapValues(\.rawValue), forKey: Self.platformsKey)
        }
    }
}
