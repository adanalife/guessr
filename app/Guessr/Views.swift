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
                    Text("Yesterday").tag("daily")
                }
                .pickerStyle(.segmented)
                ForEach(Array((board?.rows ?? []).enumerated()), id: \.offset) { rank, row in
                    let mine = isMine(row)
                    LabeledContent("\(rank + 1). \(row.name)\(mine ? " (you)" : "")", value: "\(row.points)")
                        .fontWeight(mine ? .bold : nil)
                        .listRowBackground(mine ? Color.accentColor.opacity(0.15) : nil)
                }
            } header: {
                Text(board.map { "Leaderboard · \($0.period)" } ?? "Leaderboard")
            }
            if let error {
                Text(error).foregroundStyle(.secondary)
            }
        }
        .paper()
        .navigationTitle("Guessr")
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

    var body: some View {
        Form {
            ReminderSection()
            // Only before the first guess: joining after it would leave the
            // day's progress on this device belonging to the player it left.
            if !playedToday {
                Section {
                    NavigationLink("Already playing on the web? Enter your code") { JoinView(player: $player) }
                }
            }
            if account.auth.isConfigured {
                Section("Twitch") {
                    if let session = account.session {
                        LabeledContent("Signed in as", value: session.login)
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
        .paper()
        .navigationTitle("Settings")
        // Read on every visit rather than once: the Play tab saves as it goes.
        .onAppear { playedToday = !DayProgress.resume(Saved.progress, on: GuessrClient.today()).played.isEmpty }
        .task { await account.refreshIfNeeded() }
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
            DeviceCodeRows(code: code)
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

/// A device code waiting on the human: the code, where to enter it, and a
/// spinner for the wait.
struct DeviceCodeRows: View {
    let code: DeviceCode

    var body: some View {
        LabeledContent("Code", value: code.userCode)
        if let url = URL(string: code.verificationUri) {
            Link("Enter it at Twitch", destination: url)
        }
        ProgressView()
    }
}
