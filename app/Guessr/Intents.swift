#if TWITCH
import AppIntents
import GuessrKit

/// A failure worth hearing: why the guess never reached chat.
struct GuessError: Error, CustomLocalizedStringResourceConvertible {
    var text: String
    var localizedStringResource: LocalizedStringResource { "\(text)" }
}

/// `!guess <state>` in the channel's Twitch chat, as the signed-in viewer —
/// the same line they could type in the Chat tab. Runs with the app closed: it
/// reads the login the app keeps and posts once, with no chat connection.
struct GuessStateIntent: AppIntent {
    static let title: LocalizedStringResource = "Guess the State"
    static let description = IntentDescription("Guess which state the van is in, as !guess in Twitch chat.")
    /// In the background unless nobody is signed in, when Siri offers to open
    /// the app on Settings, where the sign-in is.
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @Parameter(title: "State")
    var state: USState

    static var parameterSummary: some ParameterSummary {
        Summary("Guess \(\.$state)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let account = Account()
        await account.refreshIfNeeded()
        guard account.auth.isConfigured, !account.channel.isEmpty else {
            return .result(dialog: "This build of Guessr can't guess in Twitch chat.")
        }
        guard let session = account.session else {
            try await continueInForeground("Sign in to Twitch in Guessr's Settings to guess in the stream's chat.")
            UserDefaults.standard.set("Settings", forKey: GuessrApp.openTabKey)
            return .result(dialog: "Sign in under Twitch, then guess again.")
        }
        let helix = Helix(channel: account.channel, clientID: account.auth.clientID, session: session)
        do {
            try await helix.send("!guess \(state.rawValue)")
        } catch {
            throw GuessError(text: String(localized: "Twitch didn't take the guess: \(error.localizedDescription)"))
        }
        return .result(dialog: "Guessed \(state.localizedName).")
    }
}

/// The phrases that reach the guess from Siri with nothing to set up first.
struct GuessrShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GuessStateIntent(),
            phrases: [
                "Guess \(\.$state) in \(.applicationName)",
                "Guess that this is \(\.$state) in \(.applicationName)",
                "Guess we're in \(\.$state) in \(.applicationName)",
            ],
            shortTitle: "Guess the State",
            systemImageName: "map"
        )
    }
}
#endif
