import AppKit
import CinmuxCore
import UserNotifications

/// Posts macOS notifications for new session notices and for agents that start
/// waiting for input, unless that session is already on screen.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    var onOpen: ((String) -> Void)?
    private var noticeSequences: [String: Int64] = [:]
    private var waiting: Set<String> = []
    private var primed = false
    private var authorized = false

    /// Notification Center only serves real app bundles; a bare `swift run` binary would crash.
    private var available: Bool { Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil }

    /// Records the current state without notifying about it.
    func prime(_ sessions: [SessionRow]) {
        remember(sessions)
        primed = true
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            onMain { [weak self] in self?.authorized = granted }
        }
    }

    func observe(_ sessions: [SessionRow], selectedId: String) {
        guard primed else { return }
        let onScreen = NSApp.isActive && NSApp.keyWindow != nil
        for row in sessions {
            let visible = onScreen && row.id == selectedId
            if let previous = noticeSequences[row.id], row.noticeSequence > previous, row.unreadCount > 0, !visible {
                post(row, subtitle: row.noticeTitle, body: row.noticeBody)
            }
            if row.activity == .waiting && !waiting.contains(row.id) && !visible {
                post(row, subtitle: "Needs input", body: row.activityDetail)
            }
        }
        remember(sessions)
    }

    private func remember(_ sessions: [SessionRow]) {
        noticeSequences = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.noticeSequence) })
        waiting = Set(sessions.filter { $0.activity == .waiting }.map(\.id))
    }

    private func post(_ row: SessionRow, subtitle: String, body: String) {
        // Needs no permission, so it still works when notifications are turned off.
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        guard available, authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = row.title
        content.subtitle = subtitle
        content.body = body
        content.sound = .default
        content.threadIdentifier = row.id
        content.userInfo = ["sessionId": row.id]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["sessionId"] as? String
        onMain { [weak self] in
            if let id { self?.onOpen?(id) }
            completionHandler()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Posted only for sessions that are not on screen, so show it even while active.
        completionHandler([.banner, .sound])
    }
}
