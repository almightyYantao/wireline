import Foundation
import Observation
import Sparkle

/// Thin wrapper around Sparkle's standard updater. Reads its feed URL / public
/// key from Info.plist (set in bundle.sh), checks the GitHub-Pages appcast, and
/// drives Sparkle's built-in update UI. No custom server — just a signed
/// appcast.xml next to the site.
@Observable
@MainActor
final class Updater {
    static let shared = Updater()

    private let controller: SPUStandardUpdaterController
    /// Whether a manual "Check for Updates" can run right now (drives menu/button state).
    private(set) var canCheck = true

    private init() {
        // startingUpdater: true launches the background scheduler immediately;
        // Sparkle honors SUEnableAutomaticChecks / SUScheduledCheckInterval from
        // Info.plist. A nil feed URL (e.g. unsigned dev run) just no-ops safely.
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
        canCheck = controller.updater.canCheckForUpdates
    }

    /// User-initiated check (shows "you're up to date" if nothing's new).
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// Toggle Sparkle's automatic background checks at runtime.
    var automaticChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }
}
