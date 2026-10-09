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

/// Answers every request with the score fixture and keeps the last body sent.
final class ScoringGuessr: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var lastBody: [String: Any] = [:]
    nonisolated(unsafe) static var lastMethod: String?
    nonisolated(unsafe) static var lastUserAgent: String?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.lastMethod = request.httpMethod
        Self.lastUserAgent = request.value(forHTTPHeaderField: "User-Agent")
        Self.lastBody = jsonBody(of: request)
        answer(self, with: "score")
    }
}

/// Answers every request with the link-claim fixture and keeps the last request.
final class ClaimingGuessr: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var lastBody: [String: Any] = [:]
    nonisolated(unsafe) static var lastPath: String?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.lastPath = request.url?.path
        Self.lastBody = jsonBody(of: request)
        answer(self, with: "link-claim")
    }
}

/// Answers every request with the link-preview fixture and keeps the last request.
final class PreviewingGuessr: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var lastBody: [String: Any] = [:]
    nonisolated(unsafe) static var lastPath: String?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.lastPath = request.url?.path
        Self.lastBody = jsonBody(of: request)
        answer(self, with: "link-preview")
    }
}

/// Answers every request with the progress fixture and keeps the last request.
final class RecordingGuessr: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var lastBody: [String: Any] = [:]
    nonisolated(unsafe) static var lastPath: String?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.lastPath = request.url?.path
        Self.lastBody = jsonBody(of: request)
        answer(self, with: "progress")
    }
}

/// Accepts a Game Center sync with an empty body and keeps the request. Its
/// own class rather than RecordingGuessr: tests run in parallel, and the
/// statics are per class.
final class SyncingGuessr: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var lastBody: [String: Any] = [:]
    nonisolated(unsafe) static var lastPath: String?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.lastPath = request.url?.path
        Self.lastBody = jsonBody(of: request)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"submitted":[]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// Answers every request with the link-code fixture and keeps the last request.
final class IssuingGuessr: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var lastBody: [String: Any] = [:]
    nonisolated(unsafe) static var lastPath: String?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.lastPath = request.url?.path
        Self.lastBody = jsonBody(of: request)
        answer(self, with: "link-code")
    }
}

/// URLSession hands a protocol the body as a stream, not as httpBody.
private func jsonBody(of request: URLRequest) -> [String: Any] {
    var body = request.httpBody ?? Data()
    if let stream = request.httpBodyStream {
        stream.open()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            body.append(buffer, count: n)
        }
        stream.close()
    }
    return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
}

private func answer(_ proto: URLProtocol, with name: String) {
    let response = HTTPURLResponse(url: proto.request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
    proto.client?.urlProtocol(proto, didReceive: response, cacheStoragePolicy: .notAllowed)
    proto.client?.urlProtocol(proto, didLoad: (try? fixture(name)) ?? Data())
    proto.client?.urlProtocolDidFinishLoading(proto)
}

/// Answers the website's merge, /api/link, as the server does.
final class LinkingGuessr: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var lastBody: [String: Any] = [:]
    nonisolated(unsafe) static var lastPath: String?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.lastPath = request.url?.path
        Self.lastBody = jsonBody(of: request)
        answer(self, with: "link")
    }
}

/// Refuses every play the way /api/score refuses one against a closed date.
final class ClosedGuessr: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"error":"that day is closed"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private func client(_ proto: AnyClass) -> GuessrClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [proto]
    return GuessrClient(session: URLSession(configuration: config))
}

private let snake: JSONDecoder = {
    let d = JSONDecoder()
    d.keyDecodingStrategy = .convertFromSnakeCase
    return d
}()

private let player = Player(id: "0b7c1d2e-3f40-4a5b-8c6d-7e8f90a1b2c3", alias: "Patient Delta")
private let image = "clips/2018_1015_183219_002_opt-026000.mp4"

@Test func aGuessPostsAPlayAndDecodesTheReveal() async throws {
    let scored = try await client(ScoringGuessr.self).score(
        image: image, guess: Coordinate(lat: 33.76, lng: -118.28), date: "2026-09-23", player: player,
        elapsed: .milliseconds(8200))
    #expect(scored.points == 4091)
    #expect(scored.state == "California")
    #expect(scored.answer == Coordinate(lat: 33.913757, lng: -117.324235))
    #expect(scored.miles == 56)
    #expect(ScoringGuessr.lastMethod == "POST")
    #expect(ScoringGuessr.lastUserAgent?.hasPrefix("Guessr/") == true)
    let body = ScoringGuessr.lastBody
    #expect(body["image"] as? String == image)
    #expect(body["date"] as? String == "2026-09-23")
    #expect(body["player_id"] as? String == player.id)
    #expect(body["handle"] as? String == "Patient Delta")
    #expect(body["lat"] as? Double == 33.76)
    #expect(body["elapsed_ms"] as? Int == 8200)
}

@Test func aClosedDayIsARefusalNotARetry() async throws {
    do {
        _ = try await client(ClosedGuessr.self).score(
            image: image, guess: Coordinate(lat: 0, lng: 0), date: "2026-01-01", player: player)
        Issue.record("expected a refusal")
    } catch let error as GuessrError {
        #expect(error == .http(status: 403, message: "that day is closed"))
        #expect(error.isFinal)
    }
    #expect(!GuessrError.http(status: 502, message: "").isFinal)
}

@Test func aClaimedCodeNamesThePlayerToJoin() async throws {
    let claim = try await client(ClaimingGuessr.self).claimLink(code: "ABCD2345", from: player)
    #expect(claim == LinkClaim(playerId: "5d2c8e1a-9b3f-4c7d-a6e0-1f2b3c4d5e6f", moved: 3))
    #expect(ClaimingGuessr.lastPath == "/api/link/claim")
    #expect(ClaimingGuessr.lastBody["code"] as? String == "ABCD2345")
    #expect(ClaimingGuessr.lastBody["from"] as? String == player.id)
}

@Test func aGameCenterSyncNamesBothPlayersAndNoScore() async throws {
    try await client(SyncingGuessr.self).syncGameCenter(player: player, gamePlayerID: "A:_5f21e308073d18f9b3afdc37f646e851")
    #expect(SyncingGuessr.lastPath == "/api/gamecenter")
    #expect(SyncingGuessr.lastBody["player_id"] as? String == player.id)
    #expect(SyncingGuessr.lastBody["game_player_id"] as? String == "A:_5f21e308073d18f9b3afdc37f646e851")
    // The server computes the standing; a body carrying a score would be the cheat.
    #expect(SyncingGuessr.lastBody.count == 2)
}

/// A player store that holds whatever it was last given.
final class MemoryPlayerStore: PlayerStore, @unchecked Sendable {
    var player: Player?
    init(_ player: Player? = nil) { self.player = player }
    func load() -> Player? { player }
    func save(_ player: Player) { self.player = player }
}

@Test func aHandedOverPlayerIsAdoptedOnlyByAnEmptyStore() {
    let clips = Player(id: "clip", alias: "Clip Player")
    let empty = MemoryPlayerStore()
    #expect(empty.current(orAdopt: clips) == clips)
    #expect(empty.player == clips)
    let kept = Player(id: "kept", alias: "Kept Player")
    #expect(MemoryPlayerStore(kept).current(orAdopt: clips) == kept)
    #expect(MemoryPlayerStore().current().alias.isEmpty == false)
}

@Test func theGroupStoreRoundTripsAPlayer() {
    let suite = "lol.dana.guessr.tests.\(UUID().uuidString)"
    let store = GroupPlayerStore(suite: suite)
    #expect(store.load() == nil)
    let player = Player(id: "abc", alias: "Patient Delta")
    store.save(player)
    #expect(GroupPlayerStore(suite: suite).load() == player)
    UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
}

@Test func theWebsitesLinkCodeNamesThePlayerAndTheirName() {
    // What web/link.js writes: URLSearchParams, so a space is a `+`.
    let link = DeviceLink(URL(string: "https://guessr.dana.lol/#link=5d2c8e1a-9b3f-4c7d-a6e0-1f2b3c4d5e6f&name=Patient+Delta")!)
    #expect(link == DeviceLink(id: "5d2c8e1a-9b3f-4c7d-a6e0-1f2b3c4d5e6f", name: "Patient Delta"))
    #expect(DeviceLink(URL(string: "https://guessr.dana.lol/#link=abc")!) == DeviceLink(id: "abc"))
    #expect(DeviceLink(URL(string: "https://guessr.dana.lol/")!) == nil)
    #expect(DeviceLink(URL(string: "https://guessr.dana.lol/?link=abc")!) == nil)
    #expect(DeviceLink(URL(string: "https://guessr.dana.lol/#name=Nobody")!) == nil)
}

@Test func aDeviceLinkMovesThisPlayersPlays() async throws {
    let moved = try await client(LinkingGuessr.self).link(DeviceLink(id: "5d2c8e1a-9b3f-4c7d-a6e0-1f2b3c4d5e6f"), from: player)
    #expect(moved == 3)
    #expect(LinkingGuessr.lastPath == "/api/link")
    #expect(LinkingGuessr.lastBody["from"] as? String == player.id)
    #expect(LinkingGuessr.lastBody["to"] as? String == "5d2c8e1a-9b3f-4c7d-a6e0-1f2b3c4d5e6f")
}

@Test func aPreviewedCodeNamesBothPlayers() async throws {
    let preview = try await client(PreviewingGuessr.self).previewLink(code: "ABCD2345", from: player)
    #expect(preview.to == LinkPreview.Standing(name: "Patient Delta", points: 12345))
    #expect(preview.from == LinkPreview.Standing(name: "Lucky Overpass", points: 500))
    #expect(PreviewingGuessr.lastPath == "/api/link/preview")
    #expect(PreviewingGuessr.lastBody["code"] as? String == "ABCD2345")
    #expect(PreviewingGuessr.lastBody["from"] as? String == player.id)
}

@Test func anIssuedCodeIsForThisPlayer() async throws {
    let code = try await client(IssuingGuessr.self).issueLinkCode(for: player)
    #expect(code == LinkCode(code: "K7QM2XPB", expiresAt: "2026-09-28T23:59:00Z"))
    #expect(IssuingGuessr.lastPath == "/api/link/code")
    #expect(IssuingGuessr.lastBody["player_id"] as? String == player.id)
}

@Test func recordedRoundsComeBackInDealtOrderWithTheAnswerStandingInForALostPin() async throws {
    let rounds = try await client(RecordingGuessr.self).progress(on: "2026-09-23", for: player)
    #expect(RecordingGuessr.lastPath == "/api/progress")
    #expect(RecordingGuessr.lastBody["date"] as? String == "2026-09-23")
    #expect(RecordingGuessr.lastBody["player_id"] as? String == player.id)
    #expect(rounds.count == 2)
    #expect(rounds[0].guess == Coordinate(lat: 33.76, lng: -118.28))
    #expect(rounds[0].score.points == 4091)
    #expect(rounds[0].score.recorded)
    #expect(rounds[1].guess == rounds[1].score.answer)
}

@Test func aDayStartedElsewhereSeedsThisDeviceUpToTheFirstGap() throws {
    let day = try snake.decode(GuessrDay.self, from: fixture("day"))
    let score = try snake.decode(GuessrScore.self, from: fixture("score"))
    func played(_ i: Int) -> PlayedRound { PlayedRound(image: day.rounds[i].image, guess: Coordinate(lat: 0, lng: 0), score: score) }
    let fresh = DayProgress(date: day.date!)
    #expect(fresh.seeded(from: [played(0), played(1)], in: day).played.count == 2)
    #expect(fresh.seeded(from: [played(1), played(0)], in: day).played.map(\.image) == [day.rounds[0].image, day.rounds[1].image])
    #expect(fresh.seeded(from: [played(0), played(2)], in: day).played.count == 1, "a gap ends the resume")
    #expect(fresh.seeded(from: [played(1)], in: day).played.isEmpty, "nothing without the first round")
    let local = DayProgress(date: day.date!, played: [played(0), played(1), played(2)])
    #expect(local.seeded(from: [played(0)], in: day) == local, "the server never shortens a day")
}

@Test func progressResumesItsOwnDateOnly() throws {
    let day = try snake.decode(GuessrDay.self, from: fixture("day"))
    let score = try snake.decode(GuessrScore.self, from: fixture("score"))
    let one = PlayedRound(image: day.rounds[0].image, guess: Coordinate(lat: 0, lng: 0), score: score)
    let saved = DayProgress(date: "2026-09-23", played: [one])

    #expect(DayProgress.resume(saved, on: "2026-09-23") == saved)
    #expect(DayProgress.resume(saved, on: "2026-09-24").played.isEmpty)
    #expect(DayProgress.resume(nil, on: "2026-09-23").played.isEmpty)
    #expect(saved.next(in: day) == day.rounds[1])
    #expect(saved.total == 4091)

    let done = DayProgress(date: "2026-09-23", played: Array(repeating: one, count: day.rounds.count))
    #expect(done.next(in: day) == nil)
}

@Test func aStreakShowsWhileItCouldStillGrow() throws {
    let score = try snake.decode(GuessrScore.self, from: fixture("score"))
    #expect(score.streak == 3 && score.streakDate == "2026-09-23")
    func streak(_ days: Int?, endingOn end: String?, today: String) throws -> Int? {
        var s = score
        (s.streak, s.streakDate) = (days, end)
        let noon = try #require(ISO8601DateFormatter().date(from: "\(today)T12:00:00Z"))
        let progress = DayProgress(date: today, played: [PlayedRound(image: image, guess: s.answer, score: s)])
        return progress.streak(now: noon)
    }
    #expect(try streak(3, endingOn: "2026-09-23", today: "2026-09-23") == 3)
    #expect(try streak(3, endingOn: "2026-09-30", today: "2026-10-01") == 3, "yesterday, across a month")
    #expect(try streak(3, endingOn: "2026-09-21", today: "2026-09-23") == nil, "a broken run")
    #expect(try streak(1, endingOn: "2026-09-23", today: "2026-09-23") == nil, "one day is no streak")
    #expect(try streak(nil, endingOn: nil, today: "2026-09-23") == nil, "practice carries none")
    #expect(DayProgress(date: "2026-09-23").streak() == nil)
}

@Test func aPlayerIsMintedOnceAndKept() {
    let store = MemoryPlayerStore()
    let first = store.current()
    #expect(store.current() == first)
    #expect(UUID(uuidString: first.id) != nil)
    #expect(first.id == first.id.lowercased())
    let words = first.alias.split(separator: " ").map(String.init)
    #expect(words.count == 2 && Alias.adjectives.contains(words[0]) && Alias.nouns.contains(words[1]))
}

/// The server keeps only a handle drawn from the web game's lists, so a word
/// here that isn't there would put a nameless row on the board. Order is held
/// too, so the copy stays a copy rather than a set that happens to match.
@Test func aliasListsMatchTheWebGame() throws {
    let data = try Data(
        contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "../../../../web/alias.json").standardizedFileURL)
    let web = try JSONDecoder().decode([String: [String]].self, from: data)
    #expect(web["adjectives"] == Alias.adjectives, "adjectives differ from web/alias.json")
    #expect(web["nouns"] == Alias.nouns, "nouns differ from web/alias.json")
}
