import Foundation
import UserNotifications

/// Local-notification scheduling. Requests authorization lazily — only the
/// first time the user actually triggers a backup or enables a notification
/// toggle, never on cold launch.
///
/// The auth result is cached per-process so repeated calls don't re-query
/// `notificationSettings` on every scheduling attempt.
enum NotificationManager {

    static let onThisDayIdentifier = "com.sarpedon.phosphor.onthisday"

    /// Process-local cache of the auth decision. Reset on cold launch (which
    /// is fine — iOS itself caches the system-level answer for the user).
    private actor AuthCache {
        var value: Bool?
        func set(_ v: Bool) { value = v }
    }
    private static let authCache = AuthCache()

    @discardableResult
    static func requestAuthorizationIfNeeded() async -> Bool {
        if let cached = await authCache.value { return cached }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        let result: Bool
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            result = true
        case .denied:
            result = false
        case .notDetermined:
            result = (try? await center.requestAuthorization(
                options: [.alert, .sound, .badge]
            )) ?? false
        @unknown default:
            result = false
        }
        await authCache.set(result)
        return result
    }

    /// Schedule the daily "On this day" reminder at 09:00 local time. The
    /// notification's body is generic; the app figures out the actual asset
    /// count when the user taps in.
    static func scheduleOnThisDay(enabled: Bool) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [onThisDayIdentifier])
        guard enabled else { return }
        guard await requestAuthorizationIfNeeded() else { return }

        let content = UNMutableNotificationContent()
        content.title = "On This Day"
        content.body = "Revisit photos from this day in past years."
        content.sound = .default
        content.userInfo = ["route": "memories"]

        var components = DateComponents()
        components.hour = 9
        components.minute = 0
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)

        let request = UNNotificationRequest(
            identifier: onThisDayIdentifier, content: content, trigger: trigger
        )
        try? await center.add(request)
    }

    /// Fired after a BGProcessingTask backup run completes.
    static func sendBackupComplete(uploaded: Int, failed: Int) async {
        guard AppSettings.bool(AppSettings.Keys.backupNotificationsEnabled, default: true)
        else { return }
        guard await requestAuthorizationIfNeeded() else { return }

        let content = UNMutableNotificationContent()
        if failed == 0 {
            content.title = "Backup Complete"
            content.body = "\(uploaded) \(uploaded == 1 ? "photo" : "photos") uploaded."
        } else {
            content.title = "Backup Finished With Issues"
            content.body = "\(uploaded) uploaded, \(failed) failed."
        }
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }
}
