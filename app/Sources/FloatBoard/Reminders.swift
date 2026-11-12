import AppKit
import FloatBoardCore
import UserNotifications

/// Due reminders as macOS notifications (UserNotifications). Needs the app bundle (a bundle id); `swift run` builds
/// have none, so they get no reminders. The app asks for permission once, the first time reminders are on.
@MainActor final class SystemReminders: NSObject, ReminderScheduler, UNUserNotificationCenterDelegate {
    /// Reminders need a real app bundle: UNUserNotificationCenter refuses a bare executable.
    static var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }
    static let askedKey = "dueRemindersAskedPermission"

    private let center = UNUserNotificationCenter.current()
    private let log: (ActivityLevel, String, String?) -> Void
    /// Clicking a reminder opens the board.
    var onOpen: () -> Void = {}

    init(log: @escaping (ActivityLevel, String, String?) -> Void) {
        self.log = log
        super.init()
        center.delegate = self
    }

    /// Asks once (on the first launch with reminders on); later launches never ask again.
    func askOnce(_ defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: Self.askedKey) else { return }
        defaults.set(true, forKey: Self.askedKey)
        center.requestAuthorization(options: [.alert, .sound]) { [log] granted, error in
            Task { @MainActor in
                if let error { log(.warning, "Could not ask to show due reminders", "\(error)") }
                else if !granted { log(.info, "Due reminders are off in System Settings, Notifications", nil) }
            }
        }
    }

    func schedule(_ r: DueReminder) {
        let content = UNMutableNotificationContent()
        content.title = r.title
        content.body = r.body
        content.sound = .default
        content.userInfo = ["card": r.cardID]
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: r.fireAt)
        let request = UNNotificationRequest(identifier: r.id, content: content,
                                            trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
        center.add(request) { [log] error in
            guard let error else { return }
            Task { @MainActor in log(.warning, "Could not schedule a due reminder", "\(error)") }
        }
    }

    func cancel(_ ids: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)   // a done task's reminder leaves Notification Centre too
    }

    // Shown even while FloatBoard is in front (it usually is: the bar is always there).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler done: @escaping () -> Void) {
        Task { @MainActor in self.onOpen(); done() }
    }
}
