import GameKit
import GuessrKit
import SwiftUI

/// The Game Center sign-in, and the nudge that has the server submit this
/// player's standing. The app never names a score: it tells the server which
/// Game Center player it is signed in as, and the server submits what its
/// plays table says this guessr player has earned (server/gamecenter.py), so a
/// modified app can claim nothing the real game did not record.
@Observable
final class GameCenter {
    private(set) var signedIn = false
    /// Achievements completed since the last sync, for the toast to name.
    /// Server-submitted achievements never raise Apple's own banner.
    var newlyEarned: [String] = []

    /// The achievements this device has seen completed, so a sync can tell
    /// which ones are new.
    private static let earnedKey = "gamecenter-earned"

    /// Hands GameKit its sign-in. iOS shows its own sheet when the player has
    /// to act and signs a Game Center user in silently otherwise; a device
    /// with no Game Center user stays signed out, and the game is unchanged.
    /// `synced` runs once a sign-in lands, so plays made on the web or before
    /// signing in reach the board too.
    func start(then synced: @escaping () async -> Void) {
        GKLocalPlayer.local.authenticateHandler = { sheet, _ in
            if let sheet { UIApplication.shared.rootViewController?.present(sheet, animated: true) }
            self.signedIn = GKLocalPlayer.local.isAuthenticated
            if self.signedIn { Task { await synced() } }
        }
    }

    /// Asks the server to submit `player`'s standing to the signed-in Game
    /// Center player. A failure is nothing to show: the standing is the
    /// table's, so the next sync carries the same one.
    func sync(_ player: Player, with client: GuessrClient) async {
        guard signedIn else { return }
        try? await client.syncGameCenter(player: player, gamePlayerID: GKLocalPlayer.local.gamePlayerID)
        await noteEarned()
    }

    /// Diffs the completed achievements against the ones seen before. The
    /// first read on a device only records them, so a player who signs in
    /// with a history isn't toasted for all of it at once.
    private func noteEarned() async {
        guard let done = try? await GKAchievement.loadAchievements().filter(\.isCompleted).map(\.identifier) else { return }
        let seen = UserDefaults.standard.stringArray(forKey: Self.earnedKey)
        UserDefaults.standard.set(done, forKey: Self.earnedKey)
        guard let seen else { return }
        let new = Set(done).subtracting(seen)
        guard !new.isEmpty, let all = try? await GKAchievementDescription.loadAchievementDescriptions() else { return }
        newlyEarned = all.filter { new.contains($0.identifier) }.map(\.title)
    }

    /// Game Center's own dashboard over the app: the boards and the achievements.
    func showDashboard() {
        GKAccessPoint.shared.trigger(state: .dashboard) {}
    }
}

extension UIApplication {
    /// The window a system sheet presents over.
    var rootViewController: UIViewController? {
        connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first?.keyWindow?.rootViewController
    }
}

/// "Achievement unlocked" over the top of the screen for a few seconds, one
/// line per achievement a sync found new.
struct AchievementToast: ViewModifier {
    @Environment(GameCenter.self) private var gameCenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if !gameCenter.newlyEarned.isEmpty {
                VStack(spacing: 2) {
                    Label("Achievement unlocked", systemImage: "trophy.fill").font(.caption.bold())
                    ForEach(gameCenter.newlyEarned, id: \.self) { Text($0).font(.system(.headline, design: .serif)) }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
                .padding(.top, 8)
                .transition(reduceMotion ? AnyTransition.opacity : .move(edge: .top).combined(with: .opacity))
                .onTapGesture { gameCenter.newlyEarned = [] }
                .accessibilityAddTraits(.isButton)
                .task {
                    try? await Task.sleep(for: .seconds(4))
                    gameCenter.newlyEarned = []
                }
            }
        }
        .animation(.spring, value: gameCenter.newlyEarned)
        .sensoryFeedback(.success, trigger: gameCenter.newlyEarned) { _, now in !now.isEmpty }
    }
}
