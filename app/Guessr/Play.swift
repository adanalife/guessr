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
    /// Compact on a phone held on its side, the one shape with no room to
    /// stack the clip over the map.
    @Environment(\.verticalSizeClass) private var heightClass

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
                    round(day, image: image, shown: shown)
                } else {
                    DayResultView(progress: progress)
                }
            } else if let message {
                ContentUnavailableView {
                    Label(message, systemImage: "car")
                } actions: {
                    Button("Retry") {
                        self.message = nil
                        Task { await load() }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .paper()
        .navigationTitle("Guessr")
        .task { await load() }
    }

    private func round(_ day: GuessrDay, image: String, shown: PlayedRound?) -> some View {
        // A fresh player per clip: a looper can't be rebuilt on a queue
        // player still holding the last clip's items.
        let clip = ClipView(
            url: Guessr.baseURL.appending(path: image), fills: sizeClass == .regular && heightClass != .compact
        ).id(image)
        return Group {
            if heightClass == .compact {
                // A phone on its side: the clip as large as the height allows,
                // the map and controls in the column beside it.
                HStack(spacing: 12) {
                    clip.aspectRatio(ClipView.aspect, contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    VStack(spacing: 8) {
                        ProgressSquares(progress: progress, of: day.rounds.count)
                        map(shown)
                        controls(day, image: image, shown: shown)
                    }
                    .frame(width: 280)
                }
                .padding(.horizontal)
            } else if sizeClass == .regular {
                // The web's wide layout: the clip is the whole screen, since
                // squinting at it is the game, and the map rides over its corner
                // until the reveal makes the map the thing worth reading.
                GeometryReader { screen in
                    ZStack(alignment: .bottomTrailing) {
                        clip.ignoresSafeArea()
                            // A scrim under the status bar, whose white text is lost
                            // over a bright sky.
                            .overlay(alignment: .top) {
                                LinearGradient(colors: [.black.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom)
                                    .frame(height: 80)
                                    .ignoresSafeArea()
                                    .allowsHitTesting(false)
                            }
                        let width = revealed ? min(screen.size.width * 0.6, 736) : 352
                        VStack(alignment: .trailing, spacing: 12) {
                            map(shown)
                                // Revealed, the map keeps its own aspect rather than
                                // growing taller than wide on a portrait screen.
                                .frame(width: width, height: revealed ? min(screen.size.height * 0.6, width * 0.66) : 240)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .shadow(color: .black.opacity(0.4), radius: 12, y: 8)
                            // Before the reveal the column is one width with the map,
                            // the squares on a capsule of their own and the pill on the
                            // clip, carrying its own contrast; the reveal gets a card.
                            VStack(spacing: 12) {
                                ProgressSquares(progress: progress, of: day.rounds.count)
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .background(.regularMaterial.opacity(shown == nil ? 1 : 0), in: Capsule())
                                controls(day, image: image, shown: shown)
                                    .shadow(color: .black.opacity(shown == nil ? 0.4 : 0), radius: 8, y: 4)
                            }
                            .padding(shown == nil ? 0 : 16)
                            .frame(maxWidth: shown == nil ? 352 : 420)
                            .background(.regularMaterial.opacity(shown == nil ? 0 : 1), in: RoundedRectangle(cornerRadius: 12))
                        }
                        .padding()
                    }
                }
            } else {
                VStack(spacing: 12) {
                    ProgressSquares(progress: progress, of: day.rounds.count)
                    clip.aspectRatio(ClipView.aspect, contentMode: .fit)
                    map(shown)
                    controls(day, image: image, shown: shown)
                }
                .padding()
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .sensoryFeedback(.selection, trigger: pin?.latitude)
        .sensoryFeedback(trigger: revealed) { _, shown in
            shown ? progress.played.last.map { Self.feedback(for: $0.score.points) } : nil
        }
    }

    /// A reveal lands as hard as it scored: a success for a square the share
    /// string turns green or better, a thud that softens down the bands below.
    static func feedback(for points: Int) -> SensoryFeedback {
        switch points {
        case 4000...: .success
        case 2500...: .impact(weight: .heavy)
        case 1000...: .impact(weight: .medium)
        default: .impact(weight: .light)
        }
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
            .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
            .background(Color.paper)
        }
    }

    private func controls(_ day: GuessrDay, image: String, shown: PlayedRound?) -> some View {
        VStack(spacing: 12) {
            if let shown {
                RevealCard(round: shown)
            } else if let message {
                Text(message).font(.callout).multilineTextAlignment(.center)
            }
            button(day, image: image)
                .inkButton()
        }
    }

    @ViewBuilder
    private func button(_ day: GuessrDay, image: String) -> some View {
        if revealed {
            Button(progress.next(in: day) == nil ? "Show score screen" : "Next round") {
                (revealed, pin, message, camera) = (false, nil, nil, PlayView.lower48)
            }
        } else {
            Button(scoring ? "Scoring…" : pin == nil ? "Place a pin on the map to guess" : "Guess") {
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

/// The finished day: every round, the total, and the text to share it.
struct DayResultView: View {
    let progress: DayProgress
    @State private var copied = false
    /// The round whose clip is playing again, by image: a map pin's selection
    /// tag and a row's tap both set it.
    @State private var replaying: String?

    static var nextDaily: Date {
        Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: .now)) ?? .now
    }

    var body: some View {
        List {
            Section {
                Map(selection: $replaying) {
                    ForEach(Array(progress.played.enumerated()), id: \.offset) { i, r in
                        Marker("\(i + 1)", coordinate: r.score.answer.location).tint(.green).tag(r.image)
                        MapPolyline(coordinates: [r.guess.location, r.score.answer.location])
                            .stroke(.green, style: StrokeStyle(lineWidth: 2, dash: [5, 6]))
                        Annotation("", coordinate: r.guess.location, anchor: .center) {
                            Circle().fill(Color.ink).frame(width: 8, height: 8)
                        }
                    }
                }
                .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
                .background(Color.paper)
                .frame(height: 280)
                .listRowInsets(EdgeInsets())
            }
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("You have completed today's game").font(.caption).foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(progress.total.formatted())
                            .font(.system(size: 44, weight: .bold, design: .serif))
                            .monospacedDigit()
                        Text("/ \((progress.played.count * 5000).formatted())").foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        ForEach(Array(progress.played.enumerated()), id: \.offset) { _, r in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.band(for: r.score.points))
                                .frame(width: 16, height: 16)
                        }
                    }
                }
            }
            Section {
                // The date is the replay sheet's to show; a row holds to one line.
                ForEach(Array(progress.played.enumerated()), id: \.offset) { i, r in
                    Button {
                        replaying = r.image
                    } label: {
                        LabeledContent {
                            Text("\(r.score.miles.formatted()) mi · \(r.score.points.formatted())").layoutPriority(1)
                        } label: {
                            Text("\(i + 1). \(r.score.state)")
                        }
                    }
                    .foregroundStyle(Color.ink)
                }
            }
            Section {
                if let text = progress.shareText() {
                    Button(copied ? "Copied" : "Copy share text", systemImage: copied ? "checkmark" : "doc.on.doc") {
                        UIPasteboard.general.string = text
                        copied = true
                    }
                }
                // The next date opens at the player's own midnight, the day
                // `GuessrClient.today()` turns over; a relative Text keeps counting.
                Text("Come back in \(Text(Self.nextDaily, style: .relative)) for five more.")
                    .foregroundStyle(.secondary)
            }
        }
        .readableWidth()
        .paper()
        .sheet(isPresented: Binding(get: { replaying != nil }, set: { if !$0 { replaying = nil } })) {
            if let round = progress.played.first(where: { $0.image == replaying }) {
                ReplayView(round: round)
            }
        }
    }
}

/// One played round's clip again, with where it was and how the guess did.
private struct ReplayView: View {
    let round: PlayedRound

    var body: some View {
        VStack(spacing: 12) {
            ClipView(url: Guessr.baseURL.appending(path: round.image)).aspectRatio(ClipView.aspect, contentMode: .fit)
            Text(
                "**\(round.score.state)**, \(round.score.filmed) — off by **\(round.score.miles.formatted()) mi** for **\(round.score.points.formatted())** points."
            )
            .font(.system(.callout, design: .serif))
            .multilineTextAlignment(.center)
        }
        .padding()
        .presentationDetents([.medium, .large])
        .paper()
    }
}

/// A clip on a muted loop. No scrubber: a scrubber is a way to hunt for a
/// frame the round didn't mean to show. A pinch zooms in and a drag pans the
/// zoomed picture, a tap pauses it, and a double tap zooms back out. `fills`
/// crops it to cover its frame rather than letterboxing inside it.
struct ClipView: View {
    /// Every clip's shape: 1280 wide with the dashcam HUD cropped off the
    /// bottom. A frame of this shape leaves nothing to letterbox.
    static let aspect = 1280.0 / 674.0

    let url: URL
    var fills = false
    @State private var player = AVQueuePlayer()
    @State private var looper: AVPlayerLooper?
    @State private var paused = false
    /// The zoom between gestures, and the one a gesture in progress shows.
    @State private var zoom = ClipZoom()
    @State private var live: ClipZoom?

    var body: some View {
        GeometryReader { geo in
            let shown = live ?? zoom
            PlayerLayer(player: player, gravity: fills ? .resizeAspectFill : .resizeAspect)
                .allowsHitTesting(false)
                .scaleEffect(shown.scale)
                .offset(x: shown.x, y: shown.y)
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
                .contentShape(Rectangle())
                .gesture(pinch(geo.size))
                .gesture(pan(geo.size), isEnabled: zoom.scale > 1)
                .onTapGesture(count: 2) { withAnimation { zoom = ClipZoom() } }
                .onTapGesture { togglePause() }
                .overlay {
                    if paused {
                        Image(systemName: "pause.circle.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.white.opacity(0.8))
                            .allowsHitTesting(false)
                    }
                }
        }
        .accessibilityElement()
        .accessibilityLabel(paused ? "Clip, paused" : "Clip")
        .accessibilityAction(named: paused ? "Play" : "Pause") { togglePause() }
        // A tab switch runs this again on the way back, and a second looper on
        // a player still holding the first one's items leaves it with nothing
        // to play: the looper is built once, and each appearance only resumes.
        .onAppear {
            if looper == nil {
                player.isMuted = true
                looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            }
            if !paused { player.play() }
        }
        .onDisappear { player.pause() }
    }

    private func togglePause() {
        paused.toggle()
        if paused { player.pause() } else { player.play() }
    }

    private func pinch(_ size: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                live = zoom.zoomed(
                    by: value.magnification,
                    aboutX: value.startLocation.x - size.width / 2, y: value.startLocation.y - size.height / 2,
                    width: size.width, height: size.height)
            }
            .onEnded { _ in
                zoom = live ?? zoom
                live = nil
            }
    }

    private func pan(_ size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                live = zoom.panned(
                    dx: value.translation.width, dy: value.translation.height, width: size.width, height: size.height)
            }
            .onEnded { _ in
                zoom = live ?? zoom
                live = nil
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
        // Seen only until the first frame: a shade off the page, so the slot
        // reads as a clip on its way rather than a hole in the paper.
        view.backgroundColor = UIColor(Color.ink.opacity(0.08))
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

extension Color {
    /// The share string's square for a score, as a color: the one language
    /// the reveal, the day result and the share text all speak.
    static func band(for points: Int) -> Color {
        switch Share.square(for: points) {
        case "🏆": .yellow
        case "🟩": .green
        case "🟨": .yellow
        case "🟧": .orange
        default: .gray
        }
    }
}

/// Five squares that fill in band color as the day is played, with the running
/// total beside them. The current round is outlined in ink. Until the day's
/// first round scores, the row asks the question instead, since empty squares
/// and a zero mean nothing to a first-time player.
struct ProgressSquares: View {
    let progress: DayProgress
    let of: Int

    var body: some View {
        Group {
            if progress.played.isEmpty {
                Text("Where was this dashcam clip taken?")
                    .font(.system(.title3, design: .serif, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            } else {
                HStack(spacing: 6) {
                    ForEach(0..<of, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(i < progress.played.count ? Color.band(for: progress.played[i].score.points) : .clear)
                            .strokeBorder(i == progress.played.count ? Color.ink : Color.secondary.opacity(0.4), lineWidth: 1.5)
                            .frame(width: 16, height: 16)
                    }
                    Spacer()
                    Text(progress.total.formatted())
                        .font(.system(.title3, design: .serif, weight: .semibold))
                        .monospacedDigit()
                }
                .transition(.opacity)
            }
        }
        .animation(.default, value: progress.played.isEmpty)
    }
}

/// The reveal: the points as the headline, the place under them, painted in the
/// round's band color so the score reads before the number does. Only orange
/// and up are painted: a grey round keeps a plain outline, so color on the card
/// always means a good round.
struct RevealCard: View {
    let round: PlayedRound
    /// The points roll up from zero as the reveal's haptic lands.
    @State private var counted = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let band = Share.square(for: round.score.points) == "⬜" ? nil : Color.band(for: round.score.points)
        VStack(spacing: 2) {
            CountUp(value: counted)
                .font(.system(size: 44, weight: .bold, design: .serif))
                .monospacedDigit()
                .accessibilityLabel(round.score.points.formatted())
            Text("points").font(.caption).textCase(.uppercase).foregroundStyle(.secondary)
            Text(round.score.state)
                .font(.system(.title2, design: .serif, weight: .semibold))
                .padding(.top, 6)
            Text("\(round.score.miles.formatted()) mi away · \(round.score.filmed)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background((band ?? .clear).opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(band ?? Color.secondary.opacity(0.4), lineWidth: 2))
        .onAppear {
            let points = Double(round.score.points)
            if reduceMotion { counted = points } else { withAnimation(.easeOut(duration: 0.8)) { counted = points } }
        }
    }
}

/// A number SwiftUI interpolates frame by frame, so an animated change counts
/// through every value on the way.
private struct CountUp: View, Animatable {
    var value: Double
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View { Text(Int(value.rounded()).formatted()) }
}
