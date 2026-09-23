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

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.lastMethod = request.httpMethod
        // URLSession hands a protocol the body as a stream, not as httpBody.
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
        Self.lastBody = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: (try? fixture("score")) ?? Data())
        client?.urlProtocolDidFinishLoading(self)
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
        image: image, guess: Coordinate(lat: 33.76, lng: -118.28), date: "2026-09-23", player: player)
    #expect(scored.points == 4091)
    #expect(scored.state == "California")
    #expect(scored.answer == Coordinate(lat: 33.913757, lng: -117.324235))
    #expect(scored.miles == 56)
    #expect(ScoringGuessr.lastMethod == "POST")
    let body = ScoringGuessr.lastBody
    #expect(body["image"] as? String == image)
    #expect(body["date"] as? String == "2026-09-23")
    #expect(body["player_id"] as? String == player.id)
    #expect(body["handle"] as? String == "Patient Delta")
    #expect(body["lat"] as? Double == 33.76)
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
/// here that isn't there would put a nameless row on the board.
@Test func aliasListsMatchTheWebGame() throws {
    let js = try String(
        contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "../../../../web/alias.js").standardizedFileURL,
        encoding: .utf8)
    for (name, words) in [("ADJECTIVES", Alias.adjectives), ("NOUNS", Alias.nouns)] {
        let block = try #require(js.firstMatch(of: try Regex("export const \(name) = \\[([^\\]]*)\\];")))
        let listed = block.output[1].substring.map { String($0) } ?? ""
        let web = Set(listed.matches(of: /'(\w+)'/).map { String($0.output.1) })
        #expect(web == Set(words), "\(name) differs from web/alias.js")
    }
}
