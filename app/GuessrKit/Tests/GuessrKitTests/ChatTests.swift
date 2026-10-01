import Foundation
import Testing

@testable import GuessrKit

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

/// A `channel.chat.message` frame from `user`, saying `text`.
private func message(_ id: String, from user: String, _ text: String = "hi") -> Data {
    Data(
        #"""
        {"metadata":{"message_type":"notification","message_timestamp":"2026-09-23T14:56:51Z","subscription_type":"channel.chat.message"},
         "payload":{"event":{"chatter_user_id":"\#(user)","chatter_user_login":"u\#(user)","chatter_user_name":"U\#(user)",
         "message_id":"\#(id)","message":{"text":"\#(text)","fragments":[{"type":"text","text":"\#(text)"}]},"color":"","badges":[]}}}
        """#.utf8)
}

private func event(_ type: String, _ fields: String) -> Data {
    Data(
        #"{"metadata":{"message_type":"notification","subscription_type":"\#(type)"},"payload":{"event":{\#(fields)}}}"#
            .utf8)
}

/// Stands in for api.twitch.tv/helix. Stateless: each answer depends only on
/// the request, so parallel tests can share it.
final class StubHelix: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        let query = Dictionary(
            (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { a, _ in a })
        let reply: String
        switch url.path {
        case "/helix/users" where query["id"] == "11":
            reply =
                #"{"data":[{"id":"11","login":"roadwatcher","display_name":"RoadWatcher","type":"","broadcaster_type":"","description":"","profile_image_url":"https://static-cdn.jtvnw.net/u/11-300x300.png","offline_image_url":"","view_count":0,"created_at":"2016-12-14T20:32:28Z"}]}"#
        case "/helix/users" where query["id"] != nil:
            reply = #"{"data":[]}"#
        case "/helix/users":
            reply = #"{"data":[{"id":"1971641","login":"\#(query["login"] ?? "")"}]}"#
        case "/helix/moderation/channels" where query["after"] == nil:
            reply = #"{"data":[{"broadcaster_id":"111"},{"broadcaster_id":"222"}],"pagination":{"cursor":"page2"}}"#
        case "/helix/moderation/channels" where query["after"] == "page2":
            reply = #"{"data":[{"broadcaster_id":"1971641"}],"pagination":{}}"#
        case "/helix/chat/global_badges":
            reply =
                #"{"data":[{"set_id":"moderator","versions":[{"id":"1","image_url_1x":"https://g/mod1","image_url_2x":"https://g/mod2","image_url_4x":"https://g/mod4"}]},{"set_id":"subscriber","versions":[{"id":"12","image_url_1x":"https://g/sub1","image_url_2x":"https://g/sub2","image_url_4x":"https://g/sub4"}]}]}"#
        case "/helix/chat/badges":
            reply =
                #"{"data":[{"set_id":"subscriber","versions":[{"id":"12","image_url_1x":"https://c/sub1","image_url_2x":"https://c/sub2","image_url_4x":"https://c/sub4"}]}]}"#
        case "/helix/chat/emotes":
            reply = #"{"data":[{"id":"emotesv2_1","name":"danaVan","images":{"url_1x":"https://c/e1"},"tier":"1000","emote_type":"subscriptions"}],"template":"https://static-cdn.jtvnw.net/emoticons/v2/{{id}}/{{format}}/{{theme_mode}}/{{scale}}"}"#
        case "/helix/chat/emotes/global":
            reply = #"{"data":[{"id":"25","name":"Kappa","images":{"url_1x":"https://g/e25"},"emote_type":"globals"}]}"#
        case "/helix/chat/settings":
            reply =
                #"{"data":[{"broadcaster_id":"1971641","emote_mode":false,"follower_mode":true,"follower_mode_duration":10,"slow_mode":true,"slow_mode_wait_time":30,"subscriber_mode":false,"unique_chat_mode":false}]}"#
        case "/helix/chat/messages":
            reply = #"{"data":[{"message_id":"","is_sent":false,"drop_reason":{"code":"msg_duplicate","message":"duplicate message"}}]}"#
        default:
            reply = "{}"
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor
private func chat(userID: String = "2914196", capacity: Int = 300) -> TwitchChat {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubHelix.self]
    return TwitchChat(
        channel: "adanalife_", clientID: "app1",
        session: TwitchSession(accessToken: "a", refreshToken: "r", expiresAt: .now, login: "kate", userID: userID),
        urlSession: URLSession(configuration: config),
        helixBase: URL(string: "https://twitch.test/helix")!,
        capacity: capacity)
}

@MainActor @Test func aChatMessageFrameDecodesIntoALine() throws {
    let chat = chat()
    chat.handle(try fixture("chat-message"))
    let line = try #require(chat.lines.first)
    #expect(line.id == "cc106a89-1814-919d-454c-f4f2f970aae7")
    #expect(line.userId == "4145994")
    #expect(line.login == "kate")
    #expect(line.displayName == "Kate")
    #expect(line.color == "#00FF7F")
    #expect(line.badges == ["moderator": "1", "subscriber": "12"])
    #expect(line.isModerator && line.isSubscriber && !line.isBroadcaster)
    #expect(line.fragments == [.text("hello van "), .emote(id: "25", text: "Kappa"), .text(" where are we")])
    #expect(line.fragments.map(\.text).joined() == line.text)
    #expect(line.timestamp == Date(timeIntervalSince1970: 1_790_175_411.634))
    #expect(line.messageType == "text" && !line.isFirstMessage && !line.isPointsHighlight)
}

@Test func aLineMentionsALoginAsAWholeWordFromSomeoneElse() {
    func line(_ text: String, from login: String = "roadwatcher") -> ChatLine {
        ChatLine(id: "1", userId: "1", login: login, displayName: login, text: text)
    }
    #expect(line("hey @Kate where are we").mentions("kate"))
    #expect(line("kate: morning").mentions("kate"))
    #expect(!line("katerina says hi").mentions("kate"))
    #expect(!line("hi @kate", from: "kate").mentions("kate"))
    #expect(!line("hi").mentions(""))
    #expect(ChatLine(id: "1", userId: "1", login: "a", displayName: "a", text: "hi", messageType: "user_intro").isFirstMessage)
}

@MainActor @Test func aNotificationFrameIsALineWithAKind() throws {
    let chat = chat()
    chat.handle(try fixture("chat-notification"))
    let line = try #require(chat.lines.first)
    #expect(line.kind == "resub")
    #expect(line.notice == "Kate subscribed at Tier 1. They've subscribed for 12 months!")
    #expect(line.text == "a year of van")
    #expect(line.badges == ["subscriber": "12"])
    // A raid says nothing of its own: the line is the notice alone.
    chat.handle(
        event(
            "channel.chat.notification",
            #""message_id":"r1","chatter_user_id":"77","chatter_user_login":"roadwatcher","notice_type":"raid","system_message":"5 raiders from roadwatcher have joined!","message":{"text":"","fragments":[]}"#
        ))
    let raid = try #require(chat.lines.last)
    #expect(raid.kind == "raid" && raid.text.isEmpty && raid.fragments.isEmpty)
    #expect(chat.lines.first?.kind == "resub")
}

@MainActor @Test func aReplyCarriesTheMessageItAnswers() throws {
    let chat = chat()
    chat.handle(
        event(
            "channel.chat.message",
            #""message_id":"r2","chatter_user_id":"4","chatter_user_login":"kate","message":{"text":"@RoadWatcher Utah"},"reply":{"parent_message_id":"r1","parent_message_body":"where is this?","parent_user_id":"11","parent_user_login":"roadwatcher","parent_user_name":"RoadWatcher","thread_message_id":"r1"}"#
        ))
    chat.handle(message("m1", from: "1"))
    let reply = try #require(chat.lines.first?.reply)
    #expect(reply == ChatReply(parentId: "r1", login: "roadwatcher", displayName: "RoadWatcher", text: "where is this?"))
    #expect(chat.lines.last?.reply == nil)
}

@MainActor @Test func deleteAndClearMarkLinesDeleted() {
    let chat = chat()
    for (id, user) in [("m1", "1"), ("m2", "2"), ("m3", "1"), ("m4", "3")] { chat.handle(message(id, from: user)) }
    chat.handle(event("channel.chat.message_delete", #""target_user_id":"3","message_id":"m4""#))
    #expect(chat.lines.filter(\.deleted).map(\.id) == ["m4"])
    chat.handle(event("channel.chat.clear_user_messages", #""target_user_id":"1""#))
    #expect(chat.lines.filter(\.deleted).map(\.id) == ["m1", "m3", "m4"])
    #expect(chat.lines.count == 4)
}

@MainActor @Test func theRingIsBoundedAndDropsRedeliveries() {
    let chat = chat(capacity: 3)
    for i in 1...5 { chat.handle(message("m\(i)", from: "1")) }
    chat.handle(message("m5", from: "1"))
    #expect(chat.lines.map(\.id) == ["m3", "m4", "m5"])
}

@MainActor @Test func aSeededRingReadsFromLastTimeUntilItRollsOver() throws {
    func line(_ id: String) -> ChatLine {
        ChatLine(
            id: id, userId: "1", login: "u1", displayName: "U1", text: "Kappa @u2",
            fragments: [.emote(id: "25", text: "Kappa"), .text(" "), .mention("@u2")],
            timestamp: Date(timeIntervalSince1970: 1_790_000_000),
            reply: ChatReply(parentId: "p", login: "u2", displayName: "U2", text: "yo"))
    }
    // The round trip a host's defaults put the lines through, fragments and reply included.
    let kept = try JSONDecoder().decode([ChatLine].self, from: JSONEncoder().encode([line("a"), line("b"), line("c"), line("d")]))
    #expect(kept[0] == line("a"))

    let chat = chat(capacity: 3)
    chat.seed(kept)
    #expect(chat.lines.map(\.id) == ["b", "c", "d"], "the newest capacity-many")
    chat.seed([line("x")])
    #expect(chat.lines.map(\.id) == ["b", "c", "d"], "only an empty ring takes a seed")
    chat.handle(message("d", from: "1"))
    chat.handle(message("e", from: "1"))
    #expect(chat.lines.map(\.id) == ["c", "d", "e"], "a redelivered seed line is dropped and the ring rolls on")
}

@MainActor @Test func sessionFramesComeBackAsControl() {
    let chat = chat()
    let welcome = Data(
        #"{"metadata":{"message_type":"session_welcome"},"payload":{"session":{"id":"s1","status":"connected","keepalive_timeout_seconds":30,"reconnect_url":null}}}"#
            .utf8)
    #expect(chat.handle(welcome) == .welcome(sessionID: "s1", keepalive: 30))
    let reconnect = Data(
        #"{"metadata":{"message_type":"session_reconnect"},"payload":{"session":{"id":"s1","status":"reconnecting","reconnect_url":"wss://eventsub.wss.twitch.tv/ws?id=abc"}}}"#
            .utf8)
    #expect(chat.handle(reconnect) == .reconnect(URL(string: "wss://eventsub.wss.twitch.tv/ws?id=abc")!))
    let revocation = Data(
        #"{"metadata":{"message_type":"revocation","subscription_type":"channel.chat.message"},"payload":{"subscription":{"id":"f1","status":"authorization_revoked","type":"channel.chat.message","version":"1"}}}"#
            .utf8)
    #expect(chat.handle(revocation) == .revoked("Twitch stopped channel.chat.message: authorization_revoked"))
    #expect(chat.handle(Data(#"{"metadata":{"message_type":"session_keepalive"},"payload":{}}"#.utf8)) == nil)
    #expect(chat.handle(Data("not json".utf8)) == nil)
}

@Test func colorPrefersTwitchsOwnAndMutesBots() {
    let picked = ChatLine(id: "1", userId: "1", login: "kate", displayName: "Kate", text: "", color: "#00FF7F")
    #expect(picked.colorHex == "#00FF7F")
    let unpicked = ChatLine(id: "2", userId: "1", login: "kate", displayName: "Kate", text: "")
    #expect(unpicked.colorHex == usernameColorHex("kate"))
    #expect(unpicked.colorHex?.hasPrefix("#") == true)
    let owner = ChatLine(id: "3", userId: "9", login: "adanalife_", displayName: "", text: "", badges: ["broadcaster": "1"])
    #expect(owner.colorHex == "#ffc857")
    let bot = ChatLine(id: "4", userId: "5", login: "Nightbot", displayName: "", text: "", color: "#0000FF")
    #expect(bot.colorHex == nil)
}

/// The web console's own answers for these names, from its `username_color`.
/// Pinned rather than derived, so a change to either side's palette or hash
/// fails here.
@Test func usernameColoursMatchTheConsole() {
    #expect(usernameColorHex("kate") == "#9ee493")
    #expect(usernameColorHex("mel", platform: "twitch") == "#7fb0ff")
    #expect(usernameColorHex("gus", platform: "youtube") == "#ff7eb3")
    // A platform with no palette of its own, or none named, takes the shared one.
    #expect(usernameColorHex("kate", platform: "kick") == "#ff7eb3")
    #expect(usernameColorHex("kate", platform: nil) == "#ff7eb3")
    // Hashed lowercased, so a display-cased name is the same colour.
    #expect(usernameColorHex("Kate") == "#9ee493")
    #expect(usernameColorHex("kate", isBroadcaster: true) == "#ffc857")
    #expect(usernameColorHex("nightbot") == nil)
}

/// The RFC 3174 vectors, one long enough to spill into a second block —
/// `usernameColorHex` only hashes short logins, so nothing else would catch a
/// padding bug.
@Test func sha1MatchesTheKnownVectors() {
    func hex(_ s: String) -> String { sha1(Array(s.utf8)).map { String(format: "%02x", $0) }.joined() }
    #expect(hex("abc") == "a9993e364706816aba3e25717850c26c9cd0d89d")
    #expect(
        hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")
            == "84983e441c3bd26ebaae4aa1f95129e5e54670f1")
}

@Test func badgeTagsLabelSubMonthsAndMods() {
    let line = ChatLine(
        id: "1", userId: "1", login: "k", displayName: "", text: "",
        badges: ["subscriber": "12", "moderator": "1", "broadcaster": "1", "founder": "0"])
    #expect(line.badgeTags.map(\.label) == ["founder", "mod", "sub 12"])
    let tier3 = ChatLine(id: "2", userId: "1", login: "k", displayName: "", text: "", badges: ["subscriber": "3006"])
    #expect(tier3.badgeTags.map(\.label) == ["sub 6"])
}

@MainActor @Test func badgeArtLayersTheChannelOverGlobal() async throws {
    let art = try await chat().helix.badgeArt()
    #expect(art["subscriber"]?["12"]?["url_2x"] == "https://c/sub2")
    #expect(art["moderator"]?["1"]?["url_4x"] == "https://g/mod4")
    #expect(art.url(for: BadgeTag(name: "moderator", version: "1", label: "mod")) == URL(string: "https://g/mod2"))
}

@MainActor @Test func moderatesPagesThroughTheCursor() async {
    #expect(await chat().helix.moderates())
    #expect(await chat(userID: "1971641").helix.moderates())
}

@MainActor @Test func aUserCardReadsTheProfileByID() async throws {
    let helix = chat().helix
    let user = try #require(try await helix.user(id: "11"))
    #expect(user.displayName == "RoadWatcher")
    #expect(user.profileImage == URL(string: "https://static-cdn.jtvnw.net/u/11-300x300.png"))
    #expect(user.createdAt == Date(timeIntervalSince1970: 1_481_747_548))
    #expect(try await helix.user(id: "404") == nil)
}

@MainActor @Test func aDroppedSendIsAnError() async {
    await #expect(throws: TwitchChatError.dropped("duplicate message")) { try await chat().helix.send("hi") }
}

@MainActor @Test func emotesListTheChannelsThenTheGlobals() async throws {
    #expect(try await chat().helix.emotes() == [ChatEmote(id: "emotesv2_1", name: "danaVan"), ChatEmote(id: "25", name: "Kappa")])
}

@Test func theComposerKnowsWhichMentionIsBeingTyped() {
    #expect(mentionInProgress("hey @ka") == "ka")
    #expect(mentionInProgress("@") == "")
    #expect(mentionInProgress("hey @kate ") == nil)
    #expect(mentionInProgress("hey kate") == nil)
    #expect(completingLastWord("hey @ka", with: "@Kate") == "hey @Kate ")
    #expect(completingLastWord("", with: "@Kate") == "@Kate ")
    #expect(completingLastWord("a b", with: "c") == "a c ")
}

@MainActor @Test func chatModeReadsFromHelixAndFollowsUpdates() async throws {
    let chat = chat()
    #expect(try await chat.helix.chatMode() == ChatMode(slowSeconds: 30, followerMinutes: 10))
    chat.handle(
        event(
            "channel.chat_settings.update",
            #""emote_mode":true,"follower_mode":false,"follower_mode_duration_minutes":null,"slow_mode":true,"slow_mode_wait_time_seconds":120,"subscriber_mode":true,"unique_chat_mode":false"#
        ))
    #expect(chat.mode == ChatMode(slowSeconds: 120, subscribersOnly: true, emoteOnly: true))
    // Off with a stale duration still reads as off.
    chat.handle(
        event(
            "channel.chat_settings.update",
            #""emote_mode":false,"follower_mode":true,"follower_mode_duration_minutes":0,"slow_mode":false,"slow_mode_wait_time_seconds":30,"subscriber_mode":false,"unique_chat_mode":false"#
        ))
    #expect(chat.mode == ChatMode(followerMinutes: 0))
}

@Test func chatModeSummarizesAndCountsDown() {
    #expect(ChatMode().summary == nil)
    #expect(ChatMode(followerMinutes: 0).summary == "Followers only")
    #expect(
        ChatMode(slowSeconds: 30, followerMinutes: 10080, emoteOnly: true).summary
            == "Slow mode, 30s · Followers of 7d only · Emotes only")
    let sent = Date(timeIntervalSince1970: 1000)
    let slow = ChatMode(slowSeconds: 30)
    #expect(slow.wait(since: nil) == 0)
    #expect(slow.wait(since: sent, now: sent) == 30)
    #expect(slow.wait(since: sent, now: sent.addingTimeInterval(12.5)) == 18)
    #expect(slow.wait(since: sent, now: sent.addingTimeInterval(31)) == 0)
    #expect(ChatMode().wait(since: sent, now: sent) == 0)
}

@MainActor @Test func aHeldMessageWaitsUntilAnyModRules() throws {
    let chat = chat()
    let hold = #"""
        "broadcaster_user_id":"1971641","user_id":"11","user_login":"roadwatcher","user_name":"RoadWatcher",
        "message_id":"h1","message":{"text":"wow that is a bad word","fragments":[{"type":"text","text":"wow that is a bad word"}]},
        "reason":"automod","automod":{"category":"swearing","level":2,"boundaries":[{"start_pos":14,"end_pos":22}]},
        "blocked_term":null,"status":"unknown","held_at":"2026-09-30T14:56:51.123456789Z"
        """#
    chat.handle(event("automod.message.hold", hold))
    chat.handle(event("automod.message.hold", hold))
    let held = try #require(chat.held.first)
    #expect(chat.held.count == 1)
    #expect(held.id == "h1" && held.userId == "11" && held.displayName == "RoadWatcher")
    #expect(held.text == "wow that is a bad word" && held.why == "AutoMod: swearing 2")
    #expect(held.heldAt == Date(timeIntervalSince1970: 1_790_780_211.123))
    // A message the log would show is not a held one, and a hold is not a line.
    #expect(chat.lines.isEmpty)

    chat.handle(
        event(
            "automod.message.hold",
            #""user_id":"12","user_login":"vanfan","message_id":"h2","message":{"text":"buy now"},"reason":"blocked_term","automod":null,"blocked_term":{"terms_found":[{"term_id":"t1","boundary":{"start_pos":0,"end_pos":6},"owner_broadcaster_user_id":"1971641"}]}"#
        ))
    #expect(chat.held.map(\.why) == ["AutoMod: swearing 2", "Blocked term"])
    chat.handle(event("automod.message.update", #""message_id":"h1","status":"approved","moderator_user_id":"2914196""#))
    #expect(chat.held.map(\.id) == ["h2"])
    chat.handle(event("automod.message.update", #""message_id":"h2","status":"expired""#))
    #expect(chat.held.isEmpty)
}

@Test func chatModeSettingsSendALengthOnlyWithItsMode() throws {
    func json(_ mode: ChatMode) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: mode.settings, options: .sortedKeys), as: UTF8.self)
    }
    #expect(
        try json(ChatMode())
            == #"{"emote_mode":false,"follower_mode":false,"slow_mode":false,"subscriber_mode":false,"unique_chat_mode":false}"#)
    #expect(
        try json(ChatMode(slowSeconds: 30, followerMinutes: 0, emoteOnly: true))
            == #"{"emote_mode":true,"follower_mode":true,"follower_mode_duration":0,"slow_mode":true,"slow_mode_wait_time":30,"subscriber_mode":false,"unique_chat_mode":false}"#
    )
}
