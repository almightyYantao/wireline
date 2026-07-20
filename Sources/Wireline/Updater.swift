import Foundation
import Observation
import AppKit
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

    /// Last time a foreground-triggered silent check ran, to throttle them.
    private var lastForegroundCheck = Date.distantPast

    private init() {
        // startingUpdater: true launches the background scheduler immediately;
        // Sparkle honors SUEnableAutomaticChecks / SUScheduledCheckInterval from
        // Info.plist. A nil feed URL (e.g. unsigned dev run) just no-ops safely.
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
        canCheck = controller.updater.canCheckForUpdates
        // The scheduled check only fires while running and on its interval, so a
        // long-lived window can lag a release. Also check (silently) whenever the
        // app is brought to the foreground — throttled so it's not spammy — so an
        // update is offered promptly without needing to quit and relaunch.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkInBackgroundIfDue() }
        }
    }

    /// A silent check on foreground activation: prompts only if an update exists,
    /// and at most every 30 minutes.
    private func checkInBackgroundIfDue() {
        guard controller.updater.canCheckForUpdates,
              Date().timeIntervalSince(lastForegroundCheck) > 1800 else { return }
        lastForegroundCheck = Date()
        controller.updater.checkForUpdatesInBackground()
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
