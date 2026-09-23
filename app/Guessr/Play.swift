import AVKit
import GuessrKit
import MapKit
import SwiftUI

/// Today's rounds: watch the clip, drop a pin, see how close it was.
struct PlayView: View {
    let player: Player

    @State private var day: GuessrDay?
    @State private var progress = DayProgress(date: "")
    @State private var pin: CLLocationCoordinate2D?
    /// The round just scored stays on screen until the player moves on.
    @State private var revealed = false
    @State private var scoring = false
    @State private var message: String?
    @State private var camera = PlayView.lower48

    private let client = GuessrClient()

    /// Every round opens on the whole playable area.
    static let lower48 = MapCameraPosition.region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 36.75, longitude: -95.5),
            span: MKCoordinateSpan(latitudeDelta: 25.5, longitudeDelta: 59)))

    var body: some View {
        Group {
            if let day {
                if revealed, let last = progress.played.last {
                    round(day, image: last.image, number: progress.played.count, shown: last)
                } else if let next = progress.next(in: day) {
                    round(day, image: next.image, number: progress.played.count + 1, shown: nil)
                } else {
                    DayResultView(progress: progress)
                }
            } else if let message {
                ContentUnavailableView(message, systemImage: "car")
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Guessr")
        .task { await load() }
    }

    private func round(_ day: GuessrDay, image: String, number: Int, shown: PlayedRound?) -> some View {
        VStack(spacing: 12) {
            ClipView(url: Guessr.baseURL.appending(path: image))
                .aspectRatio(16 / 9, contentMode: .fit)
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
        .padding()
        .navigationTitle("Round \(number) of \(day.rounds.count) · \(progress.total.formatted())")
        .navigationBarTitleDisplayMode(.inline)
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
    }

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
                Text("Come back tomorrow for five more.").foregroundStyle(.secondary)
            }
            NavigationLink("Leaderboards") { TodayView() }
        }
    }
}

/// A clip on a muted loop. No controls: a scrubber is a way to hunt for a frame
/// the round didn't mean to show.
struct ClipView: View {
    let url: URL
    @State private var player = AVQueuePlayer()
    @State private var looper: AVPlayerLooper?

    var body: some View {
        VideoPlayer(player: player)
            .allowsHitTesting(false)
            .task(id: url) {
                player.isMuted = true
                looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
                player.play()
            }
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
