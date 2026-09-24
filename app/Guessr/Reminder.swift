import GuessrKit
import SwiftUI
import UserNotifications

/// The daily nudge to play, and the app-icon badge that says today's rounds
/// are still waiting. Both ride on the one notification permission, asked for
/// when the player turns the reminder on.
enum Reminder {
    static let id = "guessr-daily-reminder"

    /// Asks for permission, then schedules one notification repeating at
    /// `hour:minute` local time, replacing any earlier one. Returns whether the
    /// player allowed it, so a refusal can turn the toggle back off.
    static func schedule(hour: Int, minute: Int) async -> Bool {
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) == true else { return false }
        let content = UNMutableNotificationContent()
        content.title = "Guessr"
        content.body = "Five new rounds are up. Where in the US is this?"
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
    /// and clears it once something has. Without the permission there is no
    /// badge to set, so it does nothing.
    // ponytail: refreshed on foreground and after a guess only, so an app left
    // open across midnight shows no badge until it is next backgrounded.
    static func refreshBadge() async {
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().badgeSetting == .enabled else { return }
        let unplayed = DayProgress.resume(Saved.progress, on: GuessrClient.today()).played.isEmpty
        try? await center.setBadgeCount(unplayed ? 1 : 0)
    }
}

/// The Settings rows for the reminder: a toggle and, while it is on, the time.
struct ReminderSection: View {
    @AppStorage("reminder-on") private var on = false
    /// Minutes after local midnight; 9:00 by default.
    @AppStorage("reminder-minutes") private var minutes = 9 * 60

    var body: some View {
        Section("Reminder") {
            Toggle("Remind me to play", isOn: $on)
            if on {
                DatePicker("At", selection: time, displayedComponents: .hourAndMinute)
            }
        }
        .task(id: on ? minutes : -1) { await apply() }
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
        if await Reminder.schedule(hour: minutes / 60, minute: minutes % 60) {
            await Reminder.refreshBadge()
        } else {
            on = false
        }
    }
}
