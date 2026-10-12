import Foundation
import Testing

@testable import GuessrKit

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@MainActor @Test func aPrivmsgDecodesIntoALine() throws {
    let lurk = TwitchLurk(channel: "adanalife_")
    lurk.handle(
        #"@badges=moderator/1,subscriber/12;color=#1E90FF;display-name=RoadWatcher;emotes=25:14-18;first-msg=1;id=m1;tmi-sent-ts=1760000000000;user-id=11 :roadwatcher!roadwatcher@roadwatcher.tmi.twitch.tv PRIVMSG #adanalife_ :looks like 🇺🇸 Kappa"#
    )
    let line = try #require(lurk.lines.first)
    #expect(line.id == "m1")
    #expect(line.login == "roadwatcher")
    #expect(line.displayName == "RoadWatcher")
    #expect(line.color == "#1E90FF")
    #expect(line.badges == ["moderator": "1", "subscriber": "12"])
    // The flag is two code points (four UTF-16 units), so Kappa starts at 14.
    #expect(line.fragments == [.text("looks like 🇺🇸 "), .emote(id: "25", text: "Kappa")])
    #expect(line.isFirstMessage)
    #expect(line.timestamp == Date(timeIntervalSince1970: 1_760_000_000))
}

@MainActor @Test func aReplyAndAnActionDecode() throws {
    let lurk = TwitchLurk(channel: "adanalife_")
    lurk.handle(
        "@id=m2;user-id=12;display-name=;reply-parent-msg-id=m1;reply-parent-user-login=roadwatcher;reply-parent-display-name=RoadWatcher;reply-parent-msg-body=where\\sis\\sthis? :kate!kate@kate.tmi.twitch.tv PRIVMSG #adanalife_ :\u{1}ACTION waves\u{1}"
    )
    let line = try #require(lurk.lines.first)
    #expect(line.text == "waves")
    #expect(line.displayName == "kate")
    #expect(line.reply == ChatReply(parentId: "m1", login: "roadwatcher", displayName: "RoadWatcher", text: "where is this?"))
}

@MainActor @Test func aUsernoticeIsALineWithAKind() throws {
    let lurk = TwitchLurk(channel: "adanalife_")
    lurk.handle(
        #"@id=n1;login=kate;display-name=Kate;msg-id=subgift;system-msg=Kate\sgifted\sa\sTier\s1\ssub!;user-id=13 :tmi.twitch.tv USERNOTICE #adanalife_"#
    )
    let line = try #require(lurk.lines.first)
    #expect(line.kind == "sub_gift")
    #expect(line.notice == "Kate gifted a Tier 1 sub!")
    #expect(line.text.isEmpty)
}

@MainActor @Test func clearmsgAndClearchatMarkLinesDeleted() {
    let lurk = TwitchLurk(channel: "adanalife_")
    for (id, user) in [("a", "1"), ("b", "2"), ("c", "2"), ("d", "3")] {
        lurk.handle("@id=\(id);user-id=\(user) :u!u@u PRIVMSG #adanalife_ :hi")
    }
    lurk.handle("@target-msg-id=a :tmi.twitch.tv CLEARMSG #adanalife_ :hi")
    lurk.handle("@target-user-id=2 :tmi.twitch.tv CLEARCHAT #adanalife_ :u")
    #expect(lurk.lines.map(\.deleted) == [true, true, true, false])
    lurk.handle(":tmi.twitch.tv CLEARCHAT #adanalife_")
    #expect(lurk.lines.allSatisfy { $0.deleted })
}

@MainActor @Test func connectionLinesComeBackAsControl() {
    let lurk = TwitchLurk(channel: "adanalife_")
    #expect(lurk.handle("PING :tmi.twitch.tv") == .pong("tmi.twitch.tv"))
    #expect(lurk.handle("@room-id=1;slow=0 :tmi.twitch.tv ROOMSTATE #adanalife_") == .joined)
    #expect(lurk.handle(":tmi.twitch.tv RECONNECT") == .reconnect)
    #expect(lurk.handle("@id=x :u!u@u PRIVMSG #adanalife_ :no user id") == nil)
    #expect(lurk.lines.isEmpty)
}

/// The loop joins anonymously, counts as connected once Twitch sends the
/// room's state, and answers a PING.
@MainActor @Test func theLoopJoinsAndAnswersPings() async throws {
    let lurk = TwitchLurk(channel: "ADanaLife_")
    var opened: [ScriptedSocket] = []
    lurk.makeSocket = { url in
        let socket = ScriptedSocket(url, [.frame("@slow=0 :tmi.twitch.tv ROOMSTATE #adanalife_\r\nPING :tmi.twitch.tv\r\n")])
        opened.append(socket)
        return socket
    }
    lurk.start()
    defer { lurk.stop() }
    for _ in 0..<100 where !(lurk.isConnected && opened.first?.sent.count == 4) {
        try await Task.sleep(for: .milliseconds(50))
    }
    let sent = try #require(opened.first).sent
    #expect(sent.first == "CAP REQ :twitch.tv/tags twitch.tv/commands")
    #expect(sent.contains { $0.hasPrefix("NICK justinfan") })
    #expect(sent.contains("JOIN #adanalife_"))
    #expect(sent.last == "PONG :tmi.twitch.tv")
    #expect(lurk.isConnected)
}
