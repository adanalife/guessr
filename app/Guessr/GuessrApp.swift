import GuessrKit
import SwiftUI

@main
struct GuessrApp: App {
    @State private var account = Account()
    private let players = KeychainPlayerStore()
    /// State rather than a constant because a link code swaps it for the player
    /// the code joined; every change goes back to the Keychain.
    @State private var player = KeychainPlayerStore().current()
    @State private var tab = GuessrApp.firstTab
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            TabView(selection: $tab) {
                Tab("Play", systemImage: "mappin.and.ellipse", value: "Play") {
                    NavigationStack { PlayView(player: $player) }
                }
                Tab("Boards", systemImage: "list.number", value: "Boards") { NavigationStack { TodayView() } }
                // Chat hangs off the Twitch login, so a build without a Twitch
                // client id has nothing to show there. Settings always has the
                // reminder, and hides only its Twitch section in such a build.
                if account.auth.isConfigured {
                    Tab("Chat", systemImage: "bubble.left.and.bubble.right", value: "Chat") { ChatTab() }
                }
                Tab("Settings", systemImage: "gear", value: "Settings") { NavigationStack { SettingsView() } }
            }
            .environment(account)
            .onChange(of: player) { _, joined in players.save(joined) }
            .onChange(of: scenePhase, initial: true) { _, phase in
                if phase == .active { Task { await Reminder.refreshBadge() } }
            }
        }
    }

    /// The tab a launch opens on. A Debug build takes `-tab <name>` from the
    /// launch arguments, so a screenshot of any tab can be taken from the shell.
    private static var firstTab: String {
        #if DEBUG
            if let named = UserDefaults.standard.string(forKey: "tab") { return named }
        #endif
        return "Play"
    }
}

/// The Twitch login, kept across launches, and what the build says about it.
@Observable
final class Account {
    private(set) var session: TwitchSession?
    let auth: TwitchAuth
    /// Supplied by the build; empty makes nobody the owner.
    let ownerID: String
    /// The Twitch channel the Chat tab talks in, supplied per configuration.
    let channel: String
    private let store: any SessionStore

    /// The channel's chat for the signed-in login, made the first time the
    /// Chat tab opens and kept until sign-out, so switching tabs keeps the log.
    private(set) var chat: TwitchChat?
    /// Whether Twitch says the signed-in login moderates the channel.
    private(set) var moderates = false
    /// The second login's code, while a mod is asked for the moderation scopes.
    private(set) var modCode: DeviceCode?
    private var modLogin: Task<Void, Never>?
    private var askedForModScopes = false

    init(bundle: Bundle = .main, store: any SessionStore = KeychainSessionStore()) {
        auth = TwitchAuth(clientID: bundle.object(forInfoDictionaryKey: "GuessrTwitchClientID") as? String ?? "")
        ownerID = bundle.object(forInfoDictionaryKey: "GuessrOwnerTwitchID") as? String ?? ""
        channel = bundle.object(forInfoDictionaryKey: "GuessrTwitchChannel") as? String ?? ""
        self.store = store
        session = store.load()
    }

    var isOwner: Bool { session?.isOwner(ownerID) ?? false }

    func signIn(_ code: DeviceCode, scopes: [String] = TwitchAuth.scopes) async throws {
        adopt(try await auth.poll(code, scopes: scopes))
    }

    /// Keeps a new token for the same login, or a different login altogether.
    /// The chat carries on under the new token; `openChat` replaces it when
    /// the login changes.
    private func adopt(_ fresh: TwitchSession) {
        store.save(fresh)
        session = fresh
        chat?.session = fresh
    }

    /// Refreshes a login close to expiry. A refused refresh means the login is
    /// gone, so it is dropped rather than retried.
    func refreshIfNeeded() async {
        guard let old = session, old.expiresSoon else { return }
        do {
            adopt(try await auth.refresh(old))
        } catch is TwitchAuthError {
            signOut()
        } catch {}
    }

    func signOut() {
        store.clear()
        session = nil
        chat?.stop()
        chat = nil
        moderates = false
        modLogin?.cancel()
        (modLogin, modCode, askedForModScopes) = (nil, nil, false)
    }

    /// Connects the signed-in login to the channel's chat, or keeps the
    /// connection it already has, then asks whether it moderates there.
    /// The package never refreshes a token, so this is where it happens.
    func openChat() async {
        await refreshIfNeeded()
        guard let session, !channel.isEmpty else { return }
        if chat?.session.userID != session.userID {
            chat?.stop()
            let fresh = TwitchChat(channel: channel, clientID: auth.clientID, session: session)
            fresh.start()
            (chat, moderates) = (fresh, false)
        }
        // A failed lookup reads as no, so it is asked again on the next visit.
        if !moderates, let chat { moderates = await chat.moderates() }
        if moderates { upgradeToModeratorIfNeeded() }
    }

    /// The first time a login turns out to moderate the channel without the
    /// scopes to act on it, asks Twitch again with them on top; the chat
    /// carries on under the current token meanwhile. Once per launch, so a code
    /// left to expire isn't pushed again on every visit. A task of its own, so
    /// leaving the tab doesn't abandon the login.
    // ponytail: once per launch; a "don't ask again" setting if a mod ever
    // declines on purpose. A failed second login leaves the mod verbs hidden
    // with no word why.
    private func upgradeToModeratorIfNeeded() {
        guard auth.isConfigured, !askedForModScopes, let session, !session.canModerate else { return }
        askedForModScopes = true
        modLogin = Task {
            defer { modCode = nil }
            guard let code = try? await auth.start(scopes: TwitchAuth.modScopes) else { return }
            modCode = code
            try? await signIn(code, scopes: TwitchAuth.modScopes)
        }
    }
}
