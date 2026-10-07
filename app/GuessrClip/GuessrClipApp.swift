import GuessrKit
import SwiftUI

/// The App Clip: today's rounds and nothing else, launched from a share link
/// or the site's QR code with no install. Chat, Settings, Game Center and
/// Siri stay in the full app. The player it mints lives in the app group,
/// which iOS hands to the full app on install, so the clip's plays follow.
///
/// The invocation URL is ignored: every link into the clip plays the day.
@main
struct GuessrClipApp: App {
    private let players = GroupPlayerStore()
    @State private var player = GroupPlayerStore().current()

    init() {
        Telemetry.start()
        UINavigationBar.useSerifTitles()
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack { PlayView(player: $player) }
                .foregroundStyle(Color.ink)
                .preferredColorScheme(.dark)
                .onChange(of: player) { _, changed in players.save(changed) }
        }
    }
}
