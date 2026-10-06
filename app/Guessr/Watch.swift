import AVFoundation
import GuessrKit
import SwiftUI
import WebKit

/// The stream, live, on the platform it goes out on — Twitch or YouTube, the
/// viewer's pick, kept — with the channel's chat under it for a signed-in
/// login.
///
/// A web view and not a player: neither platform publishes a native way in.
/// The page is the site's own `watch.html`, because Twitch's player renders
/// only inside a page whose hostname it was told, and an app has none.
struct WatchTab: View {
    @Environment(Account.self) private var account
    @AppStorage("watch-platform") private var platform = "twitch"
    /// Made on appearance and dropped on leaving, so a stream never decodes
    /// behind another tab.
    @State private var page: WebPage?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Above the player, not below: a scrolling view against the
                // top safe-area edge gets stretched up under the bars, and
                // the web view counts as one.
                Picker("Platform", selection: $platform) {
                    Text(verbatim: "Twitch").tag("twitch")
                    Text(verbatim: "YouTube").tag("youtube")
                }
                .pickerStyle(.segmented)
                .padding()
                Group {
                    if let page { WebView(page) } else { Color.black }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: .infinity)
                if account.showsChat { ChatPane() } else { Spacer() }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Link(destination: outside) {
                        Label("Open in \(platform == "twitch" ? "Twitch" : "YouTube")", systemImage: "arrow.up.right.square")
                    }
                }
            }
            .viewingAsBanner()
            .paper()
            .navigationTitle("Watch")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { open() }
            .onDisappear { close() }
            .onChange(of: platform) { open() }
        }
    }

    private var url: URL {
        // Pages serves `watch.html` at `/watch`, and redirects the long form.
        var url = Guessr.baseURL.appending(path: "watch")
        url.append(queryItems: [
            URLQueryItem(name: "platform", value: platform),
            URLQueryItem(name: "channel", value: account.channel),
        ])
        return url
    }

    /// The same stream in the platform's own app or site.
    private var outside: URL {
        platform == "twitch"
            ? URL(string: "https://www.twitch.tv/\(account.channel)")!
            : URL(string: "https://youtube.com/@adanalife_/live")!
    }

    private func open() {
        // Playback, or the silent switch mutes the page's audio.
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        var configuration = WebPage.Configuration()
        // ponytail: there is no autoplay-without-a-tap knob here, so the
        // viewer taps play once and gets sound for it. A WKWebView wrapper
        // with an empty mediaTypesRequiringUserActionForPlayback if that
        // tap grates.
        configuration.mediaPlaybackBehavior = .allowsInlinePlayback
        let fresh = WebPage(configuration: configuration, navigationDecider: OnlyThePlayer(host: url.host()))
        _ = fresh.load(URLRequest(url: url))
        page = fresh
    }

    private func close() {
        page = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// Keeps the web view on the one page: a tap in the player that would leave
/// for twitch.tv or youtube.com goes nowhere, so the app never browses the
/// web, which is what the store's "unrestricted web access" rating asks.
/// Frames inside the page load whatever the player needs.
private struct OnlyThePlayer: WebPage.NavigationDeciding {
    let host: String?

    func decidePolicy(for action: WebPage.NavigationAction, preferences: inout WebPage.NavigationPreferences) async -> WKNavigationActionPolicy {
        guard action.target?.isMainFrame ?? true else { return .allow }
        return action.request.url?.host() == host ? .allow : .cancel
    }
}
