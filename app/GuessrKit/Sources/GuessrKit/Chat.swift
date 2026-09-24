import Foundation
import Observation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// A run of a chat message as Twitch parsed it. Mentions and cheermotes keep
/// only their text: the line reads right, it just isn't linked or animated.
// ponytail: mention and cheermote render as plain text; give them their own
// payload (user id, bits amount) when the UI draws them differently.
public enum ChatFragment: Sendable, Equatable {
    case text(String)
    case emote(id: String, text: String)
    case mention(String)
    case cheermote(String)

    /// What the fragment says, which is also an emote's name.
    public var text: String {
        switch self {
        case .text(let s), .emote(_, let s), .mention(let s), .cheermote(let s): s
        }
    }
}

/// One chat message, in Twitch's own shape.
public struct ChatLine: Sendable, Equatable, Identifiable {
    /// Twitch's `message_id` — what a delete names.
    public var id: String
    public var userId: String
    public var login: String
    public var displayName: String
    public var text: String
    /// The colour the chatter picked on Twitch, `#RRGGBB`, or empty for one
    /// who never picked.
    public var color: String
    /// Badge set id → version id, e.g. `subscriber` → `12`.
    public var badges: [String: String]
    public var fragments: [ChatFragment]
    public var timestamp: Date

    public init(
        id: String, userId: String, login: String, displayName: String, text: String, color: String = "",
        badges: [String: String] = [:], fragments: [ChatFragment]? = nil, timestamp: Date = .now
    ) {
        self.id = id
        self.userId = userId
        self.login = login
        self.displayName = displayName
        self.text = text
        self.color = color
        self.badges = badges
        self.fragments = fragments ?? [.text(text)]
        self.timestamp = timestamp
    }

    public var isBroadcaster: Bool { badges["broadcaster"] != nil }
    public var isModerator: Bool { badges["moderator"] != nil }
    public var isSubscriber: Bool { badges["subscriber"] != nil || badges["founder"] != nil }
}

public enum TwitchChatError: Error, LocalizedError, Equatable {
    case unknownChannel(String)
    case http(status: Int, message: String)
    /// Twitch accepted the request and declined to post the message.
    case dropped(String)

    public var errorDescription: String? {
        switch self {
        case .unknownChannel(let login): "Twitch has no channel called \(login)"
        case .http(let status, let message): "Twitch answered \(status): \(message)"
        case .dropped(let why): "Twitch didn't send the message: \(why)"
        }
    }
}

/// A live Twitch channel's chat, read over EventSub's WebSocket transport and
/// written and moderated through Helix, all on the viewer's own token.
///
/// EventSub's WebSocket transport only delivers chat to the token's own user,
/// so reading requires a login; there is no anonymous mode.
@Observable @MainActor
public final class TwitchChat {
    /// The newest lines, oldest first, at most `capacity` of them.
    public private(set) var lines: [ChatLine] = []
    /// Whether a socket is open and subscribed.
    public private(set) var isConnected = false
    /// The last thing that went wrong, shown until the next welcome clears it.
    public private(set) var lastError: String?

    /// The channel's login, as typed in a URL.
    public let channel: String
    /// The channel's numeric id, once it has been looked up.
    public private(set) var broadcasterID: String?

    /// The login everything is sent as. Settable, so the caller can swap in a
    /// refreshed token without dropping the ring.
    @ObservationIgnored public var session: TwitchSession
    @ObservationIgnored let clientID: String
    @ObservationIgnored let urlSession: URLSession
    @ObservationIgnored let helixBase: URL
    @ObservationIgnored let eventSubURL: URL
    // ponytail: 300 lines, a screenful many times over; raise it or page to
    // disk if scrollback ever matters.
    @ObservationIgnored let capacity: Int

    @ObservationIgnored private var runner: Task<Void, Never>?
    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    /// Seconds of silence after which the socket counts as dead: the welcome's
    /// `keepalive_timeout_seconds`, plus slack for the network.
    @ObservationIgnored private var keepalive = 10

    public init(
        channel: String,
        clientID: String,
        session: TwitchSession,
        urlSession: URLSession = .shared,
        helixBase: URL = URL(string: "https://api.twitch.tv/helix")!,
        eventSubURL: URL = URL(string: "wss://eventsub.wss.twitch.tv/ws")!,
        capacity: Int = 300
    ) {
        self.channel = channel.lowercased()
        self.clientID = clientID
        self.session = session
        self.urlSession = urlSession
        self.helixBase = helixBase
        self.eventSubURL = eventSubURL
        self.capacity = capacity
    }

    // MARK: Reading

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
        var url = eventSubURL
        var subscribe = true
        var retiring: URLSessionWebSocketTask?
        var attempt = 0
        while !Task.isCancelled {
            do {
                _ = try await resolveBroadcaster()
                let ws = urlSession.webSocketTask(with: url)
                socket = ws
                ws.resume()
                if let moved = try await read(ws, subscribe: subscribe, retiring: &retiring, attempt: &attempt) {
                    // Twitch moves the session, subscriptions and all; the old
                    // socket stays open until the new one's welcome.
                    retiring = ws
                    url = moved
                    subscribe = false
                    continue
                }
            } catch {
                if Task.isCancelled { break }
                lastError = error.localizedDescription
            }
            isConnected = false
            retiring?.cancel(with: .goingAway, reason: nil)
            retiring = nil
            url = eventSubURL
            subscribe = true
            // ponytail: plain doubling capped at a minute, no jitter; one
            // client per phone doesn't stampede anything.
            let delay = min(1 << min(attempt, 6), 60)
            attempt += 1
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    /// Reads `ws` until it dies (throws) or Twitch asks to move (returns the
    /// new URL).
    private func read(
        _ ws: URLSessionWebSocketTask, subscribe: Bool, retiring: inout URLSessionWebSocketTask?, attempt: inout Int
    ) async throws -> URL? {
        while true {
            let data: Data
            switch try await receive(ws) {
            case .data(let d): data = d
            case .string(let s): data = Data(s.utf8)
            @unknown default: continue
            }
            switch handle(data) {
            case .welcome(let sessionID, let timeout):
                keepalive = timeout + 5
                if subscribe { try await subscribeAll(sessionID) }
                retiring?.cancel(with: .normalClosure, reason: nil)
                retiring = nil
                isConnected = true
                lastError = nil
                attempt = 0
            case .reconnect(let url):
                return url
            case .revoked(let why):
                lastError = why
            case nil:
                break
            }
        }
    }

    /// One frame, or an error once `keepalive` seconds pass without one —
    /// Twitch promises a keepalive inside that window, so silence means the
    /// socket is gone even if the OS hasn't noticed.
    private func receive(_ ws: URLSessionWebSocketTask) async throws -> URLSessionWebSocketTask.Message {
        let watchdog = Task { [keepalive] in
            try await Task.sleep(for: .seconds(keepalive))
            ws.cancel(with: .goingAway, reason: nil)
        }
        defer { watchdog.cancel() }
        return try await ws.receive()
    }

    /// What a frame asks the connection to do, beyond changing the ring.
    enum Control: Equatable {
        case welcome(sessionID: String, keepalive: Int)
        case reconnect(URL)
        case revoked(String)
    }

    /// Applies one EventSub frame: a message joins the ring, a delete or a
    /// user clear takes lines out of it, and session frames come back as a
    /// `Control` for the socket loop. An undecodable frame is ignored.
    @discardableResult
    func handle(_ frame: Data) -> Control? {
        guard let frame = try? Guessr.decoder.decode(Frame.self, from: frame) else { return nil }
        let payload = frame.payload
        switch frame.metadata.messageType {
        case "session_welcome":
            guard let s = payload?.session else { return nil }
            return .welcome(sessionID: s.id, keepalive: s.keepaliveTimeoutSeconds ?? 10)
        case "session_reconnect":
            return payload?.session?.reconnectUrl.flatMap(URL.init(string:)).map(Control.reconnect)
        case "revocation":
            let sub = payload?.subscription
            return .revoked("Twitch stopped \(sub?.type ?? "a subscription"): \(sub?.status ?? "revoked")")
        case "notification":
            guard let event = payload?.event else { return nil }
            switch frame.metadata.subscriptionType {
            case "channel.chat.message":
                if let line = event.line(at: parseTimestamp(frame.metadata.messageTimestamp)) { append(line) }
            case "channel.chat.message_delete":
                lines.removeAll { $0.id == event.messageId }
            case "channel.chat.clear_user_messages":
                lines.removeAll { $0.userId == event.targetUserId }
            default:
                break
            }
            return nil
        default:
            return nil
        }
    }

    private func append(_ line: ChatLine) {
        // EventSub delivers at least once; a redelivered message is dropped.
        guard !lines.contains(where: { $0.id == line.id }) else { return }
        lines.append(line)
        if lines.count > capacity { lines.removeFirst(lines.count - capacity) }
    }

    private func subscribeAll(_ sessionID: String) async throws {
        let broadcaster = try await resolveBroadcaster()
        for type in ["channel.chat.message", "channel.chat.message_delete", "channel.chat.clear_user_messages"] {
            _ = try await helix(
                "POST", "eventsub/subscriptions",
                body: [
                    "type": type, "version": "1",
                    "condition": ["broadcaster_user_id": broadcaster, "user_id": session.userID],
                    "transport": ["method": "websocket", "session_id": sessionID],
                ])
        }
    }

    // MARK: Helix

    /// The channel's numeric id, looked up once.
    @discardableResult
    func resolveBroadcaster() async throws -> String {
        if let broadcasterID { return broadcasterID }
        struct Users: Decodable {
            struct User: Decodable { var id: String }
            var data: [User]
        }
        let body = try await helix("GET", "users", query: ["login": channel])
        guard let id = try Guessr.decoder.decode(Users.self, from: body).data.first?.id else {
            throw TwitchChatError.unknownChannel(channel)
        }
        broadcasterID = id
        return id
    }

    /// Posts `text` to the channel as the logged-in user.
    public func send(_ text: String) async throws {
        struct Reply: Decodable {
            struct Sent: Decodable {
                struct Drop: Decodable { var message: String }
                var isSent: Bool
                var dropReason: Drop?
            }
            var data: [Sent]
        }
        let broadcaster = try await resolveBroadcaster()
        let body = try await helix(
            "POST", "chat/messages",
            body: ["broadcaster_id": broadcaster, "sender_id": session.userID, "message": text])
        if let sent = try Guessr.decoder.decode(Reply.self, from: body).data.first, !sent.isSent {
            throw TwitchChatError.dropped(sent.dropReason?.message ?? "no reason given")
        }
    }

    /// Deletes one message. Needs `moderator:manage:chat_messages`.
    public func delete(messageId: String) async throws {
        let broadcaster = try await resolveBroadcaster()
        _ = try await helix(
            "DELETE", "moderation/chat",
            query: ["broadcaster_id": broadcaster, "moderator_id": session.userID, "message_id": messageId])
    }

    /// Times a user out for `seconds`, or bans them for good when `seconds`
    /// is 0. Needs `moderator:manage:banned_users`.
    public func ban(userId: String, seconds: Int) async throws {
        let broadcaster = try await resolveBroadcaster()
        var ban: [String: Any] = ["user_id": userId]
        if seconds > 0 { ban["duration"] = seconds }
        _ = try await helix(
            "POST", "moderation/bans",
            query: ["broadcaster_id": broadcaster, "moderator_id": session.userID],
            body: ["data": ban])
    }

    /// Whether the logged-in user moderates this channel. The owner does by
    /// definition; anyone else is looked up in the channels they moderate. A
    /// failed lookup reads as no.
    public func moderates() async -> Bool {
        guard let broadcaster = try? await resolveBroadcaster() else { return false }
        if session.userID == broadcaster { return true }
        struct Page: Decodable {
            struct Channel: Decodable { var broadcasterId: String }
            struct Cursor: Decodable { var cursor: String? }
            var data: [Channel]
            var pagination: Cursor?
        }
        var after: String?
        repeat {
            var query = ["user_id": session.userID, "first": "100"]
            query["after"] = after
            guard let body = try? await helix("GET", "moderation/channels", query: query),
                let page = try? Guessr.decoder.decode(Page.self, from: body)
            else { return false }
            if page.data.contains(where: { $0.broadcasterId == broadcaster }) { return true }
            after = page.pagination?.cursor.flatMap { $0.isEmpty ? nil : $0 }
        } while after != nil
        return false
    }

    /// One Helix call on the session's token. A non-2xx answer throws with
    /// Twitch's own message.
    func helix(_ method: String, _ path: String, query: [String: String] = [:], body: [String: Any]? = nil)
        async throws -> Data
    {
        var url = helixBase.appending(path: path)
        if !query.isEmpty {
            url.append(queryItems: query.keys.sorted().map { URLQueryItem(name: $0, value: query[$0]) })
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(clientID, forHTTPHeaderField: "Client-Id")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await urlSession.settledData(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            struct Envelope: Decodable { var message: String? }
            let message =
                (try? JSONDecoder().decode(Envelope.self, from: data))?.message
                ?? String(decoding: data, as: UTF8.self)
            throw TwitchChatError.http(status: status, message: message)
        }
        return data
    }
}

/// Twitch's `message_timestamp` carries nanoseconds, which the ISO 8601
/// parser won't take; milliseconds are plenty for a chat line.
func parseTimestamp(_ raw: String?) -> Date {
    guard var raw else { return .now }
    if let dot = raw.firstIndex(of: "."), let end = raw[dot...].firstIndex(where: { !$0.isNumber && $0 != "." }) {
        let digits = raw[raw.index(after: dot)..<end].prefix(3)
        raw = String(raw[..<dot]) + "." + digits.padding(toLength: 3, withPad: "0", startingAt: 0) + raw[end...]
    }
    let parser = ISO8601DateFormatter()
    parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = parser.date(from: raw) { return date }
    parser.formatOptions = [.withInternetDateTime]
    return parser.date(from: raw) ?? .now
}

/// An EventSub WebSocket frame, as far as chat reads it.
struct Frame: Decodable {
    struct Metadata: Decodable {
        var messageType: String
        var messageTimestamp: String?
        var subscriptionType: String?
    }
    struct Session: Decodable {
        var id: String
        var keepaliveTimeoutSeconds: Int?
        var reconnectUrl: String?
    }
    struct Subscription: Decodable {
        var type: String?
        var status: String?
    }
    struct Payload: Decodable {
        var session: Session?
        var subscription: Subscription?
        var event: Event?
    }
    struct Event: Decodable {
        struct Message: Decodable {
            struct Fragment: Decodable {
                struct Emote: Decodable { var id: String }
                var type: String
                var text: String
                var emote: Emote?
            }
            var text: String
            var fragments: [Fragment]?
        }
        struct Badge: Decodable {
            var setId: String
            var id: String
        }
        var messageId: String?
        var chatterUserId: String?
        var chatterUserLogin: String?
        var chatterUserName: String?
        var message: Message?
        var color: String?
        var badges: [Badge]?
        var targetUserId: String?

        func line(at timestamp: Date) -> ChatLine? {
            guard let messageId, let chatterUserId, let message else { return nil }
            let fragments: [ChatFragment]? = message.fragments.map {
                $0.map { f in
                    switch f.type {
                    case "emote": f.emote.map { .emote(id: $0.id, text: f.text) } ?? .text(f.text)
                    case "mention": .mention(f.text)
                    case "cheermote": .cheermote(f.text)
                    default: .text(f.text)
                    }
                }
            }
            return ChatLine(
                id: messageId,
                userId: chatterUserId,
                login: chatterUserLogin ?? "",
                displayName: chatterUserName ?? chatterUserLogin ?? "",
                text: message.text,
                color: color ?? "",
                badges: Dictionary((badges ?? []).map { ($0.setId, $0.id) }, uniquingKeysWith: { a, _ in a }),
                fragments: fragments,
                timestamp: timestamp
            )
        }
    }
    var metadata: Metadata
    var payload: Payload?
}
