import AppKit
import UserNotifications

/// Posts local notifications. One about a pane carries its session id, so
/// clicking it brings that pane forward.
enum Notifier {
    static let sessionKey = "sessionID"

    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Wireline in front: its own card. In the background: a system notification
    /// (plus a card if the user asked for that).
    static func post(title: String, body: String, session: UUID? = nil) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { CardCenter.shared.route(title: title, body: body, session: session) }
        }
    }

    static func postSystem(title: String, body: String, session: UUID?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let session { content.userInfo = [sessionKey: session.uuidString] }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Schedule a one-shot notification for `date` under a stable `id`, so it can
    /// be replaced or cancelled later (e.g. when a to-do's due date changes).
    /// A date already in the past is ignored.
    static func schedule(id: String, title: String, body: String, at date: Date) {
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        guard date > Date() else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.add(request)
    }

    static func cancel(id: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
    }
}

/// Clicks on Wireline's notifications: jump to the pane that sent one (if
/// it's still open), else just bring the main window forward.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = NotificationRouter()

    func install() { UNUserNotificationCenter.current().delegate = self }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Our own posts only reach here when sent in the background; scheduled
        // ones (to-dos) can fire in front, so they get a card instead of a banner.
        let c = notification.request.content
        let id = (c.userInfo[Notifier.sessionKey] as? String).flatMap(UUID.init(uuidString:))
        let (title, body) = (c.title, c.body)
        DispatchQueue.main.async {
            MainActor.assumeIsolated { CardCenter.shared.show(title: title, body: body, session: id) }
        }
        completionHandler([.list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = (response.notification.request.content.userInfo[Notifier.sessionKey] as? String)
            .flatMap(UUID.init(uuidString:))
        completionHandler()
        DispatchQueue.main.async { MainActor.assumeIsolated { Self.open(id) } }
    }

    @MainActor
    static func open(_ id: UUID?) {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.canBecomeMain && $0.level == .normal && $0.title == "Wireline" }?
            .makeKeyAndOrderFront(nil)
        guard let id, let sessions = IslandCenter.shared.sessions, sessions.session(id) != nil else { return }
        sessions.focusSession(id)
        DispatchQueue.main.async { sessions.focusActiveTerminal() }
    }
}
