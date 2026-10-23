import GuessrKit
import MetricKit
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
            // The OS's own hang, crash, CPU and disk-write diagnostics. They
            // are recorded by iOS outside the app, so they arrive even when
            // the run that hung was killed for it, with the stack it was
            // blocked in — which the SDK's hang tracker only guesses at.
            options.enableMetricKit = true
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
        MXMetricManager.shared.add(ExitMetrics.shared)
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

    /// The steps of a day's play, in the order a player meets them.
    enum Step: String {
        case dayLoaded = "day_loaded"
        case roundShown = "round_shown"
        case guessed
        case resultShown = "result_shown"
        case shared
    }

    /// One step of play, recorded three ways. The round it names becomes the
    /// scope's `round.*` tags, so any error or crash after it says which date,
    /// round and clip the player was on. A breadcrumb puts the step in the
    /// trail under that report. And a `game.<step>` log line, so where players
    /// stop between loading a day and sharing it can be counted from the log
    /// search. Nothing here names the player.
    static func step(_ step: Step, date: String, round: Int? = nil, clip: String? = nil, data: [String: Any] = [:]) {
        var fields = data
        fields["date"] = date
        if let round { fields["round"] = round }
        if let clip { fields["clip"] = clip }
        SentrySDK.configureScope { scope in
            scope.setTag(value: date, key: "round.date")
            if let round { scope.setTag(value: String(round), key: "round.index") }
            if let clip { scope.setTag(value: clip, key: "round.clip") }
        }
        let crumb = Breadcrumb(level: .info, category: "game")
        crumb.message = step.rawValue
        crumb.data = fields
        SentrySDK.addBreadcrumb(crumb)
        SentrySDK.logger.info("game.\(step.rawValue)", attributes: fields)
    }

    /// A URL iOS handed the app, and whether it read as a device link. Only
    /// the fragment's keys travel: its values are a player id and an alias.
    static func linkOpened(_ url: URL, via route: String, read: Bool) {
        let keys = URLComponents(string: "?" + (url.fragment ?? ""))?.queryItems?.map(\.name) ?? []
        let fields: [String: Any] = [
            "route": route, "read": read, "path": url.path(), "fragment_keys": keys.joined(separator: ","),
        ]
        let crumb = Breadcrumb(level: .info, category: "link")
        crumb.message = "opened"
        crumb.data = fields
        SentrySDK.addBreadcrumb(crumb)
        SentrySDK.logger.info("link.opened", attributes: fields)
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

    /// A request to the API that never got an answer: timed out, DNS, a
    /// dropped connection.
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
    /// can carry the URL it failed on. A device with no connection is left
    /// out: every clip and request fails on it, and none of that is a bug.
    private static func report(
        _ message: String, fingerprint: String, error: (any Error)?, tags: @escaping (Scope) -> Void
    ) {
        if let error, Guessr.isOffline(error) { return }
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

/// How the app's runs actually ended, counted by the OS and delivered about
/// once a day. Sentry's `WatchdogTermination` is inferred at the next launch
/// from "the last run ended in the foreground without a crash", which a
/// force-quit from the app switcher satisfies too; these counts are what
/// iOS itself recorded, so a memory-limit or watchdog kill shows up here or
/// did not happen.
///
/// Every payload is a log line with the full breakdown. A foreground kill
/// is also an event, so it reaches the issue list rather than only the
/// log search.
/// ponytail: the same subscriber lives in tempomat's `Telemetry.swift`; a
/// shared GuessrKit type is the upgrade if a third app wants it.
final class ExitMetrics: NSObject, MXMetricManagerSubscriber {
    static let shared = ExitMetrics()

    nonisolated func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            guard let exits = payload.applicationExitMetrics else { continue }
            let fg = exits.foregroundExitData
            let bg = exits.backgroundExitData
            let counts: [String: Int] = [
                "foreground.normal": fg.cumulativeNormalAppExitCount,
                "foreground.memory_limit": fg.cumulativeMemoryResourceLimitExitCount,
                "foreground.watchdog": fg.cumulativeAppWatchdogExitCount,
                "foreground.abnormal": fg.cumulativeAbnormalExitCount,
                "foreground.bad_access": fg.cumulativeBadAccessExitCount,
                "foreground.illegal_instruction": fg.cumulativeIllegalInstructionExitCount,
                "background.normal": bg.cumulativeNormalAppExitCount,
                "background.memory_limit": bg.cumulativeMemoryResourceLimitExitCount,
                "background.memory_pressure": bg.cumulativeMemoryPressureExitCount,
                "background.watchdog": bg.cumulativeAppWatchdogExitCount,
                "background.cpu_limit": bg.cumulativeCPUResourceLimitExitCount,
                "background.abnormal": bg.cumulativeAbnormalExitCount,
                "background.bad_access": bg.cumulativeBadAccessExitCount,
                "background.task_timeout": bg.cumulativeBackgroundTaskAssertionTimeoutExitCount,
                "background.locked_file": bg.cumulativeSuspendedWithLockedFileExitCount,
            ]
            var attributes: [String: Any] = counts
            attributes["app_version"] = payload.latestApplicationVersion
            attributes["window_start"] = payload.timeStampBegin.ISO8601Format()
            attributes["window_end"] = payload.timeStampEnd.ISO8601Format()
            SentrySDK.logger.info("App exits", attributes: attributes)

            let kills = [
                ("memory limit", fg.cumulativeMemoryResourceLimitExitCount),
                ("watchdog", fg.cumulativeAppWatchdogExitCount),
            ]
            for (reason, count) in kills where count > 0 {
                SentrySDK.capture(message: "App killed in the foreground: \(reason)") { scope in
                    scope.setLevel(.error)
                    scope.setFingerprint(["app-exit", reason])
                    scope.setTag(value: String(count), key: "exit.count")
                    scope.setTag(value: payload.latestApplicationVersion, key: "exit.app_version")
                    scope.setContext(value: attributes, key: "exits")
                }
            }
        }
    }
}
