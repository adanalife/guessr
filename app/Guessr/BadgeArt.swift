import GuessrKit
import SwiftUI

/// The chat badge icons, fetched once per launch and cached by the art's URL.
///
/// One object for the whole app rather than per line: every line carries the
/// same handful of badges, so a per-view cache would fetch the moderator icon
/// once for each moderator who speaks.
@MainActor @Observable final class BadgeArt {
    static let shared = BadgeArt()

    private var sets: BadgeSets = [:]
    private var images: [URL: Image] = [:]
    private var asked: Set<URL> = []
    private var loaded = false

    /// Reads Twitch's badge table, once. A failure leaves it unloaded, so the
    /// next visit to the chat log tries again — the text chips show meanwhile.
    func load(from chat: TwitchChat) async {
        guard !loaded, let sets = try? await chat.badgeArt() else { return }
        loaded = true
        self.sets = sets
    }

    /// The icon for a badge, or nil while it is still arriving — or for a badge
    /// Twitch publishes no art for, which is what the chip is still for.
    func icon(_ tag: BadgeTag) -> Image? {
        guard let url = sets.url(for: tag) else { return nil }
        if let art = images[url] { return art }
        guard !asked.contains(url) else { return nil }
        asked.insert(url)
        Task { images[url] = await remoteImage(url, scale: 2) }
        return nil
    }
}
