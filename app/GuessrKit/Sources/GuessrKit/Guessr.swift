import Foundation

// URLSession and its companions are part of Foundation on Apple platforms and a
// separate module in corelibs-Foundation, which is what Linux builds against.
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

public struct Coordinate: Sendable, Equatable, Codable {
    public var lat: Double
    public var lng: Double

    public init(lat: Double, lng: Double) {
        self.lat = lat
        self.lng = lng
    }
}

/// A date's game: its clips, in the order they play. Image names and nothing
/// else — where each was shot stays on the server until a guess is scored.
public struct GuessrDay: Sendable, Equatable, Decodable {
    public struct Round: Sendable, Equatable, Decodable, Identifiable {
        /// The clip's public path, which doubles as its storage key.
        public var image: String
        public var id: String { image }

        public init(image: String) { self.image = image }

        public var clipURL: URL { Guessr.baseURL.appending(path: image) }
    }

    /// Null for a practice draw, which spans finished days.
    public var date: String?
    public var rounds: [Round]

    public init(date: String?, rounds: [Round]) {
        self.date = date
        self.rounds = rounds
    }
}

/// One round as a player played it: the clip, where they pinned, and where the
/// footage was shot.
///
/// Only closed dates make one. The game withholds the pin, the clip and the
/// truth for a date still open, since publishing any of them would hand out the
/// answer to a round other people have yet to play.
public struct GuessrRound: Sendable, Equatable, Identifiable {
    public var date: String
    /// The player, as the board names them.
    public var name: String
    public var image: String
    /// How far the guess landed from the truth.
    public var km: Double
    public var points: Int
    public var guess: Coordinate
    public var answer: Coordinate

    /// A date deals five rounds, one per clip.
    public var id: String { "\(date)/\(image)" }

    public init(
        date: String, name: String, image: String, km: Double, points: Int,
        guess: Coordinate, answer: Coordinate
    ) {
        self.date = date
        self.name = name
        self.image = image
        self.km = km
        self.points = points
        self.guess = guess
        self.answer = answer
    }

    public var clipURL: URL { Guessr.baseURL.appending(path: image) }

    /// Who played it and how well — "Open Arroyo · 79.7 km · 4188 pts".
    public var line: String {
        "\(name) · \(km.formatted(.number.precision(.fractionLength(1)))) km · \(points) pts"
    }
}

/// One period's players, best first. The daily board covers the last date that
/// closed; the monthly one covers the running month.
public struct GuessrLeaderboard: Sendable, Equatable, Decodable {
    public struct Row: Sendable, Equatable, Decodable, Identifiable {
        public var name: String
        public var points: Int

        public var id: String { name }

        public init(name: String, points: Int) {
            self.name = name
            self.points = points
        }

        /// A row arrives as a bare pair rather than an object —
        /// `["Patient Delta", 12456]`.
        public init(from decoder: Decoder) throws {
            var pair = try decoder.unkeyedContainer()
            name = try pair.decode(String.self)
            points = try pair.decode(Int.self)
        }
    }

    /// What the rows cover — "2026-09-07" daily, "2026-09" monthly.
    public var period: String
    public var rows: [Row]

    public init(period: String, rows: [Row]) {
        self.period = period
        self.rows = rows
    }
}

public enum Guessr {
    /// The server: the app's `GuessrAPIBase` Info.plist entry, or production
    /// for a caller with no such entry (the package tests, say).
    public static let baseURL =
        (Bundle.main.object(forInfoDictionaryKey: "GuessrAPIBase") as? String).flatMap { URL(string: $0) }
        ?? URL(string: "https://guessr.dana.lol")!

    /// The server's keys are snake_case.
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    /// The drilldown for one ranked player's rounds: a day's, against that
    /// day's board, or the running month's when no day is named.
    public static func roundsURL(base: URL = baseURL, on day: String? = nil, rank: Int = 1) -> URL {
        var items = [
            URLQueryItem(name: "board", value: day == nil ? "monthly" : "daily"),
            URLQueryItem(name: "rank", value: String(rank)),
        ]
        if let day { items.append(URLQueryItem(name: "date", value: day)) }
        return base.appending(path: "api/guesses").appending(queryItems: items)
    }

    /// A `/api/guesses` body as rounds, dropping the rows it withheld — an open
    /// date's, which arrive with null coordinates and no clip.
    public static func rounds(from data: Data) throws -> [GuessrRound] {
        let board = try decoder.decode(Board.self, from: data)
        return board.rows.compactMap { row in
            guard let image = row.image,
                let guessLat = row.guessLat, let guessLng = row.guessLng,
                let answerLat = row.answerLat, let answerLng = row.answerLng
            else { return nil }
            return GuessrRound(
                date: row.date, name: board.name, image: image, km: row.km, points: row.points,
                guess: Coordinate(lat: guessLat, lng: guessLng),
                answer: Coordinate(lat: answerLat, lng: answerLng)
            )
        }
    }

    private struct Board: Decodable {
        var name: String
        var rows: [Row]

        struct Row: Decodable {
            var date: String
            var km: Double
            var points: Int
            var image: String?
            var guessLat: Double?
            var guessLng: Double?
            var answerLat: Double?
            var answerLng: Double?
        }
    }
}

/// A read the server refused, carrying the sentence it gave as its reason.
public enum GuessrError: Error, LocalizedError, Equatable {
    case http(status: Int, message: String)

    /// A 4xx: the request itself is refused, so sending it again gets the same
    /// answer. Anything else is worth a retry.
    public var isFinal: Bool {
        switch self {
        case .http(let status, _): (400..<500).contains(status)
        }
    }

    public var errorDescription: String? {
        switch self {
        case .http(_, let message): message
        }
    }
}

/// The game's public read side. Unauthenticated: a player's credential is the
/// id their client mints, and nothing here reads as a player.
public struct GuessrClient: Sendable {
    public var baseURL: URL
    public var session: URLSession

    public init(baseURL: URL = Guessr.baseURL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    /// A date's rounds. Up to three dates are open at once and every closed one
    /// stays readable; anything later is refused.
    public func day(_ date: String = GuessrClient.today()) async throws -> GuessrDay {
        try Guessr.decoder.decode(
            GuessrDay.self,
            from: try await data(
                baseURL.appending(path: "api/day")
                    .appending(queryItems: [URLQueryItem(name: "date", value: date)])))
    }

    /// The board for a period, best player first: "daily" for the last date
    /// that closed, "monthly" for the running month.
    public func leaderboard(board: String = "daily") async throws -> GuessrLeaderboard {
        try Guessr.decoder.decode(
            GuessrLeaderboard.self,
            from: try await data(
                baseURL.appending(path: "api/leaderboard")
                    .appending(queryItems: [URLQueryItem(name: "board", value: board)])))
    }

    /// One ranked player's rounds for a day, or for the running month. The open
    /// date's rows come back withheld and are dropped.
    public func rounds(on day: String? = nil, rank: Int = 1) async throws -> [GuessrRound] {
        try Guessr.rounds(from: try await data(Guessr.roundsURL(base: baseURL, on: day, rank: rank)))
    }

    /// The date the game calls today: local rather than UTC, so the round turns
    /// over at the player's own midnight, as it does on the web.
    public static func today(_ now: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: now)
    }

    private func data(_ url: URL) async throws -> Data {
        try await data(URLRequest(url: url))
    }

    func data(_ request: URLRequest) async throws -> Data {
        var req = request
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.settledData(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            struct Envelope: Decodable { var error: String }
            let message =
                (try? JSONDecoder().decode(Envelope.self, from: data))?.error
                ?? String(decoding: data, as: UTF8.self)
            throw GuessrError.http(status: http.statusCode, message: message)
        }
        return data
    }
}

extension URLSession {
    /// `data(for:)`, out of cancellation's reach on corelibs-Foundation, which
    /// resumes its continuation a second time when a task is cancelled
    /// mid-flight and then traps. An unstructured task doesn't inherit
    /// cancellation, so the request runs to its end. Apple's Foundation cancels
    /// cleanly and gets the plain call.
    func settledData(for request: URLRequest) async throws -> (Data, URLResponse) {
        #if canImport(FoundationNetworking)
            try await Task { try await self.data(for: request) }.value
        #else
            try await data(for: request)
        #endif
    }
}
