import GuessrKit
import Sentry

/// Sentry for the app: crashes, hangs, a span per request (URLSession is
/// auto-instrumented) and structured logs. The DSN is public by nature — it
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
            // Simulator runs are development against stage, and the free tier
            // is shared with the whole fleet.
            #if targetEnvironment(simulator)
                options.enabled = false
            #endif
        }
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
}
