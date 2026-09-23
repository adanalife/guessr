import Foundation

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

    public init(
        km: Double, points: Int, lat: Double, lng: Double, state: String, filmed: String, recorded: Bool
    ) {
        (self.km, self.points, self.lat, self.lng) = (km, points, lat, lng)
        (self.state, self.filmed, self.recorded) = (state, filmed, recorded)
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

public final class MemoryPlayerStore: PlayerStore, @unchecked Sendable {
    private let lock = NSLock()
    private var player: Player?

    public init(_ player: Player? = nil) { self.player = player }

    public func load() -> Player? { lock.withLock { player } }
    public func save(_ player: Player) { lock.withLock { self.player = player } }
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

    public var total: Int { played.reduce(0) { $0 + $1.score.points } }

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
        var req = URLRequest(url: baseURL.appending(path: "api/score"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try encoder.encode(
            Body(
                image: image, lat: guess.lat, lng: guess.lng, date: date,
                playerId: player.id, handle: player.alias))
        return try Guessr.decoder.decode(GuessrScore.self, from: try await data(req))
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
        var req = URLRequest(url: baseURL.appending(path: "api/link/claim"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["code": code, "from": player.id])
        return try Guessr.decoder.decode(LinkClaim.self, from: try await data(req))
    }
}
