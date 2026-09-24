import Foundation

/// The string a finished day shares: which day, a square per round, the total,
/// and where to play. A copy of `web/share.js`, so a result pasted from the app
/// reads the same as one pasted from the browser; `shareTextMatchesTheWebGame`
/// fails on any drift in the bands or the link.
public enum Share {
    /// The canonical host rather than the build's API base: a pasted link
    /// outlives the build that made it.
    public static let homeURL = "https://guessr.dana.lol"
    public static let maxRoundScore = 5000

    /// Score bands, best first; a round takes the square of the first band it
    /// clears. 4989 is a guess within a kilometre.
    public static let bands: [(min: Int, square: String)] = [
        (4989, "🏆"), (4000, "🟩"), (2500, "🟨"), (1000, "🟧"), (0, "⬜"),
    ]

    /// Day 1 is 2026-07-31. Counted between calendar dates in UTC, so a DST
    /// change never shifts the number.
    public static func dayNumber(for date: String) -> Int? {
        let style = Date.ISO8601FormatStyle().year().month().day()
        guard let day = try? style.parse(date), let epoch = try? style.parse("2026-07-31") else { return nil }
        return Int((day.timeIntervalSince(epoch) / 86400).rounded()) + 1
    }

    public static func square(for points: Int) -> String {
        bands.first { points >= $0.min }?.square ?? "⬜"
    }

    /// Totals are grouped in `locale`, as the web's `toLocaleString()` does.
    public static func text(day: Int, results: [Int], total: Int, locale: Locale = .current) -> String {
        let n = { (v: Int) in v.formatted(.number.locale(locale)) }
        return [
            "Guessr #\(day)",
            results.map(square(for:)).joined(),
            "\(n(total)) / \(n(results.count * maxRoundScore))",
            homeURL,
        ].joined(separator: "\n")
    }
}

extension DayProgress {
    /// What a player pastes once the day is played; nil for a malformed date.
    public func shareText(locale: Locale = .current) -> String? {
        Share.dayNumber(for: date).map {
            Share.text(day: $0, results: played.map(\.score.points), total: total, locale: locale)
        }
    }
}
