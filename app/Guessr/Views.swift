#if canImport(TempomatConsole)
    import TempomatConsole
#endif
import GuessrKit
import SwiftUI

/// Today's rounds and the boards, read from the public API.
struct TodayView: View {
    @State private var day: GuessrDay?
    @State private var board: GuessrLeaderboard?
    @State private var boardName = "daily"
    @State private var error: String?

    private let client = GuessrClient()

    var body: some View {
        List {
            Section("Today") {
                if let day {
                    LabeledContent(day.date ?? "Practice", value: "\(day.rounds.count) rounds")
                }
                Link("Play on the web", destination: Guessr.baseURL)
            }
            Section {
                Picker("Board", selection: $boardName) {
                    Text("Yesterday").tag("daily")
                    Text("This month").tag("monthly")
                }
                .pickerStyle(.segmented)
                ForEach(Array((board?.rows ?? []).enumerated()), id: \.offset) { rank, row in
                    LabeledContent("\(rank + 1). \(row.name)", value: "\(row.points)")
                }
            } header: {
                Text(board.map { "Leaderboard · \($0.period)" } ?? "Leaderboard")
            }
            if let error {
                Text(error).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Guessr")
        .task(id: boardName) { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            async let d = client.day()
            async let b = client.leaderboard(board: boardName)
            (day, board, error) = (try await d, try await b, nil)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct SettingsView: View {
    @Environment(Account.self) private var account

    var body: some View {
        Form {
            Section("Twitch") {
                if let session = account.session {
                    LabeledContent("Signed in as", value: session.login)
                    Button("Sign out", role: .destructive) { account.signOut() }
                } else {
                    TwitchSignIn()
                }
            }
            #if canImport(TempomatConsole)
                if account.isOwner, let token = account.session?.accessToken {
                    ConsoleTierSection(token: token)
                }
            #endif
        }
        .navigationTitle("Settings")
        .task { await account.refreshIfNeeded() }
    }
}

/// The Twitch device-code sign-in as form rows: a button, then the code to
/// enter at Twitch until the login lands.
struct TwitchSignIn: View {
    @Environment(Account.self) private var account
    @State private var code: DeviceCode?
    @State private var error: String?

    var body: some View {
        if let code {
            DeviceCodeRows(code: code)
        } else {
            Button("Sign in with Twitch") { Task { await signIn() } }
                .disabled(!account.auth.isConfigured)
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
