import Foundation
import UserNotifications
import SwitchboardCore

/// macOS notifications for sessions that newly turn red. Requires running from the .app bundle.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    var onClick: ((String) -> Void)?
    private let center: UNUserNotificationCenter?

    override init() {
        // UNUserNotificationCenter crashes outside an app bundle (e.g. plain `swift run`).
        center = Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")
            ? UNUserNotificationCenter.current() : nil
        super.init()
        center?.delegate = self
        center?.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error { NSLog("Switchboard: notification auth error: %@", error.localizedDescription) }
            if !granted { NSLog("Switchboard: notifications not allowed") }
        }
    }

    func notifyBlocked(_ session: Session) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(session.displayName) needs you"
        content.body = session.need
        content.sound = .default
        content.userInfo = ["session_id": session.id]
        let request = UNNotificationRequest(identifier: "blocked-\(session.id)", content: content, trigger: nil)
        center.add(request)
    }

    /// Opt-in banner for a finished turn (the pill's own "done" flash is the default).
    func notifyDone(_ session: Session) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(session.displayName) is done"
        content.body = Summarizer.oneLine(session.detail.isEmpty ? "Ready for review" : session.detail, max: 140)
        content.userInfo = ["session_id": session.id]
        // Same id per session, so a chatty session replaces its banner instead of stacking them.
        center.add(UNNotificationRequest(identifier: "done-\(session.id)", content: content, trigger: nil))
    }

    func notify(title: String, body: String) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let id = response.notification.request.content.userInfo["session_id"] as? String {
            DispatchQueue.main.async { self.onClick?(id) }
        }
        completionHandler()
    }
}
