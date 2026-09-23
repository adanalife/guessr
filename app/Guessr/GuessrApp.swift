import GuessrKit
import SwiftUI

@main
struct GuessrApp: App {
    @State private var account = Account()

    var body: some Scene {
        WindowGroup {
            TabView {
                Tab("Today", systemImage: "car") { NavigationStack { TodayView() } }
                Tab("Settings", systemImage: "gear") { NavigationStack { SettingsView() } }
            }
            .environment(account)
        }
    }
}

/// The Twitch login, kept across launches, and what the build says about it.
@Observable
final class Account {
    private(set) var session: TwitchSession?
    let auth: TwitchAuth
    /// Supplied by the build; empty makes nobody the owner.
    let ownerID: String
    private let store: any SessionStore

    init(bundle: Bundle = .main, store: any SessionStore = KeychainSessionStore()) {
        auth = TwitchAuth(clientID: bundle.object(forInfoDictionaryKey: "GuessrTwitchClientID") as? String ?? "")
        ownerID = bundle.object(forInfoDictionaryKey: "GuessrOwnerTwitchID") as? String ?? ""
        self.store = store
        session = store.load()
    }

    var isOwner: Bool { session?.isOwner(ownerID) ?? false }

    func signIn(_ code: DeviceCode) async throws {
        let fresh = try await auth.poll(code)
        store.save(fresh)
        session = fresh
    }

    /// Refreshes a login close to expiry. A refused refresh means the login is
    /// gone, so it is dropped rather than retried.
    func refreshIfNeeded() async {
        guard let old = session, old.expiresSoon else { return }
        do {
            let fresh = try await auth.refresh(old)
            store.save(fresh)
            session = fresh
        } catch is TwitchAuthError {
            signOut()
        } catch {}
    }

    func signOut() {
        store.clear()
        session = nil
    }
}
