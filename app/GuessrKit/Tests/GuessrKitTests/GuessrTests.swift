import Foundation
import GuessrKit
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

private let snake: JSONDecoder = {
    let d = JSONDecoder()
    d.keyDecodingStrategy = .convertFromSnakeCase
    return d
}()

@Test func dayDecodesItsRoundsInPlayOrder() throws {
    let day = try snake.decode(GuessrDay.self, from: fixture("day"))
    #expect(day.date == "2026-09-23")
    #expect(day.rounds.count == 5)
    #expect(
        day.rounds[0].clipURL.absoluteString
            == "https://guessr.dana.lol/clips/2018_1015_183219_002_opt-026000.mp4")
}

@Test func practiceDayHasNoDate() throws {
    let day = try snake.decode(GuessrDay.self, from: Data(#"{"date":null,"rounds":[{"image":"a.mp4"}]}"#.utf8))
    #expect(day.date == nil)
    #expect(day.rounds == [GuessrDay.Round(image: "a.mp4")])
}

@Test func leaderboardDecodesItsPairedRows() throws {
    let board = try snake.decode(GuessrLeaderboard.self, from: fixture("leaderboard"))
    #expect(board.period == "2026-09-07")
    #expect(board.rows.count == 4)
    #expect(board.rows.first == GuessrLeaderboard.Row(name: "Patient Delta", points: 12456))
}

@Test func roundsDropTheOpenDaysWithheldRows() throws {
    let rounds = try Guessr.rounds(from: fixture("guesses"))
    #expect(rounds.map(\.date) == ["2026-09-01", "2026-09-06"])
    let first = try #require(rounds.first)
    #expect(first.answer == Coordinate(lat: 33.913757, lng: -117.324235))
    #expect(first.line == "Patient Delta · 90.3 km · 4091 pts")
}

@Test func roundsURLAsksTheDaysOwnBoardForADay() {
    #expect(Guessr.roundsURL().absoluteString == "https://guessr.dana.lol/api/guesses?board=monthly&rank=1")
    #expect(
        Guessr.roundsURL(on: "2026-09-07").absoluteString
            == "https://guessr.dana.lol/api/guesses?board=daily&rank=1&date=2026-09-07")
}

/// Refuses everything the way /api/day refuses a date that hasn't opened.
final class RefusingGuessr: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"error":"that day has not opened yet"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Test func aRefusalCarriesTheServersReason() async throws {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [RefusingGuessr.self]
    let client = GuessrClient(session: URLSession(configuration: config))
    await #expect(throws: GuessrError.http(status: 403, message: "that day has not opened yet")) {
        try await client.day("2099-01-01")
    }
}

@Test func todayIsTheLocalCalendarDate() {
    var parts = DateComponents()
    (parts.year, parts.month, parts.day, parts.hour) = (2026, 9, 23, 23)
    let lateEvening = Calendar(identifier: .gregorian).date(from: parts)!
    #expect(GuessrClient.today(lateEvening) == "2026-09-23")
}
