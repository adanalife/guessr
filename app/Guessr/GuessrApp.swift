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

    init() { Telemetry.start() }

    var body: some Scene {
        WindowGroup {
            TabView(selection: $tab) {
                Tab("Play", systemImage: "mappin.and.ellipse", value: "Play") {
                    NavigationStack { PlayView(player: $player) }
                }
                if account.seesBoards {
                    Tab("Boards", systemImage: "list.number", value: "Boards") { NavigationStack { TodayView() } }
                }
                // Chat hangs off the Twitch login, so a build without a Twitch
                // client id has nothing to show there. Settings always has the
                // reminder, and hides only its Twitch section in such a build.
                if account.auth.isConfigured {
                    Tab("Chat", systemImage: "bubble.left.and.bubble.right", value: "Chat") { ChatTab() }
                }
                Tab("Settings", systemImage: "gear", value: "Settings") {
                    NavigationStack { SettingsView(player: $player) }
                }
            }
            // An inset rather than an overlay: viewing as someone else is easy to forget,
            // and a banner sitting on top of the screen would be easy to miss.
            .safeAreaInset(edge: .top) {
                if let tier = account.viewingAs {
                    Text("Viewing as \(tier)")
                        .font(.caption.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(.yellow.opacity(0.3))
                }
            }
            .foregroundStyle(Color.ink)
            .environment(account)
            .onChange(of: player) { _, joined in players.save(joined) }
            .task(id: account.session?.userID) { await account.checkModerates() }
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

    init(bundle: Bundle = .main, store: any SessionStore = KeychainSessionStore()) {
        auth = TwitchAuth(clientID: bundle.object(forInfoDictionaryKey: "GuessrTwitchClientID") as? String ?? "")
        ownerID = bundle.object(forInfoDictionaryKey: "GuessrOwnerTwitchID") as? String ?? ""
        channel = bundle.object(forInfoDictionaryKey: "GuessrTwitchChannel") as? String ?? ""
        self.store = store
        session = store.load()
    }

    /// Whether the signed-in login is the owner the build names, whatever
    /// the owner is viewing the app as. A Debug build takes `-owner 1` from the
    /// launch arguments, so the owner's screens can be screenshotted from the
    /// shell without a Twitch login.
    var isRealOwner: Bool {
        #if DEBUG
            if UserDefaults.standard.bool(forKey: "owner") { return true }
        #endif
        return session?.isOwner(ownerID) ?? false
    }

    /// The tier the owner is viewing the app as — `mod`, `viewer`, or nil for
    /// themselves. Saved, so it survives a relaunch mid-look. It only ever
    /// subtracts: the server and Twitch still hear the owner. Being a
    /// default, `-previewTier mod` on the launch arguments sets it too.
    var previewTier: String? = UserDefaults.standard.string(forKey: "previewTier") {
        didSet { UserDefaults.standard.set(previewTier, forKey: "previewTier") }
    }

    /// The tier being viewed as, for the owner only, so a login that isn't
    /// the owner never inherits one left on the device.
    var viewingAs: String? { isRealOwner ? previewTier : nil }

    /// What every screen asks before it offers the owner something.
    var isOwner: Bool { isRealOwner && viewingAs == nil }

    /// Whether we moderate the channel — really, or for the length of a look.
    var isMod: Bool { viewingAs.map { $0 == "mod" } ?? moderates }

    /// The boards are for the channel's staff; a player sees their own day.
    var seesBoards: Bool { isOwner || isMod }

    func signIn(_ code: DeviceCode, scopes: [String] = TwitchAuth.scopes) async throws {
        adopt(try await auth.poll(code, scopes: scopes))
    }

    /// Keeps a new token for the same login, or a different login altogether.
    /// The chat carries on under the new token; `openChat` replaces it when
    /// the login changes.
    private func adopt(_ fresh: TwitchSession) {
        store.save(fresh)
        if fresh.userID != session?.userID { moderates = false }
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
        (modLogin, modCode) = (nil, nil)
    }

    /// Asks Twitch whether the signed-in login moderates the channel, without
    /// joining its chat, so the gates that hang off it hold before Chat opens.
    func checkModerates() async {
        await refreshIfNeeded()
        guard let session, !channel.isEmpty, !moderates else { return }
        let asker = chat ?? TwitchChat(channel: channel, clientID: auth.clientID, session: session)
        let answer = await asker.moderates()
        // The login may have changed while Twitch answered.
        if self.session?.userID == session.userID { moderates = answer }
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
            chat = fresh
        }
        // A failed lookup reads as no, so it is asked again on the next visit.
        if !moderates, let chat { moderates = await chat.moderates() }
    }

    /// Whether the login moderates the channel without the scopes to act on
    /// it, so Settings offers the second login.
    var needsModLogin: Bool {
        auth.isConfigured && moderates && session.map { !$0.canModerate } ?? false
    }

    /// Asks Twitch again with the moderation scopes on top; the chat carries
    /// on under the current token meanwhile. A task of its own, so leaving
    /// Settings doesn't abandon the login.
    func startModLogin() {
        modLogin?.cancel()
        modLogin = Task {
            defer { modCode = nil }
            guard let code = try? await auth.start(scopes: TwitchAuth.modScopes) else { return }
            modCode = code
            try? await signIn(code, scopes: TwitchAuth.modScopes)
        }
    }
}
