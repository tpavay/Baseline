import Foundation
import UserNotifications

/// Local-notification service for the morning-reading reminder. One repeating calendar
/// notification per selected weekday, all under a shared identifier prefix so rescheduling
/// replaces cleanly.
struct NotificationService {

    private static let reminderIDPrefix = "reminder.morningReading."

    /// Ask for permission (no-op if already determined). Returns whether notifications are allowed.
    static func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        case .authorized, .provisional, .ephemeral:
            return true
        default:
            return false
        }
    }

    /// Replace any existing morning reminders with one per selected weekday (1 = Sunday … 7 =
    /// Saturday), repeating weekly at hour:minute.
    static func scheduleMorningReminder(hour: Int, minute: Int, weekdays: Set<Int>) async {
        let center = UNUserNotificationCenter.current()
        await cancelMorningReminder()

        let content = UNMutableNotificationContent()
        content.title = "Morning reading"
        content.body = "Your body kept score overnight — take 2:30 to see it."
        content.sound = .default

        for weekday in weekdays.sorted() {
            var components = DateComponents()
            components.hour = hour
            components.minute = minute
            components.weekday = weekday
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
            let request = UNNotificationRequest(
                identifier: "\(reminderIDPrefix)\(weekday)",
                content: content,
                trigger: trigger
            )
            try? await center.add(request)
        }
    }

    static func cancelMorningReminder() async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let ids = pending.map(\.identifier).filter { $0.hasPrefix(reminderIDPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }
}
