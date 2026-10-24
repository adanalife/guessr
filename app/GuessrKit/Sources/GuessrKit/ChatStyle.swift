import Foundation

// How a chat line is drawn: the web console's username palette and hash, its
// badge labels, and Twitch's badge art. A viewer with no Twitch colour is the
// same colour here as in the browser.

/// Per-platform username palettes: a login is hashed, stably, to one of its
/// platform's slots. They lean different ways, so a twitch name and a youtube
/// name that hash to the same slot still read apart.
private let userPalettes = [
    "twitch": [
        "#b694ff", "#9b7bff", "#7fd1ff", "#5ad1c4", "#f2a3ff", "#7fb0ff", "#8ad4ff", "#9ee493",
    ],
    "youtube": [
        "#ff9e80", "#ff8a65", "#ffb74d", "#ffd54f", "#ff7eb3", "#ffab91", "#f48fb1", "#ffcc80",
    ],
]

/// The palette for a platform with none of its own, or no platform at all.
private let defaultPalette = [
    "#7fd1ff", "#5ad1c4", "#b694ff", "#f2a3ff", "#9ee493", "#ffd54f", "#ff9e80", "#ff7eb3",
]

/// The channel owner gets one distinct, never-hashed colour — a warm gold,
/// legible on both themes.
private let broadcasterColor = "#ffc857"

/// Known bot accounts render muted instead of coloured.
// ponytail: a fixed list; a channel bot outside it gets a colour. Learn the
// channel's bot logins from the server if that starts to matter.
private let builtinBots: Set<String> = [
    "nightbot", "streamelements", "streamlabs", "moobot", "fossabot", "wizebot", "sery_bot",
    "commanderroot", "soundalerts", "tripbot", "tripbot4000", "tripbot4001",
]

/// Whether `login` is a known bot account: its name reads muted, and a client
/// that sums up the chat leaves its lines out.
public func isChatBot(_ login: String) -> Bool { builtinBots.contains(login.lowercased()) }

/// Whether `text` is a chat command: `!` and then a name, which is how every
/// channel bot reads one. A lone `!` or `!!!` is a chatter being emphatic.
public func isChatCommand(_ text: String) -> Bool {
    let rest = text.drop { $0.isWhitespace }
    guard rest.first == "!", let next = rest.dropFirst().first else { return false }
    return next.isLetter || next.isNumber
}

/// Whether `text`, sent by `sender`, names `login` — as `@login` or bare, in
/// any case. Twitch logins are letters, digits and underscores, so any other
/// character ends a name, and `kate2` is not `kate`. A line never mentions its
/// own sender: what a reader's own highlight keys on.
public func mentions(_ text: String, from sender: String, naming login: String) -> Bool {
    let me = login.lowercased()
    guard !me.isEmpty, sender.lowercased() != me else { return false }
    return text.lowercased().split { !($0.isLetter || $0.isNumber || $0 == "_") }.contains { $0 == me }
}

/// Stable colour for a username as `#rrggbb`, or nil for a bot, which reads
/// muted. The broadcaster takes the gold; everyone else takes a palette slot
/// keyed by a SHA-1 of the lowercased login — the web console's derivation.
public func usernameColorHex(_ username: String, platform: String? = "twitch", isBroadcaster: Bool = false)
    -> String?
{
    let login = username.lowercased()
    if isBroadcaster { return broadcasterColor }
    if isChatBot(login) { return nil }
    let palette = platform.flatMap { userPalettes[$0] } ?? defaultPalette
    // The palette is a power of two long, so the digest's last byte decides
    // the slot — the same answer as hashing the whole digest as one integer.
    let last = Int(sha1(Array(login.utf8)).last ?? 0)
    return palette[last % palette.count]
}

/// Short labels for the badges common enough to name; anything else shows
/// under its own set id. Broadcaster is left out — the gold name says it.
private let badgeLabels = ["subscriber": "sub", "moderator": "mod"]

extension ChatLine {
    /// The name's colour: muted (nil) for a bot, the colour the chatter picked
    /// on Twitch when there is one, the palette otherwise.
    public var colorHex: String? {
        if isChatBot(login) { return nil }
        if !color.isEmpty { return color }
        return usernameColorHex(login, isBroadcaster: isBroadcaster)
    }

    /// Whether the line names `login` and someone else sent it.
    public func mentions(_ login: String) -> Bool { GuessrKit.mentions(text, from: self.login, naming: login) }

    /// A chatter's first message in the channel.
    public var isFirstMessage: Bool { messageType == "user_intro" }

    /// A message the chatter spent channel points to highlight.
    public var isPointsHighlight: Bool { messageType == "channel_points_highlighted" }

    /// The sender's badges as chips.
    public var badgeTags: [BadgeTag] { GuessrKit.badgeTags(badges) }
}

/// A sender's badges, set id to version, as chips — `mod`, `sub 12`, `founder`
/// — sorted by set id, with the version kept so the art table can be keyed by
/// it. Only the subscriber version is worth showing: it counts months.
/// Broadcaster is left out — the gold name says it.
public func badgeTags(_ badges: [String: String]) -> [BadgeTag] {
    badges.keys.sorted().filter { $0 != "broadcaster" }.map { name in
        let version = badges[name] ?? ""
        let label = badgeLabels[name] ?? name
        // Tier 2 and 3 subscriber versions are 2000 + months and 3000 +
        // months; the chip shows the months.
        if name == "subscriber", let n = Int(version), n % 1000 > 0 {
            return BadgeTag(name: name, version: version, label: "\(label) \(n % 1000)")
        }
        return BadgeTag(name: name, version: version, label: label)
    }
}

/// One of a sender's badges: the set and version Twitch sent, and the chip a
/// client draws when it has no art for them.
public struct BadgeTag: Sendable, Hashable, Identifiable {
    public let name: String
    public let version: String
    public let label: String
    public var id: String { "\(name)/\(version)" }

    public init(name: String, version: String, label: String) {
        self.name = name
        self.version = version
        self.label = label
    }
}

/// Badge art: set id → version id → size key (`url_1x`, `url_2x`, `url_4x`)
/// → URL.
public typealias BadgeSets = [String: [String: [String: String]]]

extension BadgeSets {
    /// The art for a badge, at the size that lands about a line of text.
    public func url(for tag: BadgeTag) -> URL? {
        let sizes = self[tag.name]?[tag.version] ?? [:]
        return (sizes["url_2x"] ?? sizes["url_1x"]).flatMap(URL.init(string:))
    }

    /// Helix's `{data: [{set_id, versions: [{id, image_url_1x…}]}]}`,
    /// reshaped into the table.
    static func helix(_ data: Data) throws -> BadgeSets {
        var out: BadgeSets = [:]
        for set in try Guessr.decoder.decode(HelixBadges.self, from: data).data {
            for v in set.versions {
                out[set.setId, default: [:]][v.id] = ["url_1x": v.imageUrl1x, "url_2x": v.imageUrl2x, "url_4x": v.imageUrl4x]
                    .compactMapValues { $0 }
            }
        }
        return out
    }

    /// `other` layered over this table, version by version.
    func overlaid(with other: BadgeSets) -> BadgeSets {
        merging(other) { mine, theirs in mine.merging(theirs) { _, t in t } }
    }
}

/// Helix's badge list, from either the channel or the global endpoint.
private struct HelixBadges: Decodable {
    struct Set: Decodable {
        struct Version: Decodable {
            var id: String
            var imageUrl1x: String?
            var imageUrl2x: String?
            var imageUrl4x: String?
            // The snake-case strategy reads `image_url_1x` as `imageUrl1X`.
            enum CodingKeys: String, CodingKey {
                case id
                case imageUrl1x = "imageUrl1X", imageUrl2x = "imageUrl2X", imageUrl4x = "imageUrl4X"
            }
        }
        var setId: String
        var versions: [Version]
    }
    var data: [Set]
}

extension Helix {
    /// Twitch's badge art: the global sets with the channel's own on top,
    /// since a channel's subscriber badges replace the stock ones. Read once
    /// and hold.
    public func badgeArt() async throws -> BadgeSets {
        let broadcaster = try await resolveBroadcaster()
        let global = try BadgeSets.helix(try await request("GET", "chat/global_badges"))
        let channel = try BadgeSets.helix(try await request("GET", "chat/badges", query: ["broadcaster_id": broadcaster]))
        return global.overlaid(with: channel)
    }
}

/// An emote a composer can offer: Twitch's id, which names its art, and the
/// word that summons it.
public struct ChatEmote: Sendable, Hashable, Identifiable, Decodable {
    public let id: String
    public let name: String
    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

extension Helix {
    /// The channel's own emotes, then Twitch's global set. Read once and hold.
    // ponytail: every emote the channel has, whether or not this viewer may
    // use one (a sub emote sent by a non-sub goes out as its name). The exact
    // usable set is GET chat/emotes/user, behind the user:read:emotes scope.
    public func emotes() async throws -> [ChatEmote] {
        struct Page: Decodable { var data: [ChatEmote] }
        let broadcaster = try await resolveBroadcaster()
        let channel = try await request("GET", "chat/emotes", query: ["broadcaster_id": broadcaster])
        let global = try await request("GET", "chat/emotes/global")
        return try Guessr.decoder.decode(Page.self, from: channel).data
            + Guessr.decoder.decode(Page.self, from: global).data
    }
}

/// The `@name` a composer is in the middle of typing — its last word, when
/// that starts with `@` — as the part after the `@`. Nil otherwise, and after a
/// trailing space, which ends the word.
public func mentionInProgress(_ text: String) -> String? {
    guard let word = text.split(separator: " ", omittingEmptySubsequences: false).last, word.hasPrefix("@")
    else { return nil }
    return String(word.dropFirst())
}

/// `text` with the word being typed swapped for `word`, and a space after it
/// so the next word starts fresh.
public func completingLastWord(_ text: String, with word: String) -> String {
    var words = text.split(separator: " ", omittingEmptySubsequences: false)
    if words.isEmpty { return word + " " }
    words[words.count - 1] = Substring(word)
    return words.joined(separator: " ") + " "
}

/// SHA-1 of `message`, as its 20 digest bytes. Hand-rolled because the
/// package carries no dependencies and CryptoKit is Apple-only; only
/// `usernameColorHex` needs it, and only for the last byte.
func sha1(_ message: [UInt8]) -> [UInt8] {
    var h: [UInt32] = [0x6745_2301, 0xefcd_ab89, 0x98ba_dcfe, 0x1032_5476, 0xc3d2_e1f0]
    var padded = message
    padded.append(0x80)
    while padded.count % 64 != 56 { padded.append(0) }
    padded.append(contentsOf: (0..<8).reversed().map { UInt8(truncatingIfNeeded: (UInt64(message.count) * 8) >> ($0 * 8)) })

    for chunk in stride(from: 0, to: padded.count, by: 64) {
        var w = [UInt32](repeating: 0, count: 80)
        for i in 0..<16 {
            w[i] = (0..<4).reduce(UInt32(0)) { $0 << 8 | UInt32(padded[chunk + i * 4 + $1]) }
        }
        for i in 16..<80 {
            w[i] = (w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]).rotated(1)
        }
        var (a, b, c, d, e) = (h[0], h[1], h[2], h[3], h[4])
        for i in 0..<80 {
            let (f, k): (UInt32, UInt32)
            switch i {
            case 0..<20: (f, k) = ((b & c) | (~b & d), 0x5a82_7999)
            case 20..<40: (f, k) = (b ^ c ^ d, 0x6ed9_eba1)
            case 40..<60: (f, k) = ((b & c) | (b & d) | (c & d), 0x8f1b_bcdc)
            default: (f, k) = (b ^ c ^ d, 0xca62_c1d6)
            }
            let temp = a.rotated(5) &+ f &+ e &+ k &+ w[i]
            (a, b, c, d, e) = (temp, a, b.rotated(30), c, d)
        }
        h = [h[0] &+ a, h[1] &+ b, h[2] &+ c, h[3] &+ d, h[4] &+ e]
    }
    return h.flatMap { word in (0..<4).reversed().map { UInt8(truncatingIfNeeded: word >> ($0 * 8)) } }
}

extension UInt32 {
    fileprivate func rotated(_ n: UInt32) -> UInt32 { self << n | self >> (32 - n) }
}

/// A chat line `threaded(reach:)` can order: the platform's id for the
/// message, which a reply names as its parent, and the parent it names. Either
/// may be absent; a line with no key can't be answered, one with no parent
/// answers nothing. Kept apart from `id` because a client may key its rows on
/// an id of its own.
public protocol Threadable: Identifiable {
    var messageKey: String? { get }
    var parentKey: String? { get }
}

extension ChatLine: Threadable {
    public var messageKey: String? { id }
    public var parentKey: String? { reply?.parentId }
}

/// A chat line where the log draws it: `nested` under the line it answers.
public struct ThreadedLine<Line: Threadable>: Identifiable {
    public var line: Line
    public var nested: Bool
    /// For a command folded by `threaded(reach:open:)`: the bot's answers to
    /// it, whether or not they are also drawn as lines of their own.
    public var answers: [Line] = []
    public var id: Line.ID { line.id }
}

extension ThreadedLine: Equatable where Line: Equatable {}
extension ThreadedLine: Sendable where Line: Sendable {}

extension Array where Element: Threadable {
    /// The log in reading order: a reply (a bot's answer to a command, a
    /// chatter's threaded reply) sits under the line it answers, after that
    /// line's earlier replies, rather than as a new line quoting it. Only
    /// when the parent is at most `reach` lines back, so a late reply is never
    /// drawn far up the log where nobody at the bottom would see it arrive.
    public func threaded(reach: Int = 20) -> [ThreadedLine<Element>] {
        var position: [String: Int] = [:]
        // Each line's thread, as the index of the line at its root.
        var root: [Int] = []
        var replies: [Int: [Element]] = [:]
        var roots: [Int] = []
        for (index, line) in enumerated() {
            if let parent = line.parentKey, let at = position[parent], index - at <= reach {
                root.append(root[at])
                replies[root[at], default: []].append(line)
            } else {
                root.append(index)
                roots.append(index)
            }
            if let key = line.messageKey { position[key] = index }
        }
        return roots.flatMap { at in
            [ThreadedLine(line: self[at], nested: false)]
                + (replies[at] ?? []).map { ThreadedLine(line: $0, nested: true) }
        }
    }
}

/// A chat line a command's answers can fold under: who sent it and what it
/// says, which is what tells a viewer's `!command` from the bot's answer.
public protocol ChatExchangeable: Threadable {
    var senderLogin: String { get }
    var body: String { get }
}

extension ChatLine: ChatExchangeable {
    public var senderLogin: String { login }
    public var body: String { text }
}

extension Array where Element: ChatExchangeable {
    /// `threaded(reach:)`, with each command and the bot's answers to it read as
    /// one exchange: a viewer's `!command` carries those answers in `answers`,
    /// and they leave the log unless the command's id is in `open`. Anyone
    /// else's reply to the command stays in its thread either way.
    public func threaded(reach: Int = 20, open: Set<Element.ID>) -> [ThreadedLine<Element>] {
        var out: [ThreadedLine<Element>] = []
        // Where in `out` the current thread's root is, when that root is a command.
        var command: Int?
        for row in threaded(reach: reach) {
            if !row.nested {
                command = isChatCommand(row.line.body) && !isChatBot(row.line.senderLogin) ? out.count : nil
            } else if let at = command, isChatBot(row.line.senderLogin) {
                out[at].answers.append(row.line)
                if !open.contains(out[at].id) { continue }
            }
            out.append(row)
        }
        return out
    }
}
