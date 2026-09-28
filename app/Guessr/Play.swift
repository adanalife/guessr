import AVFoundation
import GuessrKit
import MapKit
import SwiftUI

/// Today's rounds: watch the clip, drop a pin, see how close it was.
struct PlayView: View {
    @Binding var player: Player

    @State private var day: GuessrDay?
    @State private var progress = DayProgress(date: "")
    @State private var pin: CLLocationCoordinate2D?
    /// The round just scored stays on screen until the player moves on.
    @State private var revealed = false
    @State private var scoring = false
    @State private var message: String?
    @State private var camera = PlayView.lower48
    @Environment(\.horizontalSizeClass) private var sizeClass

    private let client = GuessrClient()

    /// Every round opens on the whole playable area.
    static let lower48 = MapCameraPosition.region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 36.75, longitude: -95.5),
            span: MKCoordinateSpan(latitudeDelta: 25.5, longitudeDelta: 59)))

    var body: some View {
        Group {
            if let day {
                // One call site for the round and its reveal, so the clip and map
                // stay the same views across a guess rather than reloading.
                let shown = revealed ? progress.played.last : nil
                if let image = shown?.image ?? progress.next(in: day)?.image {
                    round(day, image: image, number: progress.played.count + (shown == nil ? 1 : 0), shown: shown)
                } else {
                    DayResultView(progress: progress)
                }
            } else if let message {
                ContentUnavailableView(message, systemImage: "car")
            } else {
                ProgressView()
            }
        }
        .paper()
        .navigationTitle("Guessr")
        .task { await load() }
    }

    private func round(_ day: GuessrDay, image: String, number: Int, shown: PlayedRound?) -> some View {
        // A fresh player per clip: a looper can't be rebuilt on a queue
        // player still holding the last clip's items.
        let clip = ClipView(url: Guessr.baseURL.appending(path: image), fills: sizeClass == .regular).id(image)
        return Group {
            if sizeClass == .regular {
                // The web's wide layout: the clip is the whole screen, since
                // squinting at it is the game, and the map rides over its corner
                // until the reveal makes the map the thing worth reading.
                GeometryReader { screen in
                    ZStack(alignment: .bottomTrailing) {
                        clip.ignoresSafeArea()
                        VStack(alignment: .trailing, spacing: 12) {
                            map(shown)
                                .frame(
                                    width: revealed ? min(screen.size.width * 0.6, 736) : 352,
                                    height: revealed ? screen.size.height * 0.6 : 240
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .shadow(color: .black.opacity(0.4), radius: 12, y: 8)
                            controls(day, image: image, shown: shown)
                                .padding()
                                .frame(maxWidth: 420)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        }
                        .padding()
                    }
                }
            } else {
                VStack(spacing: 12) {
                    clip.aspectRatio(16 / 9, contentMode: .fit)
                    map(shown)
                    controls(day, image: image, shown: shown)
                }
                .padding()
            }
        }
        .navigationTitle("Round \(number) of \(day.rounds.count) · \(progress.total.formatted())")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func map(_ shown: PlayedRound?) -> some View {
        MapReader { proxy in
            Map(position: $camera) {
                if let pin { Marker("Your guess", coordinate: pin) }
                if let shown {
                    Marker(shown.score.state, coordinate: shown.score.answer.location).tint(.green)
                    MapPolyline(coordinates: [shown.guess.location, shown.score.answer.location])
                        .stroke(.green, style: StrokeStyle(lineWidth: 2, dash: [5, 6]))
                }
            }
            .onTapGesture { point in
                guard !revealed, !scoring, let at = proxy.convert(point, from: .local) else { return }
                pin = at
            }
        }
    }

    private func controls(_ day: GuessrDay, image: String, shown: PlayedRound?) -> some View {
        VStack(spacing: 12) {
            Group {
                if let shown {
                    Text(
                        "**\(shown.score.state)**, \(shown.score.filmed) — you were off by **\(shown.score.miles.formatted()) mi** for **\(shown.score.points.formatted())** points."
                    )
                } else if let message {
                    Text(message)
                } else {
                    Text("Somewhere in the United States. Where?")
                }
            }
            .font(.callout)
            .multilineTextAlignment(.center)
            button(day, image: image)
                .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private func button(_ day: GuessrDay, image: String) -> some View {
        if revealed {
            Button(progress.next(in: day) == nil ? "See the day" : "Next round") {
                (revealed, pin, message, camera) = (false, nil, nil, PlayView.lower48)
            }
        } else {
            Button(scoring ? "Scoring…" : pin == nil ? "Drop a pin to guess" : "Guess") {
                Task { await guess(image) }
            }
            .disabled(pin == nil || scoring)
        }
    }

    private func load() async {
        let date = GuessrClient.today()
        progress = DayProgress.resume(Saved.progress, on: date)
        do {
            day = try await client.day(date)
        } catch {
            // The server says why — nothing scheduled, or a date not yet open.
            message = (error as? GuessrError)?.errorDescription ?? "Could not reach the rounds"
        }
        #if DEBUG
            await autoplay()
        #endif
    }

    #if DEBUG
        /// `-autoplay 1` plays the rest of the day unattended, pausing on each
        /// round and each reveal long enough to screenshot it.
        private func autoplay() async {
            guard UserDefaults.standard.bool(forKey: "autoplay"), let day else { return }
            while let next = progress.next(in: day) {
                try? await Task.sleep(for: .seconds(5))
                pin = CLLocationCoordinate2D(latitude: 39.74, longitude: -104.99)
                await guess(next.image)
                guard revealed else { return }
                try? await Task.sleep(for: .seconds(6))
                (revealed, pin, message, camera) = (false, nil, nil, PlayView.lower48)
            }
        }
    #endif

    private func guess(_ image: String) async {
        guard let pin else { return }
        scoring = true
        defer { scoring = false }
        let at = Coordinate(lat: pin.latitude, lng: pin.longitude)
        do {
            // A round this player already guessed comes back with the score on
            // record, so a lost save cannot buy a better one.
            let score = try await client.score(image: image, guess: at, date: progress.date, player: player)
            progress.played.append(PlayedRound(image: image, guess: at, score: score))
            Saved.progress = progress
            if progress.played.count == 1 { await Reminder.refreshBadge() }
            (revealed, message, camera) = (true, nil, .automatic)
        } catch let error as GuessrError where error.isFinal {
            // Refused, so retrying gets the same answer: say what the server said.
            day = nil
            message = error.localizedDescription
        } catch {
            message = "Could not reach the scorer. Try that guess again."
        }
    }
}

/// Joins the player on another device by the code it shows under About → Link
/// a device. This device's plays fold onto that player, and it plays as them
/// from here on, keeping its own name.
struct JoinView: View {
    @Binding var player: Player
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var joining = false
    @State private var message: String?

    private let client = GuessrClient()

    var body: some View {
        Form {
            Section {
                TextField("Code", text: $code)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.title3.monospaced())
                Button(joining ? "Joining…" : "Join") { Task { await join() } }
                    .disabled(code.isEmpty || joining)
            } footer: {
                Text(message ?? "On the web, open About and tap Link a device to see a code. It lasts ten minutes.")
            }
        }
        .paper()
        .navigationTitle("Enter your code")
    }

    private func join() async {
        joining = true
        defer { joining = false }
        do {
            let claim = try await client.claimLink(code: code, from: player)
            player = Player(id: claim.playerId, alias: player.alias)
            dismiss()
        } catch let error as GuessrError where error.isFinal {
            message = "That code is unknown or has expired. Show a new one on the web."
        } catch {
            message = "Could not reach the server. Try the code again."
        }
    }
}

/// The finished day: every round, the total, and the way to the boards.
struct DayResultView: View {
    let progress: DayProgress

    var body: some View {
        List {
            Section {
                Map {
                    ForEach(Array(progress.played.enumerated()), id: \.offset) { i, r in
                        Marker("\(i + 1)", coordinate: r.score.answer.location).tint(.green)
                        MapPolyline(coordinates: [r.guess.location, r.score.answer.location])
                            .stroke(.green, style: StrokeStyle(lineWidth: 2, dash: [5, 6]))
                    }
                }
                .frame(height: 280)
                .listRowInsets(EdgeInsets())
            }
            Section("Today's round is done") {
                ForEach(Array(progress.played.enumerated()), id: \.offset) { i, r in
                    LabeledContent(
                        "\(i + 1). \(r.score.state), \(r.score.filmed)",
                        value: "\(r.score.miles.formatted()) mi · \(r.score.points.formatted())")
                }
                LabeledContent(
                    "Total",
                    value: "\(progress.total.formatted()) / \((progress.played.count * 5000).formatted())")
                if let text = progress.shareText() {
                    ShareLink(item: text) { Label("Share", systemImage: "square.and.arrow.up") }
                }
                Text("Come back tomorrow for five more.").foregroundStyle(.secondary)
            }
            NavigationLink("Leaderboards") { TodayView() }
        }
        .paper()
    }
}

/// A clip on a muted loop. No controls: a scrubber is a way to hunt for a frame
/// the round didn't mean to show. `fills` crops it to cover its frame rather
/// than letterboxing inside it.
struct ClipView: View {
    let url: URL
    var fills = false
    @State private var player = AVQueuePlayer()
    @State private var looper: AVPlayerLooper?

    var body: some View {
        PlayerLayer(player: player, gravity: fills ? .resizeAspectFill : .resizeAspect)
            .allowsHitTesting(false)
            .task(id: url) {
                player.isMuted = true
                looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
                player.play()
            }
    }
}

/// A bare player layer: `VideoPlayer` has no say over how the picture fits.
private struct PlayerLayer: UIViewRepresentable {
    let player: AVPlayer
    let gravity: AVLayerVideoGravity

    final class View: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> View {
        let view = View()
        view.backgroundColor = .black
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: View, context: Context) {
        view.playerLayer.videoGravity = gravity
    }
}

/// The day in progress, kept so a relaunch resumes it. Not a credential, so
/// defaults rather than the Keychain.
enum Saved {
    private static let key = "guessr-daily"

    static var progress: DayProgress? {
        get { UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(DayProgress.self, from: $0) } }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key) }
    }
}

extension Coordinate {
    var location: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lng) }
}
