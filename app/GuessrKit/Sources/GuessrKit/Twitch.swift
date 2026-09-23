import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
#if canImport(Security)
    import Security
#endif

/// A Twitch login: the tokens the device-code flow handed back and whose they
/// are. A credential, so it is kept in a `SessionStore`, never in defaults.
public struct TwitchSession: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public var login: String
    /// Twitch's numeric user id. The key for anything that decides who someone
    /// is: a login can be renamed and, once released, taken by someone else.
    public var userID: String

    public init(accessToken: String, refreshToken: String, expiresAt: Date, login: String, userID: String) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.login = login
        self.userID = userID
    }

    /// Within ten minutes of expiry — refresh before a request lands on a dead token.
    public var expiresSoon: Bool { expiresAt.timeIntervalSinceNow < 600 }

    /// Whether this login is the owner the build names. An empty owner id is
    /// the default, and makes nobody the owner.
    public func isOwner(_ ownerID: String) -> Bool {
        !ownerID.isEmpty && userID == ownerID
    }
}

/// Where a login is kept between launches. A protocol so tests and previews
/// never touch the real Keychain, which can block on a system prompt.
public protocol SessionStore: Sendable {
    func load() -> TwitchSession?
    func save(_ session: TwitchSession)
    func clear()
}

/// A store that forgets on relaunch: tests, previews, and platforms with no Keychain.
public final class MemorySessionStore: SessionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var session: TwitchSession?

    public init(_ session: TwitchSession? = nil) { self.session = session }

    public func load() -> TwitchSession? { lock.withLock { session } }
    public func save(_ session: TwitchSession) { lock.withLock { self.session = session } }
    public func clear() { lock.withLock { session = nil } }
}

#if canImport(Security)
    /// The Keychain, readable once the device has been unlocked since boot and
    /// never restored onto a second device.
    public struct KeychainSessionStore: SessionStore {
        public var service: String

        public init(service: String = "lol.dana.guessr.twitch") { self.service = service }

        private var query: [CFString: Any] {
            [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: "session"]
        }

        public func load() -> TwitchSession? {
            var q = query
            q[kSecReturnData] = true
            var item: CFTypeRef?
            guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
                return nil
            }
            return try? JSONDecoder().decode(TwitchSession.self, from: data)
        }

        /// Replaces whatever was saved. A failed write costs a login on the
        /// next launch and nothing on this one, so it is not an error.
        public func save(_ session: TwitchSession) {
            guard let data = try? JSONEncoder().encode(session) else { return }
            SecItemDelete(query as CFDictionary)
            var q = query
            q[kSecValueData] = data
            q[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(q as CFDictionary, nil)
        }

        public func clear() { SecItemDelete(query as CFDictionary) }
    }
#endif

/// What Twitch hands back to start a device-code login: the code the human
/// types, where they type it, and how to poll for the result.
public struct DeviceCode: Decodable, Sendable, Equatable {
    public var deviceCode: String
    public var userCode: String
    public var verificationUri: String
    public var expiresIn: Int
    public var interval: Int
}

public enum TwitchAuthError: Error, LocalizedError, Equatable {
    case notConfigured
    case expired
    case refused(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "Twitch login isn't configured in this build"
        case .expired: "The code expired before it was entered — try again"
        case .refused(let why): "Twitch refused the login: \(why)"
        }
    }
}

/// Twitch's device code grant — the one OAuth flow a public client can run
/// without a secret and still refresh. The app shows a code, the human types it
/// at twitch.tv/activate, the app polls until Twitch hands over tokens.
public struct TwitchAuth: Sendable {
    /// Chat as yourself, and let a server see which channels you moderate —
    /// that read, on your own token, is how a channel mod is recognized without
    /// anyone keeping a list.
    public static let scopes = ["user:write:chat", "user:read:moderated_channels"]

    /// The Twitch application's client id, registered as a Public client. Not a
    /// secret; empty leaves login switched off.
    public var clientID: String
    public var session: URLSession
    public var base: URL

    public init(
        clientID: String,
        session: URLSession = .shared,
        base: URL = URL(string: "https://id.twitch.tv/oauth2")!
    ) {
        self.clientID = clientID
        self.session = session
        self.base = base
    }

    public var isConfigured: Bool { !clientID.isEmpty }

    /// Asks Twitch for a code to show the human.
    public func start() async throws -> DeviceCode {
        guard isConfigured else { throw TwitchAuthError.notConfigured }
        let (data, response) = try await post(
            "device", ["client_id": clientID, "scopes": Self.scopes.joined(separator: " ")])
        guard status(response) == 200 else { throw TwitchAuthError.refused(message(data)) }
        return try Guessr.decoder.decode(DeviceCode.self, from: data)
    }

    /// Polls until the human has entered `code` (or it expires), then asks
    /// Twitch whose token it is.
    ///
    /// The app spends the wait in the background, since the human has left for
    /// twitch.tv/activate, and iOS cancels in-flight requests when it suspends
    /// an app. Transport failures are retried to the code's own deadline; only
    /// Twitch's own answer, or a cancelled `Task`, ends the login early.
    public func poll(_ code: DeviceCode) async throws -> TwitchSession {
        let deadline = Date.now.addingTimeInterval(TimeInterval(code.expiresIn))
        while Date.now < deadline {
            try await Task.sleep(for: .seconds(max(code.interval, 1)))
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await post(
                    "token",
                    [
                        "client_id": clientID,
                        "device_code": code.deviceCode,
                        "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                        "scopes": Self.scopes.joined(separator: " "),
                    ])
            } catch is URLError {
                continue
            }
            if status(response) == 200 { return try await session(from: data) }
            let why = message(data)
            if why == "authorization_pending" || why == "slow_down" { continue }
            throw TwitchAuthError.refused(why)
        }
        throw TwitchAuthError.expired
    }

    /// Trades the refresh token for a fresh pair. Twitch's public-client refresh
    /// tokens are single-use, so the returned session replaces the old one.
    public func refresh(_ old: TwitchSession) async throws -> TwitchSession {
        let (data, response) = try await post(
            "token",
            ["client_id": clientID, "grant_type": "refresh_token", "refresh_token": old.refreshToken])
        guard status(response) == 200 else { throw TwitchAuthError.refused(message(data)) }
        var fresh = try await session(from: data)
        if fresh.login.isEmpty { fresh.login = old.login }
        if fresh.userID.isEmpty { fresh.userID = old.userID }
        return fresh
    }

    private struct TokenResponse: Decodable {
        var accessToken: String
        var refreshToken: String
        var expiresIn: Int
    }

    private struct Validation: Decodable {
        var login: String?
        var userId: String?
    }

    private func session(from data: Data) async throws -> TwitchSession {
        let token = try Guessr.decoder.decode(TokenResponse.self, from: data)
        var req = URLRequest(url: base.appending(path: "validate"))
        req.setValue("OAuth \(token.accessToken)", forHTTPHeaderField: "Authorization")
        let (body, _) = try await session.settledData(for: req)
        let who = try? Guessr.decoder.decode(Validation.self, from: body)
        return TwitchSession(
            accessToken: token.accessToken,
            refreshToken: token.refreshToken,
            expiresAt: .now.addingTimeInterval(TimeInterval(token.expiresIn)),
            login: (who?.login ?? "").lowercased(),
            userID: who?.userId ?? ""
        )
    }

    private func post(_ path: String, _ form: [String: String]) async throws -> (Data, URLResponse) {
        var req = URLRequest(url: base.appending(path: path))
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(Self.formEncode(form).utf8)
        return try await session.settledData(for: req)
    }

    static func formEncode(_ form: [String: String]) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        return form.keys.sorted().map { key in
            let value = form[key]!
            return "\(key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key)="
                + (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)
        }.joined(separator: "&")
    }

    private func status(_ response: URLResponse) -> Int { (response as? HTTPURLResponse)?.statusCode ?? 0 }

    /// Twitch's error envelope is `{"status": 400, "message": "…"}`.
    private func message(_ data: Data) -> String {
        struct Envelope: Decodable { var message: String? }
        return (try? JSONDecoder().decode(Envelope.self, from: data))?.message ?? String(decoding: data, as: UTF8.self)
    }
}
