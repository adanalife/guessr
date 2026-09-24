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
}

@MainActor @Test func deleteAndClearTakeLinesOut() {
    let chat = chat()
    for (id, user) in [("m1", "1"), ("m2", "2"), ("m3", "1"), ("m4", "3")] { chat.handle(message(id, from: user)) }
    chat.handle(event("channel.chat.message_delete", #""target_user_id":"3","message_id":"m4""#))
    #expect(chat.lines.map(\.id) == ["m1", "m2", "m3"])
    chat.handle(event("channel.chat.clear_user_messages", #""target_user_id":"1""#))
    #expect(chat.lines.map(\.id) == ["m2"])
}

@MainActor @Test func theRingIsBoundedAndDropsRedeliveries() {
    let chat = chat(capacity: 3)
    for i in 1...5 { chat.handle(message("m\(i)", from: "1")) }
    chat.handle(message("m5", from: "1"))
    #expect(chat.lines.map(\.id) == ["m3", "m4", "m5"])
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

@Test func sha1MatchesAKnownDigest() {
    let hex = sha1(Array("abc".utf8)).map { String(format: "%02x", $0) }.joined()
    #expect(hex == "a9993e364706816aba3e25717850c26c9cd0d89d")
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
    let art = try await chat().badgeArt()
    #expect(art["subscriber"]?["12"]?["url_2x"] == "https://c/sub2")
    #expect(art["moderator"]?["1"]?["url_4x"] == "https://g/mod4")
    #expect(art.url(for: BadgeTag(name: "moderator", version: "1", label: "mod")) == URL(string: "https://g/mod2"))
}

@MainActor @Test func moderatesPagesThroughTheCursor() async {
    #expect(await chat().moderates())
    #expect(await chat(userID: "1971641").moderates())
}

@MainActor @Test func aDroppedSendIsAnError() async {
    await #expect(throws: TwitchChatError.dropped("duplicate message")) { try await chat().send("hi") }
}

@MainActor @Test func emotesListTheChannelsThenTheGlobals() async throws {
    #expect(try await chat().emotes() == [ChatEmote(id: "emotesv2_1", name: "danaVan"), ChatEmote(id: "25", name: "Kappa")])
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
