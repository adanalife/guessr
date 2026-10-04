import GuessrKit
import Sentry

/// Sentry for the app: crashes, hangs, a span per request (URLSession is
/// auto-instrumented), structured logs and a replay of the moments before an
/// error. The DSN is public by nature — it
/// ships in every binary — so it lives here rather than in a secret.
enum Telemetry {
    static let dsn = "https://d4a48302e13b01a9e98a6fb639cf3598@o325224.ingest.us.sentry.io/4512139659575296"

    static func start() {
        SentrySDK.start { options in
            options.dsn = dsn
            options.environment = environment(for: Guessr.baseURL)
            options.tracesSampleRate = 1.0
            options.enableLogs = true
            // A hang report on its own says only that the main thread stopped.
            // The profiler samples it, so a hang comes with the stack it was
            // parked in; `.trace` ties the samples to the request spans, and
            // `profileAppStarts` covers the launch.
            options.configureProfiling = {
                $0.lifecycle = .trace
                $0.sessionSampleRate = 1.0
                $0.profileAppStarts = true
            }
            // Which screen was on show when it went wrong.
            options.attachViewHierarchy = true
            // And what the player did to get there: replay buffers the
            // recent screen in memory and uploads it only with an error or
            // crash, so a session that never errors costs none of the
            // fleet's shared replay quota. The SDK masks all text and images
            // by default.
            options.sessionReplay.sessionSampleRate = 0
            options.sessionReplay.onErrorSampleRate = 1.0
            // A failed request groups by status and endpoint rather than by
            // its URLSession stack, which is the same for every request.
            options.beforeSend = { event in
                if event.exceptions?.first?.mechanism?.type == "HTTPClientError",
                    let status = event.context?["response"]?["status_code"] as? Int,
                    let url = event.request?.url.flatMap(URL.init(string:))
                {
                    event.fingerprint = Guessr.httpErrorFingerprint(status: status, url: url)
                }
                return event
            }
            // Simulator runs are development against stage, and the free tier
            // is shared with the whole fleet.
            #if targetEnvironment(simulator)
                options.enabled = false
            #endif
        }
        ClipView.failed = clipFailed
    }

    /// The fleet's deploy-env ids, read off the server the build plays
    /// against, so app events sit under the same `environment` filter as the
    /// server's.
    static func environment(for base: URL) -> String {
        switch base.host() {
        case "guessr.dana.lol": "prod-1"
        case "stage.guessr.dana.lol": "stage-1"
        default: "development"
        }
    }

    /// A clip that failed to load. AVPlayer fetches outside URLSession, so the
    /// SDK's failed-request capture never sees it; this is the only report.
    /// One fingerprint for every clip, so a bad deploy reads as one issue with
    /// many events. The path names the clip and nothing about the player.
    static func clipFailed(url: URL, attempt: Int, error: (any Error)?) {
        report("Clip failed to load", fingerprint: "clip-failed", error: error) {
            $0.setTag(value: url.path(), key: "clip")
            $0.setTag(value: String(attempt), key: "attempt")
        }
    }

    /// A request to the API that never got an answer: offline, timed out, DNS.
    /// A 5xx already reaches Sentry as the SDK's `HTTPClientError` and a 4xx is
    /// the server's answer, so a `GuessrError` is left out, as is a request
    /// the player walked away from.
    static func requestFailed(_ endpoint: String, error: any Error) {
        if error is GuessrError || error is CancellationError { return }
        if (error as? URLError)?.code == .cancelled { return }
        report("Request failed", fingerprint: "request-failed-\(endpoint)", error: error) {
            $0.setTag(value: endpoint, key: "endpoint")
        }
    }

    /// A captured message rather than the error itself: the domain and code
    /// are what group and filter, and an error's own description or user info
    /// can carry the URL it failed on.
    private static func report(
        _ message: String, fingerprint: String, error: (any Error)?, tags: @escaping (Scope) -> Void
    ) {
        SentrySDK.capture(message: message) { scope in
            scope.setLevel(.error)
            scope.setFingerprint([fingerprint])
            tags(scope)
            guard let error = error as NSError? else { return }
            scope.setTag(value: error.domain, key: "error.domain")
            scope.setTag(value: String(error.code), key: "error.code")
            if let under = error.userInfo[NSUnderlyingErrorKey] as? NSError {
                scope.setTag(value: under.domain, key: "error.underlying_domain")
                scope.setTag(value: String(under.code), key: "error.underlying_code")
            }
        }
    }
}
