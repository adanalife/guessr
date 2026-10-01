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
