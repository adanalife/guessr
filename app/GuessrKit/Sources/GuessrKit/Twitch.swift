import Foundation
import Synchronization

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
#if canImport(Security)
    import Security
    import os
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
    /// What the token was granted, as Twitch's validate endpoint reports it.
    /// Nil on a session saved before this was recorded, which reads as
    /// holding nothing extra.
    public var scopes: [String]?

    public init(
        accessToken: String, refreshToken: String, expiresAt: Date, login: String, userID: String,
        scopes: [String]? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.login = login
        self.userID = userID
        self.scopes = scopes
    }

    /// Whether this token can delete messages and ban on Twitch's say-so.
    public var canModerate: Bool { Set(TwitchAuth.modScopes).isSubset(of: scopes ?? []) }

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
public final class MemorySessionStore: SessionStore {
    private let session: Mutex<TwitchSession?>

    public init(_ session: TwitchSession? = nil) { self.session = Mutex(session) }

    public func load() -> TwitchSession? { session.withLock { $0 } }
    public func save(_ session: TwitchSession) { self.session.withLock { $0 = session } }
    public func clear() { session.withLock { $0 = nil } }
}

#if canImport(Security)
    /// One generic-password Keychain item, readable once the device has been
    /// unlocked since boot and never restored onto a second device.
    struct KeychainItem: Sendable {
        var service: String
        var account: String

        private var query: [CFString: Any] {
            [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        }

        func read() -> Data? {
            var q = query
            q[kSecReturnData] = true
            var item: CFTypeRef?
            guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess else { return nil }
            return item as? Data
        }

        /// Replaces whatever was saved, in place, so a failed write keeps the
        /// value before it rather than nothing. A failed write is not an error:
        /// it costs the value on the next launch and nothing on this one, and
        /// is logged.
        func write(_ data: Data) {
            let attrs: [CFString: Any] = [
                kSecValueData: data, kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
            var status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
            if status == errSecItemNotFound {
                status = SecItemAdd(query.merging(attrs) { $1 } as CFDictionary, nil)
            }
            if status != errSecSuccess {
                Logger(subsystem: "lol.dana.guessr", category: "keychain")
                    .error("keychain write for \(service, privacy: .public) failed: \(status)")
            }
        }

        func delete() { SecItemDelete(query as CFDictionary) }
    }

    /// The Twitch login, in the Keychain.
    public struct KeychainSessionStore: SessionStore {
        let item: KeychainItem

        public init(service: String = "lol.dana.guessr.twitch") {
            item = KeychainItem(service: service, account: "session")
        }

        public func load() -> TwitchSession? {
            item.read().flatMap { try? JSONDecoder().decode(TwitchSession.self, from: $0) }
        }

        public func save(_ session: TwitchSession) {
            if let data = try? JSONEncoder().encode(session) { item.write(data) }
        }

        public func clear() { item.delete() }
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
        case .notConfigured: String(localized: "Twitch login isn't configured in this build", bundle: .module)
        case .expired: String(localized: "The code expired before it was entered. Try again.", bundle: .module)
        case .refused(let why): String(localized: "Twitch refused the login: \(why)", bundle: .module)
        }
    }
}

/// Twitch's device code grant — the one OAuth flow a public client can run
/// without a secret and still refresh. The app shows a code, the human types it
/// at twitch.tv/activate, the app polls until Twitch hands over tokens.
public struct TwitchAuth: Sendable {
    /// Read and write chat as yourself, and see which channels you moderate —
    /// that read, on your own token, is how a channel mod is recognized without
    /// anyone keeping a list.
    public static let scopes = ["user:read:chat", "user:write:chat", "user:read:moderated_channels"]
    /// The same, plus the moderation verbs — asked for only once the login
    /// turns out to moderate the channel, so a viewer's consent screen never
    /// lists powers they don't have. Adding a scope here asks every mod for a
    /// second login again: `canModerate` wants all of them.
    public static let modScopes =
        scopes + [
            "moderator:manage:chat_messages", "moderator:manage:banned_users", "moderator:manage:automod",
            "moderator:manage:warnings", "moderator:manage:chat_settings",
        ]

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
    public func start(scopes: [String] = TwitchAuth.scopes) async throws -> DeviceCode {
        guard isConfigured else { throw TwitchAuthError.notConfigured }
        let (data, response) = try await post(
            "device", ["client_id": clientID, "scopes": scopes.joined(separator: " ")])
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
    public func poll(_ code: DeviceCode, scopes: [String] = TwitchAuth.scopes) async throws -> TwitchSession {
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
                        "scopes": scopes.joined(separator: " "),
                    ])
            } catch is URLError {
                continue
            }
            if status(response) == 200 {
                let fresh = try await session(from: data)
                // Nothing can chat or moderate as a login Twitch never named.
                guard !fresh.userID.isEmpty else { throw TwitchAuthError.refused("validate named nobody") }
                return fresh
            }
            let why = message(data)
            if why == "authorization_pending" || why == "slow_down" { continue }
            throw TwitchAuthError.refused(why)
        }
        throw TwitchAuthError.expired
    }

    /// Trades the refresh token for a fresh pair. Twitch's public-client refresh
    /// tokens are single-use, so the returned session replaces the old one.
    ///
    /// Only a 400 or 401 is Twitch turning the token down, and throws `refused`;
    /// any other status (an outage's 503, a 429) throws a `URLError`, so callers
    /// keep the login and try again later.
    public func refresh(_ old: TwitchSession) async throws -> TwitchSession {
        let (data, response) = try await post(
            "token",
            ["client_id": clientID, "grant_type": "refresh_token", "refresh_token": old.refreshToken])
        switch status(response) {
        case 200: break
        case 400, 401: throw TwitchAuthError.refused(message(data))
        default: throw URLError(.badServerResponse)
        }
        var fresh = try await session(from: data)
        if fresh.login.isEmpty { fresh.login = old.login }
        if fresh.userID.isEmpty { fresh.userID = old.userID }
        if fresh.scopes == nil { fresh.scopes = old.scopes }
        return fresh
    }

    /// Renews `old` and keeps the result in `store`; nil once the login is gone,
    /// with the store cleared. Other processes renew from the same store — the
    /// Siri guess does — and a refresh token works once, so a token another one
    /// already spent comes back as what it saved rather than as a sign-out.
    public func renew(_ old: TwitchSession, keptIn store: any SessionStore) async throws -> TwitchSession? {
        func renewedElsewhere() -> TwitchSession? {
            store.load().flatMap { $0.refreshToken == old.refreshToken ? nil : $0 }
        }
        if let kept = renewedElsewhere() { return kept }
        do {
            let fresh = try await refresh(old)
            store.save(fresh)
            return fresh
        } catch is TwitchAuthError {
            if let kept = renewedElsewhere() { return kept }
            store.clear()
            return nil
        }
    }

    private struct TokenResponse: Decodable {
        var accessToken: String
        var refreshToken: String
        var expiresIn: Int
    }

    private struct Validation: Decodable {
        var login: String?
        var userId: String?
        var scopes: [String]?
    }

    /// The session a token grant names. A validate that fails leaves who it is
    /// empty rather than throwing: by then Twitch has spent the old refresh
    /// token, so losing this pair would cost the login.
    private func session(from data: Data) async throws -> TwitchSession {
        let token = try Guessr.decoder.decode(TokenResponse.self, from: data)
        var req = URLRequest(url: base.appending(path: "validate"))
        req.setValue("OAuth \(token.accessToken)", forHTTPHeaderField: "Authorization")
        let body = try? await session.settledData(for: req).0
        let who = body.flatMap { try? Guessr.decoder.decode(Validation.self, from: $0) }
        return TwitchSession(
            accessToken: token.accessToken,
            refreshToken: token.refreshToken,
            expiresAt: .now.addingTimeInterval(TimeInterval(token.expiresIn)),
            login: (who?.login ?? "").lowercased(),
            userID: who?.userId ?? "",
            scopes: who?.scopes
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
