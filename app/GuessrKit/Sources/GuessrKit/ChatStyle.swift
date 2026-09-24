import Foundation

// How a chat line is drawn: the web console's username palette and hash, its
// badge labels, and Twitch's badge art. A viewer with no Twitch colour is the
// same colour here as in the browser.

/// Username palette: a login is hashed, stably, to one of these.
private let palette = [
    "#b694ff", "#9b7bff", "#7fd1ff", "#5ad1c4", "#f2a3ff", "#7fb0ff", "#8ad4ff", "#9ee493",
]

/// The channel owner gets one distinct, never-hashed colour — a warm gold,
/// legible on both themes.
private let broadcasterColor = "#ffc857"

/// Known bot accounts render muted instead of coloured.
// ponytail: a fixed list; a channel bot outside it gets a colour. Learn the
// channel's bot logins from the server if that starts to matter.
private let builtinBots: Set<String> = [
    "nightbot", "streamelements", "streamlabs", "moobot", "fossabot", "wizebot", "sery_bot",
    "commanderroot", "soundalerts", "tripbot",
]

/// Stable colour for a username as `#rrggbb`, or nil for a bot, which reads
/// muted. The broadcaster takes the gold; everyone else takes a palette slot
/// keyed by a SHA-1 of the lowercased login — the web console's derivation.
public func usernameColorHex(_ username: String, isBroadcaster: Bool = false) -> String? {
    let login = username.lowercased()
    if isBroadcaster { return broadcasterColor }
    if builtinBots.contains(login) { return nil }
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
        if builtinBots.contains(login.lowercased()) { return nil }
        if !color.isEmpty { return color }
        return usernameColorHex(login, isBroadcaster: isBroadcaster)
    }

    /// The sender's badges as chips — `mod`, `sub 12`, `founder` — sorted by
    /// set id, with the version kept so the art table can be keyed by it.
    /// Only the subscriber version is worth showing: it counts months.
    public var badgeTags: [BadgeTag] {
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
}

/// One of a sender's badges: the set and version Twitch sent, and the chip a
/// client draws when it has no art for them.
public struct BadgeTag: Sendable, Hashable, Identifiable {
    public let name: String
    public let version: String
    public let label: String
    public var id: String { "\(name)/\(version)" }
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

extension TwitchChat {
    /// Twitch's badge art: the global sets with the channel's own on top,
    /// since a channel's subscriber badges replace the stock ones. Read once
    /// and hold.
    public func badgeArt() async throws -> BadgeSets {
        let broadcaster = try await resolveBroadcaster()
        let global = try BadgeSets.helix(try await helix("GET", "chat/global_badges"))
        let channel = try BadgeSets.helix(try await helix("GET", "chat/badges", query: ["broadcaster_id": broadcaster]))
        return global.overlaid(with: channel)
    }
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
