import GuessrKit
import SwiftUI
import UserNotifications

/// The daily nudge to play, and the app-icon badge that says today's rounds
/// are still waiting. Each has its own switch; both ride on the one
/// notification permission, asked for when the player turns either on.
enum Reminder {
    static let id = "guessr-daily-reminder"
    /// The badge switch's defaults key, read here as well as by the switch.
    static let badgeKey = "reminder-badge"

    /// Asks for the permission a switch needs. Returns whether the player
    /// allowed it, so a refusal can turn the switch back off.
    static func authorize(_ options: UNAuthorizationOptions) async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: options)) == true
    }

    /// Asks for permission, then schedules one notification repeating at
    /// `hour:minute` local time, replacing any earlier one. Returns whether the
    /// player allowed it, so a refusal can turn the toggle back off.
    static func schedule(hour: Int, minute: Int) async -> Bool {
        let center = UNUserNotificationCenter.current()
        guard await authorize([.alert, .sound]) else { return false }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Guessr")
        content.body = String(localized: "Today's five rounds are ready to play!")
        content.sound = .default
        let trigger = UNCalendarNotificationTrigger(
            dateMatching: DateComponents(hour: hour, minute: minute), repeats: true)
        try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        return true
    }

    static func cancel() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
    }

    /// Badges the icon while nothing has been guessed today on this device,
    /// and clears it once something has or the badge switch is off. Without
    /// the permission there is no badge to set, so it does nothing.
    static func refreshBadge() async {
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().badgeSetting == .enabled else { return }
        let unplayed = DayProgress.resume(Saved.progress, on: GuessrClient.today()).played.isEmpty
        let shown = UserDefaults.standard.bool(forKey: badgeKey) && unplayed
        try? await center.setBadgeCount(shown ? 1 : 0)
    }
}

/// The Settings rows for the reminders: the badge, the notification and,
/// while the notification is on, its time.
struct ReminderSection: View {
    @AppStorage(Reminder.badgeKey) private var badge = false
    @AppStorage("reminder-on") private var on = false
    /// Minutes after local midnight; 9:00 by default.
    @AppStorage("reminder-minutes") private var minutes = 9 * 60

    var body: some View {
        Section("Daily reminders") {
            Toggle("Show badge", isOn: $badge)
            Toggle("Send notification", isOn: $on)
            if on {
                DatePicker("At", selection: time, displayedComponents: .hourAndMinute)
            }
        }
        .task(id: on ? minutes : -1) { await apply() }
        .task(id: badge) { await applyBadge() }
    }

    /// The stored minutes as a `Date` today, which is what a picker binds to.
    private var time: Binding<Date> {
        Binding {
            Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: .now) ?? .now
        } set: { picked in
            let c = Calendar.current.dateComponents([.hour, .minute], from: picked)
            minutes = (c.hour ?? 9) * 60 + (c.minute ?? 0)
        }
    }

    private func apply() async {
        guard on else { return Reminder.cancel() }
        if !(await Reminder.schedule(hour: minutes / 60, minute: minutes % 60)) { on = false }
    }

    private func applyBadge() async {
        if badge, !(await Reminder.authorize(.badge)) { badge = false }
        await Reminder.refreshBadge()
    }
}
