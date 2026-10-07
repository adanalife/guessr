import Foundation
import Synchronization

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// What the server says about a guess: how far off it was, what it earned, and
/// where the clip was actually filmed.
public struct GuessrScore: Sendable, Equatable, Codable {
    public var km: Double
    public var points: Int
    public var lat: Double
    public var lng: Double
    /// Where the footage was shot and when — "Massachusetts", "2018-09-17".
    public var state: String
    public var filmed: String
    /// Whether this counted toward a board. A replayed round comes back with
    /// the score already on record, not a fresh one.
    public var recorded: Bool
    /// On a daily play: how many consecutive days the player has finished, and
    /// the date that run ends on. Nil on practice, and on a round rebuilt from
    /// `/api/progress`.
    public var streak: Int?
    public var streakDate: String?

    public init(
        km: Double, points: Int, lat: Double, lng: Double, state: String, filmed: String, recorded: Bool,
        streak: Int? = nil, streakDate: String? = nil
    ) {
        (self.km, self.points, self.lat, self.lng) = (km, points, lat, lng)
        (self.state, self.filmed, self.recorded) = (state, filmed, recorded)
        (self.streak, self.streakDate) = (streak, streakDate)
    }

    public var answer: Coordinate { Coordinate(lat: lat, lng: lng) }

    /// The distance in the units the game speaks.
    public var miles: Int { Int((km * 0.621371).rounded()) }
}

/// Who is playing: an opaque id, which is the only credential the game has, and
/// the name the boards show beside it.
public struct Player: Sendable, Equatable, Codable {
    public var id: String
    public var alias: String

    public init(id: String, alias: String) {
        self.id = id
        self.alias = alias
    }

    /// Lowercase, the form a browser's `crypto.randomUUID()` mints.
    public static func mint() -> Player {
        Player(id: UUID().uuidString.lowercased(), alias: Alias.random())
    }
}

/// The two lists a board name is drawn from. The server drops any handle not
/// made of one word from each. A copy of `web/alias.json`, which a SwiftPM target
/// cannot reach as a resource; `aliasListsMatchTheWebGame` fails on any drift.
public enum Alias {
    public static let adjectives = [
        "Amber", "Ancient", "Autumn", "Bright", "Bronze", "Calm", "Cedar", "Copper",
        "Crimson", "Distant", "Drifting", "Dusty", "Eastern", "Emerald", "Endless",
        "Fading", "Foggy", "Frozen", "Gentle", "Gilded", "Golden", "Granite", "Hazy",
        "Hidden", "Humming", "Idle", "Lonesome", "Lucky", "Marbled", "Midnight",
        "Northern", "Open", "Painted", "Patient", "Quiet", "Rambling", "Restless",
        "Rolling", "Rusted", "Scenic", "Silent", "Silver", "Slanting", "Southern",
        "Sunlit", "Twilight", "Wandering", "Western", "Winding",
    ]
    public static let nouns = [
        "Arroyo", "Badlands", "Basin", "Bluff", "Boulder", "Butte", "Canyon",
        "Cascade", "Causeway", "Cedar", "Compass", "Coulee", "Crossing", "Delta",
        "Diner", "Dunes", "Foothill", "Freeway", "Glacier", "Harbour", "Highway",
        "Junction", "Lantern", "Lookout", "Meadow", "Mesa", "Milepost", "Odometer",
        "Overlook", "Overpass", "Pinewood", "Plateau", "Prairie", "Ridgeline",
        "Roadside", "Sagebrush", "Sandstone", "Shoreline", "Signpost", "Switchback",
        "Timberline", "Trailhead", "Turnout", "Underpass", "Valley", "Viaduct",
        "Wayside", "Wildflower", "Windmill",
    ]

    public static func random() -> String {
        "\(adjectives.randomElement()!) \(nouns.randomElement()!)"
    }
}

/// Where the player is kept between launches. The id is a credential: it lives
/// in the Keychain on a device and is never logged.
public protocol PlayerStore: Sendable {
    func load() -> Player?
    func save(_ player: Player)
}

extension PlayerStore {
    /// The saved player, or a new one minted and saved on first launch.
    public func current() -> Player {
        if let player = load() { return player }
        let player = Player.mint()
        // ponytail: a failed save means a new id next launch and this launch's
        // plays stranded on the old one; link codes are the recovery path.
        save(player)
        return player
    }
}

public final class MemoryPlayerStore: PlayerStore {
    private let player: Mutex<Player?>

    public init(_ player: Player? = nil) { self.player = Mutex(player) }

    public func load() -> Player? { player.withLock { $0 } }
    public func save(_ player: Player) { self.player.withLock { $0 = player } }
}

#if canImport(Security)
    public struct KeychainPlayerStore: PlayerStore {
        let item: KeychainItem

        public init(service: String = "lol.dana.guessr.player") {
            item = KeychainItem(service: service, account: "player")
        }

        public func load() -> Player? {
            item.read().flatMap { try? JSONDecoder().decode(Player.self, from: $0) }
        }

        public func save(_ player: Player) {
            if let data = try? JSONEncoder().encode(player) { item.write(data) }
        }
    }
#endif

/// One round as this device played it, kept so a relaunch resumes the day.
public struct PlayedRound: Sendable, Equatable, Codable {
    public var image: String
    public var guess: Coordinate
    public var score: GuessrScore

    public init(image: String, guess: Coordinate, score: GuessrScore) {
        self.image = image
        self.guess = guess
        self.score = score
    }
}

/// A date's game so far on this device.
public struct DayProgress: Sendable, Equatable, Codable {
    public var date: String
    public var played: [PlayedRound]

    public init(date: String, played: [PlayedRound] = []) {
        self.date = date
        self.played = played
    }

    /// Picks a saved game back up if it is for `date`; any other date starts fresh.
    public static func resume(_ saved: DayProgress?, on date: String) -> DayProgress {
        if let saved, saved.date == date { return saved }
        return DayProgress(date: date)
    }

    /// What the server has on record for this player today, when that is more
    /// than this device remembers: a day started on another device, or under
    /// the player this one just linked to. Walked in the day's order and cut at
    /// the first round not played, so `next(in:)` still deals the right one.
    public func seeded(from recorded: [PlayedRound], in day: GuessrDay) -> DayProgress {
        let byImage = Dictionary(recorded.map { ($0.image, $0) }, uniquingKeysWith: { a, _ in a })
        var rounds: [PlayedRound] = []
        for round in day.rounds {
            guard let played = byImage[round.image] else { break }
            rounds.append(played)
        }
        return rounds.count > played.count ? DayProgress(date: date, played: rounds) : self
    }

    public var total: Int { played.reduce(0) { $0 + $1.score.points } }

    /// The run of finished days worth celebrating, read off the last round's
    /// score: two or more, ending today or yesterday. One day is just a day
    /// played, and a run that ended before yesterday is already broken.
    public func streak(now: Date = Date()) -> Int? {
        guard let score = played.last?.score, let days = score.streak, days >= 2 else { return nil }
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now) ?? now
        let live = [GuessrClient.today(now), GuessrClient.today(yesterday)]
        return live.contains(score.streakDate ?? "") ? days : nil
    }

    /// The next round of `day` to play, or nil once every round is played.
    public func next(in day: GuessrDay) -> GuessrDay.Round? {
        played.count < day.rounds.count ? day.rounds[played.count] : nil
    }
}

extension GuessrClient {
    /// Scores a guess against a date's round and records it for `player`.
    /// First write wins on the server, so a round guessed twice comes back with
    /// the score from the first time.
    public func score(image: String, guess: Coordinate, date: String, player: Player) async throws
        -> GuessrScore
    {
        struct Body: Encodable {
            var image: String
            var lat: Double
            var lng: Double
            var date: String
            var playerId: String
            var handle: String
        }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let body = Body(
            image: image, lat: guess.lat, lng: guess.lng, date: date, playerId: player.id, handle: player.alias)
        // The server files the play under a coarse platform bucket read off
        // the user agent; the system default names CFNetwork and Darwin, not
        // the device.
        let answer = try await post(
            "api/score", body, encoder: encoder, headers: ["User-Agent": await Guessr.userAgent()])
        return try Guessr.decoder.decode(GuessrScore.self, from: answer)
    }
}

extension GuessrClient {
    /// The rounds `player` has on record for `date`, in the order the day dealt
    /// them, each with the score that was recorded. A round from before pins
    /// were kept comes back with its answer standing in for the guess.
    public func progress(on date: String, for player: Player) async throws -> [PlayedRound] {
        struct Row: Decodable {
            var image: String
            var km: Double
            var points: Int
            var guessLat: Double?
            var guessLng: Double?
            var lat: Double
            var lng: Double
            var state: String
            var filmed: String
        }
        struct Answer: Decodable { var rounds: [Row] }
        let answer = try await post("api/progress", ["date": date, "player_id": player.id])
        return try Guessr.decoder.decode(Answer.self, from: answer).rounds.map { r in
            PlayedRound(
                image: r.image,
                guess: Coordinate(lat: r.guessLat ?? r.lat, lng: r.guessLng ?? r.lng),
                score: GuessrScore(
                    km: r.km, points: r.points, lat: r.lat, lng: r.lng, state: r.state, filmed: r.filmed,
                    recorded: true))
        }
    }
}

extension GuessrClient {
    /// Names the Game Center player this device is signed in as, and the server
    /// submits what its plays table says `player` has earned -- the lifetime and
    /// monthly totals and the achievements. No score travels in either
    /// direction: a client cannot name one.
    public func syncGameCenter(player: Player, gamePlayerID: String) async throws {
        _ = try await post("api/gamecenter", ["player_id": player.id, "game_player_id": gamePlayerID])
    }
}

/// What claiming a link code answers: the player this device joins, and how
/// many of its plays moved onto them.
public struct LinkClaim: Sendable, Equatable, Codable {
    public var playerId: String
    public var moved: Int

    public init(playerId: String, moved: Int) {
        self.playerId = playerId
        self.moved = moved
    }
}

extension GuessrClient {
    /// Joins the player who drew `code` on another device: `player`'s plays
    /// fold onto theirs, and the answer is the id to play as from here on. A
    /// code is single-use and lasts ten minutes; an unknown, used or expired one
    /// is a 404.
    public func claimLink(code: String, from player: Player) async throws -> LinkClaim {
        try Guessr.decoder.decode(
            LinkClaim.self, from: try await post("api/link/claim", ["code": code, "from": player.id]))
    }
}

/// The link-a-device QR code on the website, opened on this device: the player
/// to join and the name they go by. The id rides in the URL's fragment, which
/// never reaches a server (see web/link.js); the name is a label for the
/// question, and the id is what links.
///
/// Shared with any App Clip, which opens from a URL the same way.
public struct DeviceLink: Sendable, Equatable {
    public var id: String
    public var name: String?

    public init(id: String, name: String? = nil) {
        self.id = id
        self.name = name
    }

    /// Reads the fragment `URLSearchParams` wrote: `link=<id>&name=<alias>`,
    /// with `+` for a space. Any other URL is nil.
    public init?(_ url: URL) {
        guard let fragment = url.fragment(percentEncoded: true),
            let items = URLComponents(string: "?" + fragment.replacingOccurrences(of: "+", with: "%20"))?.queryItems,
            let id = items.first(where: { $0.name == "link" })?.value, !id.isEmpty, id.count <= 64
        else { return nil }
        self.init(id: id, name: items.first(where: { $0.name == "name" })?.value)
    }
}

extension GuessrClient {
    /// Folds `player`'s plays onto `link`'s player, the merge the website runs
    /// when it opens the same QR code. Answers how many plays moved; the caller
    /// then plays as `link.id`.
    public func link(_ link: DeviceLink, from player: Player) async throws -> Int {
        struct Moved: Decodable { var moved: Int }
        return try Guessr.decoder.decode(Moved.self, from: try await post("api/link", ["from": player.id, "to": link.id])).moved
    }
}

/// What a claim would do: the player a code names and the player this device
/// plays as today, each with their all-time points.
public struct LinkPreview: Sendable, Equatable, Codable {
    public struct Standing: Sendable, Equatable, Codable {
        public var name: String
        public var points: Int

        public init(name: String, points: Int) {
            self.name = name
            self.points = points
        }
    }

    public var to: Standing
    public var from: Standing

    public init(to: Standing, from: Standing) {
        self.to = to
        self.from = from
    }
}

extension GuessrClient {
    /// Looks a code up without claiming it, so the device can ask before
    /// `claimLink` replaces its player. Same 404 as a claim for a code that is
    /// unknown, used or expired.
    public func previewLink(code: String, from player: Player) async throws -> LinkPreview {
        try Guessr.decoder.decode(
            LinkPreview.self, from: try await post("api/link/preview", ["code": code, "from": player.id]))
    }
}

/// A code another device types in to join this player, and when it stops working.
public struct LinkCode: Sendable, Equatable, Codable {
    public var code: String
    public var expiresAt: String

    public init(code: String, expiresAt: String) {
        self.code = code
        self.expiresAt = expiresAt
    }
}

extension GuessrClient {
    /// A fresh code for `player`, live ten minutes; asking again retires the
    /// previous one.
    public func issueLinkCode(for player: Player) async throws -> LinkCode {
        try Guessr.decoder.decode(LinkCode.self, from: try await post("api/link/code", ["player_id": player.id]))
    }
}
