import GuessrKit
import SwiftUI

@main
struct GuessrApp: App {
    @State private var account = Account()
    @State private var gameCenter = GameCenter()
    private let players = KeychainPlayerStore()
    private let client = GuessrClient()
    /// State rather than a constant because a link code swaps it for the player
    /// the code joined; every change goes back to the Keychain.
    @State private var player = KeychainPlayerStore().current()
    @State private var tab = GuessrApp.firstTab
    /// A tab something outside the view asked for, such as the Siri guess
    /// sending a signed-out player to Settings; taken once, then cleared.
    @AppStorage(GuessrApp.openTabKey) private var openTab = ""
    static let openTabKey = "open-tab"
    /// Settings' theme: "system" follows the device, else "light" or "dark".
    @AppStorage("appearance") private var appearance = "dark"
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Telemetry.start()
        UINavigationBar.useSerifTitles()
    }

    var body: some Scene {
        WindowGroup {
            TabView(selection: $tab) {
                Tab("Play", systemImage: "mappin.and.ellipse", value: "Play") {
                    NavigationStack { PlayView(player: $player).viewingAsBanner() }
                }
                if account.seesBoards {
                    Tab("Boards", systemImage: "list.number", value: "Boards") { NavigationStack { TodayView(alias: player.alias).viewingAsBanner() } }
                }
                Tab("Watch", systemImage: "play.rectangle", value: "Watch") { WatchTab() }
                // Chat hangs off the Twitch login, so the tab shows only while
                // a login is signed in; Settings is where a player signs in.
                // Settings always has the reminder, and hides only its Twitch
                // section in a build without a Twitch client id.
                if account.showsChat {
                    Tab("Chat", systemImage: "bubble.left.and.bubble.right", value: "Chat") { ChatTab() }
                }
                Tab("Settings", systemImage: "gear", value: "Settings") {
                    NavigationStack { SettingsView(player: $player).viewingAsBanner() }
                }
            }
            .foregroundStyle(Color.ink)
            .preferredColorScheme(appearance == "system" ? nil : appearance == "dark" ? .dark : .light)
            .modifier(AchievementToast())
            .environment(account)
            .environment(gameCenter)
            .task { gameCenter.start { await gameCenter.sync(player, with: client) } }
            // A sign-in opens Chat, the tab it brings, on every device: left to
            // itself, the iPad's tab bar keeps Settings selected as Chat
            // appears ahead of it.
            // A sign-out while on Chat, a "View as" that drops the boards, or a
            // `-tab` launch naming a hidden tab lands on Play rather than on a
            // tab that isn't there.
            .onChange(of: account.showsChat, initial: true) { showed, shows in
                if shows, !showed { tab = "Chat" }
                if !shows, tab == "Chat" { tab = "Play" }
            }
            .onChange(of: account.seesBoards, initial: true) { _, sees in
                if !sees, tab == "Boards" { tab = "Play" }
            }
            .onChange(of: openTab, initial: true) { _, named in
                guard !named.isEmpty else { return }
                tab = named
                openTab = ""
            }
            .onChange(of: player) { _, joined in players.save(joined) }
            .task(id: account.session?.userID) { await account.checkModerates() }
            .onChange(of: scenePhase, initial: true) { _, phase in
                if phase == .active { Task { await Reminder.refreshBadge() } }
            }
            // Midnight with the app open: the new day is unplayed.
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
                Task { await Reminder.refreshBadge() }
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
    /// The ids of the lines the chat opened with from last time, which the
    /// log draws dimmed under a rule.
    private(set) var earlierChat: Set<String> = []
    /// Whether Twitch says the signed-in login moderates the channel.
    private(set) var moderates = false
    /// The second login's code, while a mod is asked for the moderation scopes.
    private(set) var modCode: DeviceCode?
    private var modLogin: Task<Void, Never>?
    /// The token exchange in flight; see `refreshIfNeeded()`.
    private var refreshing: Task<Void, Never>?
    /// Chatters whose lines this device keeps off the Chat tab: Twitch user id
    /// to the display name Settings lists them by. The viewer's own
    /// moderation: it changes nothing on Twitch. A list from before names
    /// were kept shows each chatter by id.
    var hiddenChatters: [String: String] =
        UserDefaults.standard.dictionary(forKey: "hidden-chatter-names") as? [String: String]
        ?? Dictionary(uniqueKeysWithValues: (UserDefaults.standard.stringArray(forKey: "hidden-chatters") ?? []).map { ($0, $0) })
    {
        didSet { UserDefaults.standard.set(hiddenChatters, forKey: "hidden-chatter-names") }
    }

    init(bundle: Bundle = .main, store: any SessionStore = KeychainSessionStore()) {
        #if TWITCH
            auth = TwitchAuth(clientID: bundle.object(forInfoDictionaryKey: "GuessrTwitchClientID") as? String ?? "")
        #else
            // No client id is no Twitch login: Settings hides its Twitch
            // section and the Chat tab never appears.
            auth = TwitchAuth(clientID: "")
        #endif
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

    /// Whether the Chat tab is there: a Twitch build with a login signed in.
    var showsChat: Bool { auth.isConfigured && session != nil }

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
    ///
    /// One exchange at a time, shared by every caller: a launch onto the Chat
    /// tab asks twice at once (the root's mod check and the tab's chat), and
    /// Twitch's refresh tokens are single-use, so the second exchange of the
    /// same token is refused — which would sign out the login the first one
    /// just renewed. Unstructured, so a view's task ending doesn't cancel it.
    func refreshIfNeeded() async {
        if let refreshing { return await refreshing.value }
        guard let old = session, old.expiresSoon else { return }
        let exchange = Task {
            defer { refreshing = nil }
            do {
                let fresh = try await auth.refresh(old)
                // A sign-out, or another login, while the exchange ran wins.
                if session?.refreshToken == old.refreshToken { adopt(fresh) }
            } catch is TwitchAuthError {
                if session?.refreshToken == old.refreshToken { signOut() }
            } catch {}
        }
        refreshing = exchange
        await exchange.value
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
        guard auth.isConfigured, let session, !channel.isEmpty, !moderates else { return }
        let asker = chat?.helix ?? Helix(channel: channel, clientID: auth.clientID, session: session)
        let answer = await asker.moderates()
        // The login may have changed while Twitch answered.
        if self.session?.userID == session.userID { moderates = answer }
    }

    /// Connects the signed-in login to the channel's chat, or keeps the
    /// connection it already has, then asks whether it moderates there.
    /// The package never refreshes a token, so this is where it happens: on
    /// opening, and before each reconnect.
    func openChat() async {
        await refreshIfNeeded()
        guard let session, !channel.isEmpty else { return }
        if chat?.session.userID != session.userID {
            chat?.stop()
            let fresh = TwitchChat(channel: channel, clientID: auth.clientID, session: session)
            // EventSub replays nothing, so last time's tail is what the tab
            // opens on until live lines arrive.
            let earlier = Saved.chat
            fresh.seed(earlier)
            earlierChat = Set(earlier.map(\.id))
            fresh.beforeConnect = { [weak self] in await self?.refreshIfNeeded() }
            fresh.start()
            chat = fresh
        }
        // A failed lookup reads as no, so it is asked again on the next visit.
        if !moderates, let chat { moderates = await chat.helix.moderates() }
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
