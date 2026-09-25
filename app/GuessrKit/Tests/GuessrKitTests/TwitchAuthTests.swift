import Foundation
import GuessrKit
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Stands in for id.twitch.tv: hands out a device code, says "pending" on the
/// first token poll and grants on the second, and validates the result.
final class StubTwitch: URLProtocol {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var tokenPolls = 0
    /// The form the most recent POST carried — the token grant, by the end.
    nonisolated(unsafe) static var lastBody = ""

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let body = requestBody(request)
        let (status, reply): (Int, String) = Self.lock.withLock {
            if request.httpMethod == "POST" { Self.lastBody = body }
            switch request.url?.lastPathComponent {
            case "device":
                return (
                    200,
                    #"{"device_code":"dev1","user_code":"ABCD-EFGH","verification_uri":"https://www.twitch.tv/activate","expires_in":1800,"interval":0}"#
                )
            case "token":
                Self.tokenPolls += 1
                if Self.tokenPolls == 1 { return (400, #"{"status":400,"message":"authorization_pending"}"#) }
                return (200, #"{"access_token":"acc","refresh_token":"ref","expires_in":14400,"token_type":"bearer"}"#)
            case "validate":
                return (200, #"{"client_id":"app1","login":"Kate","user_id":"555","expires_in":14400,"scopes":["user:read:chat","user:write:chat"]}"#)
            default:
                return (404, "{}")
            }
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Test func deviceCodeLoginPollsThroughPendingAndNamesTheUser() async throws {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubTwitch.self]
    let auth = TwitchAuth(
        clientID: "app1", session: URLSession(configuration: config), base: URL(string: "https://twitch.test/oauth2")!)

    let code = try await auth.start()
    #expect(code.userCode == "ABCD-EFGH")

    let session = try await auth.poll(code)
    #expect(session.accessToken == "acc")
    #expect(session.login == "kate")
    #expect(session.userID == "555")
    #expect(!session.expiresSoon)
    #expect(session.scopes == ["user:read:chat", "user:write:chat"])
    #expect(!session.canModerate)
    #expect(StubTwitch.lastBody.contains("device_code=dev1"))
    #expect(StubTwitch.lastBody.contains("client_id=app1"))
}

@Test func anUnconfiguredBuildRefusesToStart() async {
    await #expect(throws: TwitchAuthError.notConfigured) { try await TwitchAuth(clientID: "").start() }
}

@Test func ownerIsMatchedByUserIDAndAnEmptyOwnerMatchesNobody() {
    let session = TwitchSession(accessToken: "a", refreshToken: "r", expiresAt: .now, login: "kate", userID: "555")
    #expect(session.isOwner("555"))
    #expect(!session.isOwner("556"))
    #expect(!session.isOwner(""))
    #expect(!TwitchSession(accessToken: "a", refreshToken: "r", expiresAt: .now, login: "", userID: "").isOwner(""))
}

@Test func canModerateNeedsBothModScopes() {
    func session(_ scopes: [String]?) -> TwitchSession {
        TwitchSession(accessToken: "a", refreshToken: "r", expiresAt: .now, login: "kate", userID: "555", scopes: scopes)
    }
    #expect(session(TwitchAuth.modScopes).canModerate)
    #expect(!session(TwitchAuth.scopes + ["moderator:manage:chat_messages"]).canModerate)
    #expect(!session(nil).canModerate)
}

/// A request's body as a string. URLSession hands a protocol the body as a
/// stream, not as `httpBody`.
private func requestBody(_ request: URLRequest) -> String {
    guard let stream = request.httpBodyStream else { return String(decoding: request.httpBody ?? Data(), as: UTF8.self) }
    stream.open()
    defer { stream.close() }
    var out = Data()
    var buf = [UInt8](repeating: 0, count: 1024)
    while stream.hasBytesAvailable {
        let n = stream.read(&buf, maxLength: buf.count)
        if n <= 0 { break }
        out.append(buf, count: n)
    }
    return String(decoding: out, as: UTF8.self)
}

/// id.twitch.tv as an app the system keeps suspending sees it: the first two
/// token polls die the way a suspended app's in-flight requests do, and the
/// third is answered. What the human sees is a browser, a switch back, and a
/// login.
final class StubSuspendingTwitch: URLProtocol {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var tokenPolls = 0
    /// How many token polls the transport ate, so a test can tell a retry from
    /// a stub that never dropped anything.
    static var dropped: Int { lock.withLock { min(tokenPolls, 2) } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        enum Reply { case drop, send(String) }
        let reply: Reply = Self.lock.withLock {
            switch request.url?.lastPathComponent {
            case "device":
                return .send(
                    #"{"device_code":"dev1","user_code":"ABCD-EFGH","verification_uri":"https://www.twitch.tv/activate","expires_in":1800,"interval":0}"#
                )
            case "token":
                Self.tokenPolls += 1
                if Self.tokenPolls <= 2 { return .drop }
                return .send(#"{"access_token":"acc","refresh_token":"ref","expires_in":14400,"token_type":"bearer"}"#)
            case "validate":
                return .send(#"{"client_id":"app1","login":"Kate","user_id":"555","expires_in":14400}"#)
            default:
                return .send("{}")
            }
        }
        // Answered off `startLoading`'s own thread: a failure handed back
        // inline re-enters URLSession from inside the call it is answering, and
        // the suite deadlocks with every test parked.
        nonisolated(unsafe) let stub = self
        let url = request.url!
        DispatchQueue.global().async {
            switch reply {
            case .drop:
                stub.client?.urlProtocol(stub, didFailWithError: URLError(.cancelled))
            case .send(let body):
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
                stub.client?.urlProtocol(stub, didReceive: response, cacheStoragePolicy: .notAllowed)
                stub.client?.urlProtocol(stub, didLoad: Data(body.utf8))
                stub.client?.urlProtocolDidFinishLoading(stub)
            }
        }
    }
}

/// The login is *meant* to be waiting while the human is in the browser, which
/// is exactly when iOS suspends the app and cancels its requests. A dropped
/// poll is not Twitch saying no, and must not end a login that still has 30
/// minutes on its code.
@Test func aSuspendedAppKeepsPollingRatherThanFailingTheLogin() async throws {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubSuspendingTwitch.self]
    let auth = TwitchAuth(
        clientID: "app1", session: URLSession(configuration: config), base: URL(string: "https://twitch.test/oauth2")!)
    let code = try await auth.start()

    let session = try await auth.poll(code)
    #expect(StubSuspendingTwitch.dropped == 2, "the stub never dropped a poll")
    #expect(session.accessToken == "acc")
    #expect(session.login == "kate")
}

/// Answers one status and one body to every OAuth call, so a login fails the
/// way Twitch fails it. `validate` always answers, since a refusal never
/// reaches it and a grant needs it to name the user.
final class RefusingTwitch: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) static var status = 400
    nonisolated(unsafe) static var body = #"{"status":400,"message":"authorization_pending"}"#
    /// Who `validate` says the token belongs to — "" for the nobody a refresh
    /// has to fall back from.
    nonisolated(unsafe) static var login = "Kate"
    nonisolated(unsafe) static var userID = "555"

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let (status, reply): (Int, String) = Self.lock.withLock {
            if request.url?.lastPathComponent == "validate" {
                return (
                    200,
                    #"{"client_id":"app1","login":"\#(Self.login)","user_id":"\#(Self.userID)","expires_in":14400}"#
                )
            }
            return (Self.status, Self.body)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    /// One auth against this stub, answering `status` and `body`. The tests
    /// below share the stub's static answer, so they set it here, one at a time.
    static func auth(status: Int, body: String, login: String = "Kate", userID: String = "555") -> TwitchAuth {
        lock.withLock {
            Self.status = status
            Self.body = body
            Self.login = login
            Self.userID = userID
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RefusingTwitch.self]
        return TwitchAuth(
            clientID: "app1", session: URLSession(configuration: config), base: URL(string: "https://twitch.test/oauth2")!)
    }
}

/// A code Twitch has handed out and is still waiting on, as it arrives on the
/// wire — decoded rather than built, since that is the only way it is made.
private func pendingCode(expiresIn: Int = 1800) throws -> DeviceCode {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(
        DeviceCode.self,
        from: Data(
            #"{"device_code":"dev1","user_code":"ABCD-EFGH","verification_uri":"https://www.twitch.tv/activate","expires_in":\#(expiresIn),"interval":0}"#
                .utf8))
}

/// Serialized: the stub answers from statics, so two of these running at once
/// would each read the other's status and body.
@Suite(.serialized)
struct TwitchRefusals {
    /// The three ends a login can come to, all through the one stub.
    @Test func aLoginEndsOnTwitchsOwnAnswerAndOnNothingElse() async throws {
        // The human said no in the browser. That is Twitch's answer, not a
        // dropped request, so the poll stops rather than waiting out the code.
        var auth = RefusingTwitch.auth(status: 400, body: #"{"status":400,"message":"access_denied"}"#)
        await #expect(throws: TwitchAuthError.refused("access_denied")) { try await auth.poll(pendingCode()) }

        // Twitch refuses the code request itself — a client id it doesn't know.
        auth = RefusingTwitch.auth(status: 400, body: #"{"status":400,"message":"invalid client"}"#)
        await #expect(throws: TwitchAuthError.refused("invalid client")) { try await auth.start() }

        // The code ran out while the human was away: still pending, but there
        // is nothing left to poll for.
        auth = RefusingTwitch.auth(status: 400, body: #"{"status":400,"message":"authorization_pending"}"#)
        let expired = try pendingCode(expiresIn: 0)
        await #expect(throws: TwitchAuthError.expired) { try await auth.poll(expired) }
    }

    /// Twitch's public-client refresh tokens are single use, so the pair that
    /// comes back replaces the old one whole — and a validate that names nobody
    /// must not cost the session the login and id it already had.
    @Test func refreshingReplacesThePairAndKeepsWhoItIsWhenTwitchNamesNobody() async throws {
        let old = TwitchSession(
            accessToken: "stale", refreshToken: "r1", expiresAt: .now.addingTimeInterval(60), login: "kate",
            userID: "555")
        #expect(old.expiresSoon)

        var auth = RefusingTwitch.auth(
            status: 200,
            body: #"{"access_token":"acc2","refresh_token":"r2","expires_in":14400,"token_type":"bearer"}"#)
        var fresh = try await auth.refresh(old)
        #expect(fresh.accessToken == "acc2")
        #expect(fresh.refreshToken == "r2")
        #expect(fresh.login == "kate")
        #expect(!fresh.expiresSoon)

        auth = RefusingTwitch.auth(
            status: 200,
            body: #"{"access_token":"acc3","refresh_token":"r3","expires_in":14400,"token_type":"bearer"}"#,
            login: "", userID: "")
        fresh = try await auth.refresh(old)
        #expect(fresh.login == "kate")
        #expect(fresh.userID == "555")

        // A refresh token Twitch has already spent: the login is gone and the
        // human has to do it again, which the caller can only know from a throw.
        auth = RefusingTwitch.auth(status: 400, body: #"{"status":400,"message":"Invalid refresh token"}"#)
        await #expect(throws: TwitchAuthError.refused("Invalid refresh token")) { try await auth.refresh(old) }
    }
}
