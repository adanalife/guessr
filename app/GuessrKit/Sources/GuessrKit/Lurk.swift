import Foundation
import Observation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// A Twitch channel's chat read with no login, over Twitch's IRC WebSocket as
/// one of the anonymous `justinfan` users it lets in to read. Nothing can be
/// sent this way: a viewer who wants to talk signs in and gets a `TwitchChat`.
@Observable @MainActor
public final class TwitchLurk {
    /// The newest lines, oldest first, at most `capacity` of them.
    public private(set) var lines: [ChatLine] = []
    /// Whether the socket is open and in the channel.
    public private(set) var isConnected = false
    public let channel: String

    @ObservationIgnored let url: URL
    @ObservationIgnored let capacity: Int
    @ObservationIgnored private var runner: Task<Void, Never>?
    @ObservationIgnored private var socket: (any ChatSocket)?
    @ObservationIgnored var makeSocket: (URL) -> any ChatSocket
    /// Twitch PINGs about every five minutes; twice that without a frame is a
    /// dead socket the OS hasn't noticed.
    @ObservationIgnored var silence: Duration = .seconds(600)

    public init(
        channel: String,
        urlSession: URLSession = .shared,
        url: URL = URL(string: "wss://irc-ws.chat.twitch.tv:443")!,
        capacity: Int = 300
    ) {
        self.channel = channel
        self.url = url
        self.capacity = capacity
        self.makeSocket = { urlSession.webSocketTask(with: $0) }
    }

    /// Connects and keeps connecting until `stop()`.
    public func start() {
        guard runner == nil else { return }
        runner = Task { await run() }
    }

    public func stop() {
        runner?.cancel()
        runner = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        isConnected = false
    }

    private func run() async {
        var attempt = 0
        while !Task.isCancelled {
            let ws = makeSocket(url)
            socket = ws
            ws.resume()
            do {
                // Any `justinfan` name reads; the number only keeps two apart.
                for command in [
                    "CAP REQ :twitch.tv/tags twitch.tv/commands", "NICK justinfan\(Int.random(in: 10000...99999))",
                    "JOIN #\(channel.lowercased())",
                ] {
                    try await ws.send(.string(command))
                }
                try await read(ws, attempt: &attempt)
            } catch {}
            isConnected = false
            ws.cancel(with: .goingAway, reason: nil)
            socket = nil
            if Task.isCancelled { break }
            let delay = TwitchChat.backoff(attempt)
            attempt += 1
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    /// Reads `ws` until it dies (throws) or Twitch asks for a reconnect.
    private func read(_ ws: any ChatSocket, attempt: inout Int) async throws {
        while true {
            let watchdog = Task { [silence] in
                try await Task.sleep(for: silence)
                ws.cancel(with: .goingAway, reason: nil)
            }
            let message = try await ws.receive()
            watchdog.cancel()
            let text: String
            switch message {
            case .string(let s): text = s
            case .data(let d): text = String(decoding: d, as: UTF8.self)
            @unknown default: continue
            }
            // One frame can carry several lines; "\r\n" is a single Character.
            for raw in text.split(separator: "\r\n") {
                switch handle(String(raw)) {
                case .pong(let token): try await ws.send(.string("PONG :\(token)"))
                case .joined:
                    isConnected = true
                    attempt = 0
                case .reconnect: return
                case nil: break
                }
            }
        }
    }

    /// What a line asks the connection to do, beyond changing the log.
    enum Control: Equatable {
        case pong(String)
        case joined
        case reconnect
    }

    /// Applies one IRC line: a message or notice joins the ring, a delete or a
    /// timeout marks lines `deleted`, and connection lines come back as a
    /// `Control`. Anything else is ignored.
    @discardableResult
    func handle(_ raw: String) -> Control? {
        guard let message = IRCMessage(raw) else { return nil }
        switch message.command {
        case "PING": return .pong(message.trailing ?? "tmi.twitch.tv")
        case "ROOMSTATE": return .joined
        case "RECONNECT": return .reconnect
        case "PRIVMSG", "USERNOTICE":
            if let line = message.line, !lines.contains(where: { $0.id == line.id }) {
                lines.append(line)
                if lines.count > capacity { lines.removeFirst(lines.count - capacity) }
            }
        case "CLEARMSG":
            for i in lines.indices where lines[i].id == message.tags["target-msg-id"] { lines[i].deleted = true }
        case "CLEARCHAT":
            // A user's timeout or ban names them; a whole-chat clear names nobody.
            let target = message.tags["target-user-id"]
            for i in lines.indices where target == nil || lines[i].userId == target { lines[i].deleted = true }
        default: break
        }
        return nil
    }
}

/// One line of Twitch's IRC: `@tags :prefix COMMAND params :trailing`.
struct IRCMessage {
    var tags: [String: String] = [:]
    /// The sender's login, from a `nick!user@host` prefix.
    var login: String?
    var command: String
    var trailing: String?

    init?(_ raw: String) {
        var rest = Substring(raw)
        if rest.hasPrefix("@") {
            guard let space = rest.firstIndex(of: " ") else { return nil }
            for pair in rest[rest.index(after: rest.startIndex)..<space].split(separator: ";") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                tags[String(kv[0])] = kv.count > 1 ? Self.unescape(kv[1]) : ""
            }
            rest = rest[rest.index(after: space)...]
        }
        if rest.hasPrefix(":") {
            guard let space = rest.firstIndex(of: " ") else { return nil }
            let prefix = rest[rest.index(after: rest.startIndex)..<space]
            if prefix.contains("!") { login = prefix.split(separator: "!").first.map(String.init) }
            rest = rest[rest.index(after: space)...]
        }
        if let colon = rest.range(of: " :") {
            trailing = String(rest[colon.upperBound...])
            rest = rest[..<colon.lowerBound]
        }
        guard let command = rest.split(separator: " ").first else { return nil }
        self.command = String(command)
    }

    /// IRCv3 tag values escape `;`, space, `\`, CR and LF.
    static func unescape(_ value: Substring) -> String {
        let escapes: [Character: Character] = ["s": " ", ":": ";", "\\": "\\", "r": "\r", "n": "\n"]
        var out = ""
        var escaping = false
        for c in value {
            if escaping {
                out.append(escapes[c] ?? c)
                escaping = false
            } else if c == "\\" {
                escaping = true
            } else {
                out.append(c)
            }
        }
        return out
    }

    /// IRC's names for a notice, as EventSub's `notice_type` spells them,
    /// which is what the log keys its glyphs on. The rest pass through.
    static let kinds = [
        "subgift": "sub_gift", "submysterygift": "community_sub_gift", "giftpaidupgrade": "gift_paid_upgrade",
        "primepaidupgrade": "prime_paid_upgrade", "payforward": "pay_it_forward",
    ]

    /// A PRIVMSG or USERNOTICE as a chat line; nil without the ids every line needs.
    var line: ChatLine? {
        guard let id = tags["id"], let userId = tags["user-id"] else { return nil }
        var text = trailing ?? ""
        // `/me`, which IRC wraps as a CTCP ACTION.
        if text.hasPrefix("\u{1}ACTION "), text.hasSuffix("\u{1}") { text = String(text.dropFirst(8).dropLast()) }
        let login = tags["login"] ?? self.login ?? ""
        let notice = command == "USERNOTICE"
        let msgID = tags["msg-id"]
        let badges = (tags["badges"] ?? "").split(separator: ",").compactMap { badge -> (String, String)? in
            let parts = badge.split(separator: "/", maxSplits: 1)
            return parts.count == 2 ? (String(parts[0]), String(parts[1])) : nil
        }
        return ChatLine(
            id: id, userId: userId, login: login,
            displayName: tags["display-name"].flatMap { $0.isEmpty ? nil : $0 } ?? login,
            text: text, color: tags["color"] ?? "",
            badges: Dictionary(badges, uniquingKeysWith: { a, _ in a }),
            fragments: Self.fragments(text, emotes: tags["emotes"] ?? ""),
            timestamp: tags["tmi-sent-ts"].flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) } ?? .now,
            kind: notice ? msgID.map { Self.kinds[$0] ?? $0 } : nil,
            notice: notice ? tags["system-msg"] : nil,
            messageType: notice
                ? nil
                : msgID == "highlighted-message" ? "channel_points_highlighted"
                : tags["first-msg"] == "1" ? "user_intro" : nil,
            reply: tags["reply-parent-msg-id"].map {
                ChatReply(
                    parentId: $0, login: tags["reply-parent-user-login"] ?? "",
                    displayName: tags["reply-parent-display-name"] ?? "", text: tags["reply-parent-msg-body"] ?? "")
            })
    }

    /// Twitch's `emotes` tag — `25:0-4,12-16/1902:6-10`, inclusive ranges
    /// counted in code points — as runs of `text`.
    static func fragments(_ text: String, emotes: String) -> [ChatFragment] {
        var spans: [(start: Int, end: Int, id: String)] = []
        for emote in emotes.split(separator: "/") {
            let parts = emote.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            for range in parts[1].split(separator: ",") {
                let ends = range.split(separator: "-").compactMap { Int($0) }
                if ends.count == 2 { spans.append((ends[0], ends[1], String(parts[0]))) }
            }
        }
        let scalars = Array(text.unicodeScalars)
        func slice(_ from: Int, _ to: Int) -> String { String(String.UnicodeScalarView(scalars[from..<to])) }
        var out: [ChatFragment] = []
        var at = 0
        for span in spans.sorted(by: { $0.start < $1.start })
        where span.start >= at && span.start <= span.end && span.end < scalars.count {
            if span.start > at { out.append(.text(slice(at, span.start))) }
            out.append(.emote(id: span.id, text: slice(span.start, span.end + 1)))
            at = span.end + 1
        }
        if at < scalars.count || out.isEmpty { out.append(.text(slice(at, scalars.count))) }
        return out
    }
}
