import Foundation
import Observation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// A run of a chat message as Twitch parsed it. Mentions and cheermotes keep
/// only their text: the line reads right, it just isn't linked or animated.
// ponytail: mention and cheermote render as plain text; give them their own
// payload (user id, bits amount) when the UI draws them differently.
public enum ChatFragment: Sendable, Equatable, Codable {
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

/// The message a reply answers, as Twitch quotes it on the reply.
public struct ChatReply: Sendable, Equatable, Codable {
    public var parentId: String
    public var login: String
    public var displayName: String
    public var text: String

    public init(parentId: String, login: String, displayName: String, text: String) {
        (self.parentId, self.login, self.displayName, self.text) = (parentId, login, displayName, text)
    }
}

/// What the channel asks of anyone who talks: Twitch's slow, followers-only,
/// subscribers-only, emote-only and unique-message modes.
public struct ChatMode: Sendable, Equatable {
    /// Seconds a viewer waits between messages; 0 when slow mode is off.
    public var slowSeconds = 0
    /// How long a viewer must have followed, in minutes; nil when followers-only
    /// is off, 0 for any follower.
    public var followerMinutes: Int?
    public var subscribersOnly = false
    public var emoteOnly = false
    public var uniqueOnly = false

    public init(
        slowSeconds: Int = 0, followerMinutes: Int? = nil, subscribersOnly: Bool = false, emoteOnly: Bool = false,
        uniqueOnly: Bool = false
    ) {
        (self.slowSeconds, self.followerMinutes, self.subscribersOnly, self.emoteOnly, self.uniqueOnly) =
            (slowSeconds, followerMinutes, subscribersOnly, emoteOnly, uniqueOnly)
    }

    /// The modes in force, as the composer lists them; nil when chat is open.
    public var summary: String? {
        var parts: [String] = []
        if slowSeconds > 0 { parts.append("Slow mode, \(compactDuration(slowSeconds))") }
        if let m = followerMinutes {
            parts.append(m > 0 ? "Followers of \(compactDuration(m * 60)) only" : "Followers only")
        }
        if subscribersOnly { parts.append("Subscribers only") }
        if emoteOnly { parts.append("Emotes only") }
        if uniqueOnly { parts.append("Unique messages only") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The body that sets these modes on Helix (`PATCH chat/settings`). A
    /// length goes only with its mode switched on: Twitch refuses a wait time
    /// beside `slow_mode: false`.
    public var settings: [String: Any] {
        var body: [String: Any] = [
            "slow_mode": slowSeconds > 0, "follower_mode": followerMinutes != nil,
            "subscriber_mode": subscribersOnly, "emote_mode": emoteOnly, "unique_chat_mode": uniqueOnly,
        ]
        if slowSeconds > 0 { body["slow_mode_wait_time"] = slowSeconds }
        if let followerMinutes { body["follower_mode_duration"] = followerMinutes }
        return body
    }

    /// Whole seconds until a viewer whose last message went at `lastSent` may
    /// send again; 0 when they may now.
    public func wait(since lastSent: Date?, now: Date = .now) -> Int {
        guard slowSeconds > 0, let lastSent else { return 0 }
        return max(0, Int((Double(slowSeconds) - now.timeIntervalSince(lastSent)).rounded(.up)))
    }
}

/// `30s`, `10m`, `3d`: a mode's length in its coarsest whole unit.
func compactDuration(_ seconds: Int) -> String {
    switch seconds {
    case ..<60: "\(seconds)s"
    case ..<3600: "\(seconds / 60)m"
    case ..<86400: "\(seconds / 3600)h"
    default: "\(seconds / 86400)d"
    }
}

/// One chat message, in Twitch's own shape.
public struct ChatLine: Sendable, Equatable, Identifiable, Codable {
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
    /// For a sub, gift, raid or announcement: Twitch's `notice_type`, and
    /// the sentence it wrote about it. `text` is then whatever the chatter
    /// added, often nothing.
    public var kind: String?
    public var notice: String?
    /// Twitch's `message_type` for an ordinary message: `user_intro` for a
    /// chatter's first message in the channel, `channel_points_highlighted`
    /// for one paid for with channel points; nil or `text` otherwise.
    public var messageType: String?
    /// Whether a mod deleted it, or it went with a timeout or ban. The line
    /// stays in the ring so a mod can see what was removed; a viewer's log
    /// leaves it out.
    public var deleted = false
    /// What this line answers, for a reply.
    public var reply: ChatReply?

    public init(
        id: String, userId: String, login: String, displayName: String, text: String, color: String = "",
        badges: [String: String] = [:], fragments: [ChatFragment]? = nil, timestamp: Date = .now,
        kind: String? = nil, notice: String? = nil, messageType: String? = nil, reply: ChatReply? = nil
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
        self.kind = kind
        self.notice = notice
        self.messageType = messageType
        self.reply = reply
    }

    public var isBroadcaster: Bool { badges["broadcaster"] != nil }
    public var isModerator: Bool { badges["moderator"] != nil }
    public var isSubscriber: Bool { badges["subscriber"] != nil || badges["founder"] != nil }
}

/// A message AutoMod is holding for a mod's verdict, as `automod.message.hold`
/// describes it. It is not a `ChatLine`: nobody else has seen it.
public struct HeldMessage: Sendable, Equatable, Identifiable {
    /// Twitch's `message_id` — what the verdict names.
    public var id: String
    public var userId: String
    public var login: String
    public var displayName: String
    public var text: String
    public var fragments: [ChatFragment]
    /// Why it was held, as a mod reads it: `AutoMod: sexual 3` or `Blocked term`.
    public var why: String
    public var heldAt: Date

    public init(
        id: String, userId: String, login: String, displayName: String, text: String, fragments: [ChatFragment]? = nil,
        why: String, heldAt: Date = .now
    ) {
        self.id = id
        self.userId = userId
        self.login = login
        self.displayName = displayName
        self.text = text
        self.fragments = fragments ?? [.text(text)]
        self.why = why
        self.heldAt = heldAt
    }
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

/// A live Twitch channel's chat, read over EventSub's WebSocket transport on
/// the viewer's own token. Writing and moderating go through `helix`, which a
/// host with no socket can build on its own.
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
    /// The channel's chat modes: read on each connect, then kept by EventSub.
    public private(set) var mode = ChatMode()
    /// What AutoMod is holding, oldest first, for a login with the scope to
    /// rule on it. Empty until a hold arrives — Helix has no list to read —
    /// and a message leaves when any mod rules, or it expires.
    public private(set) var held: [HeldMessage] = []

    /// The Helix calls the socket subscribes through, and everything that
    /// writes to or moderates the channel.
    @ObservationIgnored public let helix: Helix
    /// The channel's login, as typed in a URL.
    public var channel: String { helix.channel }
    /// The login everything is sent as. Settable, so the caller can swap in a
    /// refreshed token without dropping the ring.
    public var session: TwitchSession {
        get { helix.session }
        set { helix.session = newValue }
    }
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
        self.helix = Helix(
            channel: channel, clientID: clientID, session: session, urlSession: urlSession, base: helixBase)
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

    /// Puts lines from before this session at the front: a log the host kept
    /// from last time, so the tab opens on something to read rather than a
    /// blank page. Only into an empty ring, and only the newest `capacity`;
    /// a live line that redelivers one of these is dropped like any other.
    public func seed(_ earlier: [ChatLine]) {
        guard lines.isEmpty, !earlier.isEmpty else { return }
        lines = Array(earlier.suffix(capacity))
    }

    private func run() async {
        var url = eventSubURL
        var subscribe = true
        var retiring: URLSessionWebSocketTask?
        var attempt = 0
        while !Task.isCancelled {
            do {
                _ = try await helix.resolveBroadcaster()
                let ws = helix.urlSession.webSocketTask(with: url)
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
                if subscribe {
                    try await subscribeAll(sessionID)
                    // After subscribing, so no change can slip between the
                    // read and the first update. A failed read keeps the last.
                    if let read = try? await helix.chatMode() { mode = read }
                }
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
    /// user clear marks lines `deleted`, and session frames come back as a
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
            case "channel.chat.message", "channel.chat.notification":
                if let line = event.line(at: parseTimestamp(frame.metadata.messageTimestamp)) { append(line) }
            case "channel.chat.message_delete":
                for i in lines.indices where lines[i].id == event.messageId { lines[i].deleted = true }
            case "channel.chat.clear_user_messages":
                for i in lines.indices where lines[i].userId == event.targetUserId { lines[i].deleted = true }
            case "automod.message.hold":
                if let message = event.held(at: parseTimestamp(frame.metadata.messageTimestamp)),
                    !held.contains(where: { $0.id == message.id })
                {
                    held.append(message)
                }
            case "automod.message.update":
                held.removeAll { $0.id == event.messageId }
            case "channel.chat_settings.update":
                mode = ChatMode(
                    slowSeconds: event.slowMode == true ? event.slowModeWaitTimeSeconds ?? 0 : 0,
                    followerMinutes: event.followerMode == true ? event.followerModeDurationMinutes ?? 0 : nil,
                    subscribersOnly: event.subscriberMode ?? false, emoteOnly: event.emoteMode ?? false,
                    uniqueOnly: event.uniqueChatMode ?? false)
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
        let broadcaster = try await helix.resolveBroadcaster()
        for type in [
            "channel.chat.message", "channel.chat.notification", "channel.chat.message_delete",
            "channel.chat.clear_user_messages", "channel.chat_settings.update",
        ] {
            try await subscribe(type, version: "1", condition: ["user_id": session.userID], to: sessionID)
        }
        // AutoMod's holds go only to a moderator, and only with the scope; a
        // refusal — a mod since demoted, say — must not cost them the chat.
        guard session.canModerate else { return }
        for type in ["automod.message.hold", "automod.message.update"] {
            try? await subscribe(type, version: "2", condition: ["moderator_user_id": session.userID], to: sessionID)
        }
    }

    private func subscribe(_ type: String, version: String, condition: [String: String], to sessionID: String)
        async throws
    {
        let broadcaster = try await helix.resolveBroadcaster()
        _ = try await helix.request(
            "POST", "eventsub/subscriptions",
            body: [
                "type": type, "version": version,
                "condition": condition.merging(["broadcaster_user_id": broadcaster]) { a, _ in a },
                "transport": ["method": "websocket", "session_id": sessionID],
            ])
    }
}

/// Twitch's Helix API for one channel, on the viewer's own token: the lookups,
/// writes and moderation that need no chat socket.
@MainActor
public final class Helix {
    /// The channel's login, lowercased.
    public let channel: String
    /// The login every call is made as. Settable, so a refreshed token swaps
    /// in without a new client.
    public var session: TwitchSession
    let clientID: String
    let urlSession: URLSession
    let base: URL
    /// The channel's numeric id, once it has been looked up.
    public private(set) var broadcasterID: String?
    /// Profiles already read, by user id: a card reopened costs no call.
    private var users: [String: TwitchUser] = [:]

    public init(
        channel: String,
        clientID: String,
        session: TwitchSession,
        urlSession: URLSession = .shared,
        base: URL = URL(string: "https://api.twitch.tv/helix")!
    ) {
        self.channel = channel.lowercased()
        self.clientID = clientID
        self.session = session
        self.urlSession = urlSession
        self.base = base
    }

    /// The channel's numeric id, looked up once.
    @discardableResult
    func resolveBroadcaster() async throws -> String {
        if let broadcasterID { return broadcasterID }
        struct Users: Decodable {
            struct User: Decodable { var id: String }
            var data: [User]
        }
        let body = try await request("GET", "users", query: ["login": channel])
        guard let id = try Guessr.decoder.decode(Users.self, from: body).data.first?.id else {
            throw TwitchChatError.unknownChannel(channel)
        }
        broadcasterID = id
        return id
    }

    /// A chatter's public profile, for their user card: read once per user
    /// id, nil for an id Twitch no longer knows. Needs no scope.
    public func user(id: String) async throws -> TwitchUser? {
        if let known = users[id] { return known }
        struct Page: Decodable { var data: [TwitchUser] }
        let body = try await request("GET", "users", query: ["id": id])
        let user = try TwitchUser.decoder.decode(Page.self, from: body).data.first
        users[id] = user
        return user
    }

    /// Posts `text` to the channel as the logged-in user, threaded under the
    /// message `replyTo` names when there is one.
    public func send(_ text: String, replyTo: String? = nil) async throws {
        struct Reply: Decodable {
            struct Sent: Decodable {
                struct Drop: Decodable { var message: String }
                var isSent: Bool
                var dropReason: Drop?
            }
            var data: [Sent]
        }
        let broadcaster = try await resolveBroadcaster()
        var message = ["broadcaster_id": broadcaster, "sender_id": session.userID, "message": text]
        message["reply_parent_message_id"] = replyTo
        let body = try await request("POST", "chat/messages", body: message)
        if let sent = try Guessr.decoder.decode(Reply.self, from: body).data.first, !sent.isSent {
            throw TwitchChatError.dropped(sent.dropReason?.message ?? "no reason given")
        }
    }

    /// Deletes one message. Needs `moderator:manage:chat_messages`.
    public func delete(messageId: String) async throws {
        let broadcaster = try await resolveBroadcaster()
        _ = try await request(
            "DELETE", "moderation/chat",
            query: ["broadcaster_id": broadcaster, "moderator_id": session.userID, "message_id": messageId])
    }

    /// Times a user out for `seconds`, or bans them for good when `seconds`
    /// is 0. Needs `moderator:manage:banned_users`.
    public func ban(userId: String, seconds: Int) async throws {
        let broadcaster = try await resolveBroadcaster()
        var ban: [String: Any] = ["user_id": userId]
        if seconds > 0 { ban["duration"] = seconds }
        _ = try await request(
            "POST", "moderation/bans",
            query: ["broadcaster_id": broadcaster, "moderator_id": session.userID],
            body: ["data": ban])
    }

    /// Lifts a user's timeout or ban. Needs `moderator:manage:banned_users`.
    public func unban(userId: String) async throws {
        let broadcaster = try await resolveBroadcaster()
        _ = try await request(
            "DELETE", "moderation/bans",
            query: ["broadcaster_id": broadcaster, "moderator_id": session.userID, "user_id": userId])
    }

    /// Lets a held message through, or drops it. Needs `moderator:manage:automod`.
    public func rule(messageId: String, allow: Bool) async throws {
        _ = try await request(
            "POST", "moderation/automod/message",
            body: ["user_id": session.userID, "msg_id": messageId, "action": allow ? "ALLOW" : "DENY"])
    }

    /// Warns a user, who can't chat again until they acknowledge it. Twitch
    /// wants a reason. Needs `moderator:manage:warnings`.
    public func warn(userId: String, reason: String) async throws {
        let broadcaster = try await resolveBroadcaster()
        _ = try await request(
            "POST", "moderation/warnings",
            query: ["broadcaster_id": broadcaster, "moderator_id": session.userID],
            body: ["data": ["user_id": userId, "reason": reason]])
    }

    /// Sets the channel's chat modes; the change comes back over EventSub.
    /// Needs `moderator:manage:chat_settings`.
    public func update(mode: ChatMode) async throws {
        let broadcaster = try await resolveBroadcaster()
        _ = try await request(
            "PATCH", "chat/settings",
            query: ["broadcaster_id": broadcaster, "moderator_id": session.userID], body: mode.settings)
    }

    /// The channel's chat modes as they stand. Needs no scope.
    public func chatMode() async throws -> ChatMode {
        struct Page: Decodable {
            struct Settings: Decodable {
                var emoteMode: Bool
                var followerMode: Bool
                var followerModeDuration: Int?
                var slowMode: Bool
                var slowModeWaitTime: Int?
                var subscriberMode: Bool
                var uniqueChatMode: Bool
            }
            var data: [Settings]
        }
        let broadcaster = try await resolveBroadcaster()
        let body = try await request("GET", "chat/settings", query: ["broadcaster_id": broadcaster])
        guard let s = try Guessr.decoder.decode(Page.self, from: body).data.first else { return ChatMode() }
        return ChatMode(
            slowSeconds: s.slowMode ? s.slowModeWaitTime ?? 0 : 0,
            followerMinutes: s.followerMode ? s.followerModeDuration ?? 0 : nil,
            subscribersOnly: s.subscriberMode, emoteOnly: s.emoteMode, uniqueOnly: s.uniqueChatMode)
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
            guard let body = try? await request("GET", "moderation/channels", query: query),
                let page = try? Guessr.decoder.decode(Page.self, from: body)
            else { return false }
            if page.data.contains(where: { $0.broadcasterId == broadcaster }) { return true }
            after = page.pagination?.cursor.flatMap { $0.isEmpty ? nil : $0 }
        } while after != nil
        return false
    }

    /// One Helix call on the session's token. A non-2xx answer throws with
    /// Twitch's own message.
    func request(_ method: String, _ path: String, query: [String: String] = [:], body: [String: Any]? = nil)
        async throws -> Data
    {
        var url = base.appending(path: path)
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

/// Who a chatter is, as Helix `users` answers: what a user card shows.
public struct TwitchUser: Decodable, Sendable, Equatable {
    public var id: String
    public var login: String
    public var displayName: String
    /// Twitch's avatar art; every account has one, a default if never set.
    public var profileImageUrl: String
    /// When the account was made.
    public var createdAt: Date

    public init(id: String, login: String, displayName: String, profileImageUrl: String, createdAt: Date) {
        self.id = id
        self.login = login
        self.displayName = displayName
        self.profileImageUrl = profileImageUrl
        self.createdAt = createdAt
    }

    public var profileImage: URL? { URL(string: profileImageUrl) }

    /// Helix writes `created_at` in whole seconds, which `.iso8601` reads.
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .iso8601
        return d
    }()
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
        struct Reply: Decodable {
            var parentMessageId: String
            var parentMessageBody: String?
            var parentUserLogin: String?
            var parentUserName: String?
        }
        var messageId: String?
        var chatterUserId: String?
        var chatterUserLogin: String?
        var chatterUserName: String?
        var message: Message?
        var color: String?
        var badges: [Badge]?
        var targetUserId: String?
        var noticeType: String?
        var systemMessage: String?
        var messageType: String?
        var reply: Reply?
        // automod.message.hold
        struct AutoMod: Decodable {
            var category: String
            var level: Int
        }
        struct BlockedTerm: Decodable {
            struct Term: Decodable { var termId: String? }
            var termsFound: [Term]?
        }
        var userId: String?
        var userLogin: String?
        var userName: String?
        var reason: String?
        var automod: AutoMod?
        var blockedTerm: BlockedTerm?
        var heldAt: String?
        // channel.chat_settings.update
        var emoteMode: Bool?
        var followerMode: Bool?
        var followerModeDurationMinutes: Int?
        var slowMode: Bool?
        var slowModeWaitTimeSeconds: Int?
        var subscriberMode: Bool?
        var uniqueChatMode: Bool?

        /// Twitch's runs as chat fragments; nil when it sent none.
        var fragments: [ChatFragment]? {
            message?.fragments.map {
                $0.map { f in
                    switch f.type {
                    case "emote": f.emote.map { .emote(id: $0.id, text: f.text) } ?? .text(f.text)
                    case "mention": .mention(f.text)
                    case "cheermote": .cheermote(f.text)
                    default: .text(f.text)
                    }
                }
            }
        }

        func held(at timestamp: Date) -> HeldMessage? {
            guard let messageId, let userId, let message else { return nil }
            let why =
                if let automod { "AutoMod: \(automod.category) \(automod.level)" } else if reason == "blocked_term" {
                    "Blocked term"
                } else { reason ?? "AutoMod" }
            return HeldMessage(
                id: messageId, userId: userId, login: userLogin ?? "", displayName: userName ?? userLogin ?? "",
                text: message.text, fragments: fragments, why: why,
                heldAt: heldAt == nil ? timestamp : parseTimestamp(heldAt))
        }

        func line(at timestamp: Date) -> ChatLine? {
            guard let messageId, let chatterUserId, let message else { return nil }
            return ChatLine(
                id: messageId,
                userId: chatterUserId,
                login: chatterUserLogin ?? "",
                displayName: chatterUserName ?? chatterUserLogin ?? "",
                text: message.text,
                color: color ?? "",
                badges: Dictionary((badges ?? []).map { ($0.setId, $0.id) }, uniquingKeysWith: { a, _ in a }),
                fragments: fragments,
                timestamp: timestamp,
                kind: noticeType,
                notice: systemMessage,
                messageType: messageType,
                reply: reply.map {
                    ChatReply(
                        parentId: $0.parentMessageId, login: $0.parentUserLogin ?? "",
                        displayName: $0.parentUserName ?? $0.parentUserLogin ?? "", text: $0.parentMessageBody ?? "")
                }
            )
        }
    }
    var metadata: Metadata
    var payload: Payload?
}
