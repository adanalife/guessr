#if canImport(TempomatConsole)
    import TempomatConsole
#endif
import GuessrKit
import SwiftUI

extension Color {
    /// The web game's page and text colors, light and dark, from the asset catalog.
    static let paper = Color("Paper")
    static let ink = Color("Ink")
}

extension View {
    /// The web game's page color behind a screen, lists and forms included.
    func paper() -> some View {
        scrollContentBackground(.hidden).background(Color.paper)
    }

    /// A list or form at a readable width, centred on the page, on regular width
    /// only: an iPad row the full width of the screen strands a toggle far from
    /// its label. The large title moves over the column with it, so it doesn't
    /// float at the screen's edge. Goes inside `paper()`, so the page color still
    /// fills the screen.
    func readableWidth(title: LocalizedStringKey) -> some View { modifier(ReadableWidth(title: title)) }

    /// The web game's play button: an ink fill under a paper label, the
    /// highest-contrast thing on screen in either theme. The accent is a text
    /// color, too light in dark mode to carry a white label.
    func inkButton() -> some View { buttonStyle(InkButtonStyle()) }
}

/// An ink capsule under a paper label. Disabled, it is the same capsule at
/// half strength rather than the system's grey, which vanishes on paper in
/// light mode and on footage in either.
private struct InkButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(Color.paper)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color.ink.opacity(isEnabled ? 1 : 0.45), in: Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

extension View {
    /// The owner's "Viewing as" band, on each tab's root inside its navigation stack.
    /// Inside the stack it sits below the navigation bar and clear of the tab bar on
    /// both devices: iPadOS floats the tab bar over the top of the window and iOS
    /// floats it over the bottom, so an inset on the tab view collides with one or
    /// the other. Solid yellow with black text reads in light and dark; the fill stays
    /// out of the safe area, where it would flood the transparent navigation bar.
    func viewingAsBanner() -> some View { modifier(ViewingAsBanner()) }
}

private struct ReadableWidth: ViewModifier {
    let title: LocalizedStringKey
    @Environment(\.horizontalSizeClass) private var sizeClass

    func body(content: Content) -> some View {
        if sizeClass == .regular {
            content.frame(maxWidth: 640).frame(maxWidth: .infinity)
                .navigationTitle(title)
                .toolbar {
                    // The bar's own large title, drawn over the column and
                    // lined up with its cards' edge, where a full-width list
                    // puts it. The serif matches the appearance proxy's.
                    ToolbarItem(placement: .largeTitle) {
                        Text(title)
                            .font(.system(.largeTitle, design: .serif, weight: .bold))
                            // ponytail: 20 is the inset-grouped list's regular-width
                            // margin, measured, not read; a system margin change
                            // drifts it, a readable-content guide fixes that.
                            .padding(.leading, 20)
                            .frame(maxWidth: 640, alignment: .leading)
                            .frame(maxWidth: .infinity)
                    }
                }
        } else {
            content.navigationTitle(title)
        }
    }
}

private struct ViewingAsBanner: ViewModifier {
    @Environment(Account.self) private var account

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .top) {
            if let tier = account.viewingAs {
                Text("Viewing as \(tier)")
                    .font(.caption.bold())
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(.yellow, ignoresSafeAreaEdges: [])
            }
        }
    }
}

/// The boards, read from the public API, the running month first.
struct TodayView: View {
    /// The player's own name, whose row is picked out when it makes the board.
    var alias: String?
    @State private var board: GuessrLeaderboard?
    @State private var boardName = "monthly"
    @State private var error: String?

    private let client = GuessrClient()

    var body: some View {
        List {
            Section {
                Picker("Board", selection: $boardName) {
                    Text("This month").tag("monthly")
                    Text("Daily").tag("daily")
                }
                .pickerStyle(.segmented)
                ForEach(Array((board?.rows ?? []).enumerated()), id: \.offset) { rank, row in
                    let mine = isMine(row)
                    LabeledContent(mine ? "\(rank + 1). \(row.name) (you)" : "\(rank + 1). \(row.name)", value: "\(row.points)")
                        .fontWeight(mine ? .bold : nil)
                        .listRowBackground(mine ? Color.accentColor.opacity(0.15) : nil)
                }
            } header: {
                if let board { Text("Leaderboard · \(board.period)") } else { Text("Leaderboard") }
            }
            if let error {
                Text(error).foregroundStyle(.secondary)
            }
        }
        .readableWidth(title: "Guessr")
        .paper()
        .task(id: boardName) { await load() }
        .refreshable { await load() }
    }

    // ponytail: matched by name, since no public response may carry a player
    // id. Another player drawing the same two words lights up too (the board
    // numbers them "(2)"), and an operator-set alias does not; a board that
    // marks the caller's row server-side is the upgrade.
    private func isMine(_ row: GuessrLeaderboard.Row) -> Bool {
        guard let alias else { return false }
        return row.name == alias || row.name.hasPrefix("\(alias) (")
    }

    private func load() async {
        do {
            (board, error) = (try await client.leaderboard(board: boardName), nil)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct SettingsView: View {
    @Environment(Account.self) private var account
    @Binding var player: Player
    @State private var playedToday = false
    @AppStorage("kilometers") private var kilometers = false
    @AppStorage("appearance") private var appearance = "dark"

    var body: some View {
        Form {
            NameSection(player: $player, playedToday: playedToday)
            ReminderSection()
            Section {
                Toggle("Distances in kilometers", isOn: $kilometers)
                    .toggleStyle(.switch)
            }
            Section("Appearance") {
                Picker("Appearance", selection: $appearance) {
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                    Text("System").tag("system")
                }
                .pickerStyle(.segmented)
            }
            if account.auth.isConfigured {
                Section("Twitch") {
                    if let session = account.session {
                        LabeledContent("Signed in as", value: session.login)
                        // A mod's second login, for the scopes that delete,
                        // time out and ban.
                        if account.needsModLogin {
                            if let code = account.modCode {
                                TwitchCodeRows(code: code, prominentLabel: .paper).tint(Color.ink)
                            } else {
                                Button("Access your mod tools") { account.startModLogin() }
                            }
                        }
                        Button("Sign out", role: .destructive) { account.signOut() }
                    } else {
                        TwitchSignIn()
                    }
                }
            }
            #if canImport(TempomatConsole)
                if account.isOwner, let token = account.session?.accessToken {
                    ConsoleTierSection(token: token)
                }
            #endif
            if account.isRealOwner {
                Section {
                    Picker(
                        "View as",
                        selection: Binding(
                            get: { account.previewTier ?? "me" },
                            set: { account.previewTier = $0 == "me" ? nil : $0 }
                        )
                    ) {
                        Text("Me").tag("me")
                        Text("Mod").tag("mod")
                        Text("Viewer").tag("viewer")
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text("Shows the app the way a mod or a viewer sees it. Anything you press still runs as you.")
                }
            }
        }
        .readableWidth(title: "Settings")
        .paper()
        // Read on every visit rather than once: the Play tab saves as it goes.
        .onAppear { playedToday = !DayProgress.resume(Saved.progress, on: GuessrClient.today()).played.isEmpty }
        .task { await account.refreshIfNeeded() }
    }
}

/// The name the boards show, and a reroll that keeps the one name before it,
/// as the web's About panel does. The server records whatever name the next
/// play carries, so a new one shows from the next round on. Below them, the
/// ways another device plays as this same name.
struct NameSection: View {
    @Binding var player: Player
    let playedToday: Bool
    @AppStorage("alias-prev") private var previous = ""

    var body: some View {
        Section("Leaderboard name") {
            // Serif, after the web's ET Book, so the name reads as the name.
            Text(player.alias).font(.system(.title2, design: .serif, weight: .semibold))
            Button("Generate new name") {
                var next = Alias.random()
                while next == player.alias { next = Alias.random() }
                previous = player.alias
                player.alias = next
            }
            if !previous.isEmpty {
                Button("Undo, back to \(previous)") {
                    player.alias = previous
                    previous = ""
                }
            }
            // Beside the name: a linked device plays as this same name.
            LinkCodeRows(player: $player, playedToday: playedToday)
        }
    }
}

/// A code the web types in to join this device's player, live ten minutes.
/// Once a code is showing, the other direction is offered too: entering a code
/// the web drew.
struct LinkCodeRows: View {
    @Binding var player: Player
    let playedToday: Bool
    @State private var code: LinkCode?
    @State private var asking = false
    @State private var error: String?

    private let client = GuessrClient()

    var body: some View {
        if let code {
            LabeledContent("Temporary code") { Text(code.code).font(.title3.monospaced()) }
            // A markdown link opens in Safari, where the web game keeps its save.
            Text("Visit [guessr.dana.lol](https://guessr.dana.lol), tap About, and enter this code under \"Link a device\".")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        Button(asking ? "Asking…" : code == nil ? "Link a device" : "Show a new code") { Task { await issue() } }
            .disabled(asking)
        if let error {
            Text(error).foregroundStyle(.secondary)
        }
        // Only before the first guess: joining after it would leave the day's
        // progress on this device belonging to the player it left.
        if code != nil, !playedToday {
            NavigationLink("Enter your code") { JoinView(player: $player) }
        }
    }

    private func issue() async {
        asking = true
        defer { asking = false }
        do {
            (code, error) = (try await client.issueLinkCode(for: player), nil)
        } catch {
            self.error = String(localized: "Could not reach the server. Try again.")
        }
    }
}

/// The Twitch device-code sign-in as form rows: a button, then the code to
/// enter at Twitch until the login lands.
struct TwitchSignIn: View {
    @Environment(Account.self) private var account
    @State private var code: DeviceCode?
    @State private var error: String?
    #if DEBUG
        @State private var pressedForLaunchArgument = false
    #endif

    var body: some View {
        if let code {
            TwitchCodeRows(code: code, prominentLabel: .paper).tint(Color.ink)
        } else {
            Button("Sign in with Twitch") { Task { await signIn() } }
                .disabled(!account.auth.isConfigured)
                #if DEBUG
                    // `-signin 1` presses the button once on appear, so the
                    // code screen can be screenshotted from the shell. A task
                    // of its own, as the press is: the button leaves when the
                    // code arrives, which would cancel `.task`'s.
                    .onAppear {
                        guard UserDefaults.standard.bool(forKey: "signin"), !pressedForLaunchArgument else { return }
                        pressedForLaunchArgument = true
                        Task { await signIn() }
                    }
                #endif
        }
        if let error {
            Text(error).foregroundStyle(.secondary)
        }
    }

    private func signIn() async {
        error = nil
        do {
            let started = try await account.auth.start()
            code = started
            try await account.signIn(started)
        } catch {
            self.error = error.localizedDescription
        }
        code = nil
    }
}
