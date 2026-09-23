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

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let (status, reply): (Int, String) = Self.lock.withLock {
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
                return (200, #"{"client_id":"app1","login":"Kate","user_id":"555","expires_in":14400}"#)
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
