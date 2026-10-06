import Foundation
import GuessrKit
import Testing

private let enUS = Locale(identifier: "en_US")

@Test func dayNumbersMatchTheWebGame() {
    // Expected values from web/daily.js's dayNumber; 2027-03-15 is past a DST change.
    #expect(Share.dayNumber(for: "2026-07-31") == 1)
    #expect(Share.dayNumber(for: "2026-09-24") == 56)
    #expect(Share.dayNumber(for: "2027-03-15") == 228)
    #expect(Share.dayNumber(for: "not a date") == nil)
}

@Test(arguments: [
    (5000, "🏆"), (4989, "🏆"), (4988, "🟩"), (4000, "🟩"), (3999, "🟨"), (2500, "🟨"),
    (2499, "🟧"), (1000, "🟧"), (999, "⬜"), (0, "⬜"),
])
func bandBoundaries(points: Int, square: String) {
    #expect(Share.square(for: points) == square)
}

@Test func textMatchesTheWebGame() {
    // node: shareText(56, [4989, 4988, 3999, 1000, 0], 14976) from web/share.js
    #expect(
        Share.text(day: 56, results: [4989, 4988, 3999, 1000, 0], total: 14976, locale: enUS)
            == "Guessr #56\n🏆🟩🟨🟧⬜\n14,976 / 25,000\nhttps://guessr.dana.lol")
}

@Test func shareTextMatchesTheWebGame() throws {
    let web = try String(
        contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "../../../../web/share.js").standardizedFileURL,
        encoding: .utf8)
    #expect(web.contains("HOME_URL = '\(Share.homeURL)'"), "home URL differs from web/share.js")
    #expect(web.contains("MAX_ROUND_SCORE = \(Share.maxRoundScore);"))
    for band in Share.bands {
        #expect(web.contains("{ min: \(band.min), square: '\(band.square)'"), "band \(band.min) differs from web/share.js")
    }
}
