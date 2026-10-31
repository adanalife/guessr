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
    @State private var player = KeychainPlayerStore().current(orAdopt: GroupPlayerStore().load())
    @State private var tab = GuessrApp.firstTab
    /// Bumped when the App Clip's plays land on this player, so Play loads
    /// the day again with any rounds the clip played today.
    @State private var clipFolds = 0
    /// A link-a-device QR code scanned into the app that the server couldn't
    /// look up, held while the plain question asks.
    @State private var link: DeviceLink?
    /// A scanned code the server could look up, held while the comparison
    /// sheet asks; `link` is then the plain question for one it couldn't.
    @State private var comparing: (link: DeviceLink, preview: LinkPreview)?
    /// Set by a join from the sheet that failed, and shown once the sheet has
    /// gone, since an alert can't present over it from here.
    @State private var sheetJoinFailed = false
    /// The name a scanned code goes by when it is this device's own player.
    @State private var alreadyAs: String?
    @State private var linkFailed = false
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
                    NavigationStack {
                        PlayView(player: $player) { score, progress in
                            if progress.played.count == 1 { Task { await Reminder.refreshBadge() } }
                            // Off the reveal's path: the server reads the standing
                            // off its own table, so this carries nothing the reveal
                            // waits on.
                            if score.recorded { Task { await gameCenter.sync(player, with: client) } }
                        }
                        .id(clipFolds)
                        .viewingAsBanner()
                    }
                }
                if account.seesBoards {
                    Tab("Boards", systemImage: "list.number", value: "Boards") { NavigationStack { TodayView(alias: player.alias).viewingAsBanner() } }
                }
                // Settings is where a player signs in. It always has the
                // reminder, and hides only its Twitch section in a build
                // without a Twitch client id.
                #if WATCH
                    Tab("Watch", systemImage: "play.rectangle", value: "Watch") { WatchTab() }
                #endif
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
            .task { await foldInClip() }
            #if DEBUG
                // `-linkPreview 1` opens the comparison sheet on sample players,
                // for a screenshot without scanning a code.
                .task {
                    if UserDefaults.standard.bool(forKey: "linkPreview") {
                        comparing = (DeviceLink(id: "sample", name: "Patient Delta"), .sample)
                    }
                }
            #endif
            // A "View as" that drops the boards, or a `-tab` launch naming a
            // hidden tab, lands on Play rather than on a tab that isn't there.
            .onChange(of: account.seesBoards, initial: true) { _, sees in
                if !sees, tab == "Boards" { tab = "Play" }
            }
            .onChange(of: openTab, initial: true) { _, named in
                guard !named.isEmpty else { return }
                tab = named
                openTab = ""
            }
            .onChange(of: player) { _, joined in players.save(joined) }
            // The website's QR code, which iOS hands here instead of Safari when
            // the app is installed. Behind a question, never on arrival alone:
            // a URL that silently rewrites who you are is a URL anyone can send.
            // Linking keeps each device's own alias, so this device's player
            // can go by another name on the web; that code still says so
            // rather than nothing.
            .onOpenURL { opened($0, via: "url") }
            // A camera scan of a guessr.dana.lol code can arrive as an App Clip
            // invocation, which reaches an installed full app as a web
            // browsing activity rather than an opened URL.
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                if let url = activity.webpageURL { opened(url, via: "activity") }
            }
            .sheet(
                isPresented: Binding(get: { comparing != nil }, set: { if !$0 { comparing = nil } }),
                onDismiss: {
                    if sheetJoinFailed { (sheetJoinFailed, linkFailed) = (false, true) }
                }
            ) {
                if let comparing {
                    LinkCompareView(
                        preview: comparing.preview, alias: player.alias, codeHeading: String(localized: "Scanned code")
                    ) {
                        let joined = await join(comparing.link)
                        sheetJoinFailed = !joined
                        return joined
                    }
                }
            }
            .alert(
                link.map { Text("Play as \($0.name ?? String(localized: "your other device"))?") } ?? Text(verbatim: ""),
                isPresented: Binding(get: { link != nil }, set: { if !$0 { link = nil } }), presenting: link
            ) { opened in
                Button("Join") { Task { linkFailed = !(await join(opened)) } }
                Button("Cancel", role: .cancel) {}
            } message: { opened in
                Text("This device's plays will be merged with \(opened.name ?? String(localized: "your other device")).")
            }
            .alert(
                alreadyAs.map { Text("Already playing as \($0)") } ?? Text(verbatim: ""),
                isPresented: Binding(get: { alreadyAs != nil }, set: { if !$0 { alreadyAs = nil } }), presenting: alreadyAs
            ) { _ in
                Button("OK", role: .cancel) {}
            }
            .alert("Could not link the devices just now.", isPresented: $linkFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Scan the code again to retry.")
            }
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

    /// A guessr.dana.lol URL handed to the app, by either route iOS uses.
    private func opened(_ url: URL, via route: String) {
        let link = DeviceLink(url)
        Telemetry.linkOpened(url, via: route, read: link != nil)
        guard let link else { return }
        guard link.id != player.id else {
            alreadyAs = link.name ?? player.alias
            return
        }
        Task { await ask(link) }
    }

    /// Looks the scanned player up before asking, so the sheet can set both
    /// players side by side. A failed look still asks, with only the name the
    /// code carries.
    private func ask(_ opened: DeviceLink) async {
        do {
            comparing = (opened, try await client.previewLink(opened, from: player))
        } catch {
            Telemetry.requestFailed("link-preview", error: error)
            link = opened
        }
    }

    /// Joins the website's player: the merge runs first, and the id is adopted
    /// only once it has, so a failure leaves this device's plays where they are.
    /// Answers whether it joined.
    private func join(_ link: DeviceLink) async -> Bool {
        do {
            _ = try await client.link(link, from: player)
            // Today's rounds are the joined player's now, as the server holds them.
            Saved.progress = nil
            player = Player(id: link.id, alias: player.alias)
            tab = "Play"
            return true
        } catch {
            Telemetry.requestFailed("link", error: error)
            return false
        }
    }

    /// Moves the App Clip's plays onto this device's player when the Keychain
    /// already held one, the merge a link runs, keeping this player's id and
    /// alias. The clip's player leaves the app group only once the merge has
    /// run, so a failure is retried on the next launch.
    private func foldInClip() async {
        let group = GroupPlayerStore()
        guard let clip = group.handedOver(besides: player) else { return }
        do {
            let moved = try await client.link(DeviceLink(id: player.id), from: clip)
            group.clear()
            if moved > 0 { clipFolds += 1 }
        } catch {
            Telemetry.requestFailed("clip-link", error: error)
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
    /// The Twitch channel the chat talks in, supplied per configuration.
    let channel: String
    private let store: any SessionStore

    /// The channel's chat for the signed-in login, made the first time the
    /// chat opens and kept until sign-out, so switching tabs keeps the log.
    private(set) var chat: TwitchChat?
    /// The channel's chat read with no login, for a viewer who hasn't signed
    /// in; dropped once they do.
    private(set) var lurk: TwitchLurk?
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
    /// Chatters whose lines this device keeps out of the chat: Twitch user id
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
            // section, and the Watch tab has no chat.
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

    /// Whether the Watch tab carries chat: a Twitch build, signed in or not —
    /// signed out reads it anonymously.
    var showsChat: Bool {
        #if TWITCH
            !channel.isEmpty
        #else
            false
        #endif
    }

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

    /// Refreshes a login close to expiry, or takes up the one the Siri guess
    /// already refreshed. A refused refresh means the login is gone, so it is
    /// dropped rather than retried.
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
            let renewed: TwitchSession?
            do { renewed = try await auth.renew(old, keptIn: store) } catch { return }  // a transport failure retries next time
            // A sign-out, or another login, while the exchange ran wins.
            guard session?.refreshToken == old.refreshToken else { return }
            if let renewed { adopt(renewed) } else { signOut() }
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

    /// Reads the channel's chat anonymously, or keeps the reading it has.
    func openLurk() {
        guard lurk == nil, session == nil, !channel.isEmpty else { return }
        let fresh = TwitchLurk(channel: channel)
        fresh.start()
        lurk = fresh
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
            lurk?.stop()
            lurk = nil
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
