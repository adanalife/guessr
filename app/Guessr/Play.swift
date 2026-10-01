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
    /// The state under the pin, for the button's `!guess <state>` callback.
    @State private var pinState: String?
    /// The round just scored stays on screen until the player moves on.
    @State private var revealed = false
    @State private var scoring = false
    @State private var message: String?
    @State private var camera = PlayView.lower48
    /// Where the map is looking, whoever moved it last: the zoom buttons scale it.
    @State private var region: MKCoordinateRegion?
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// Compact on a phone held on its side, the one shape with no room to
    /// stack the clip over the map.
    @Environment(\.verticalSizeClass) private var heightClass
    @Environment(GameCenter.self) private var gameCenter

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
        // Keyed on the player: a link to another device's player is a new
        // record to resume from.
        .task(id: player.id) { await load() }
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
                                // growing taller than wide on a portrait screen, and
                                // yields height to the card so a landscape screen
                                // still shows the whole column.
                                .frame(width: width)
                                .frame(maxHeight: revealed ? min(screen.size.height * 0.6, width * 0.66) : 240)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .shadow(color: .black.opacity(0.4), radius: 12, y: 8)
                                .layoutPriority(-1)
                            // Before the reveal the column is one width with the map,
                            // the squares on a capsule of their own and the pill on the
                            // clip, carrying its own contrast; the reveal gets a card.
                            // Either way it shares the map's edges.
                            VStack(spacing: 12) {
                                ProgressSquares(progress: progress, of: day.rounds.count)
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .background(.regularMaterial.opacity(shown == nil ? 1 : 0), in: Capsule())
                                controls(day, image: image, shown: shown)
                                    .shadow(color: .black.opacity(shown == nil ? 0.4 : 0), radius: 8, y: 4)
                            }
                            .padding(shown == nil ? 0 : 16)
                            .frame(maxWidth: width)
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
                    // Titled for VoiceOver, with no label on the map to crowd a near miss.
                    Marker(shown.score.state, coordinate: shown.score.answer.location).tint(.green)
                        .annotationTitles(.hidden)
                    MapPolyline(coordinates: [shown.guess.location, shown.score.answer.location])
                        .stroke(.green, style: StrokeStyle(lineWidth: 2, dash: [5, 6]))
                }
            }
            .onTapGesture { point in
                guard !revealed, !scoring, let at = proxy.convert(point, from: .local) else { return }
                pin = at
            }
            .onMapCameraChange { region = $0.region }
            .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
            .background(Color.paper)
            .overlay(alignment: .bottomTrailing) {
                VStack(spacing: 0) {
                    Button { zoom(by: 0.5) } label: {
                        Image(systemName: "plus").frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .accessibilityLabel("Zoom in")
                    Divider()
                    Button { zoom(by: 2) } label: {
                        Image(systemName: "minus").frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .accessibilityLabel("Zoom out")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.ink)
                .fixedSize()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding(8)
            }
        }
    }

    private func zoom(by factor: Double) {
        guard let region else { return }
        let span = MKCoordinateSpan(
            latitudeDelta: min(region.span.latitudeDelta * factor, 90),
            longitudeDelta: min(region.span.longitudeDelta * factor, 180))
        withAnimation { camera = .region(MKCoordinateRegion(center: region.center, span: span)) }
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
            Button(guessTitle) { Task { await guess(image) } }
            .disabled(pin == nil || scoring)
            // A new pin cancels the last lookup; until one answers, or outside
            // the US, the button says plain "Guess". ponytail: CLGeocoder is
            // deprecated in iOS 26, but MKReverseGeocodingRequest's addresses
            // carry a city and a country and no state field to read.
            .task(id: pin.map { [$0.latitude, $0.longitude] }) {
                pinState = nil
                guard let pin else { return }
                let placemark = try? await CLGeocoder()
                    .reverseGeocodeLocation(CLLocation(latitude: pin.latitude, longitude: pin.longitude)).first
                guard !Task.isCancelled, placemark?.isoCountryCode == "US", let area = placemark?.administrativeArea
                else { return }
                pinState = (USState.abbreviations[area] ?? USState(rawValue: area))?.localizedName
            }
        }
    }

    /// The guess button's label: what to do, then the state under the pin.
    private var guessTitle: LocalizedStringKey {
        if scoring { return "Scoring…" }
        if pin == nil { return "Place a pin on the map to guess" }
        if let pinState { return "Guess \(pinState)" }
        return "Guess"
    }

    private func load() async {
        let date = GuessrClient.today()
        progress = DayProgress.resume(Saved.progress, on: date)
        do {
            let loaded = try await client.day(date)
            day = loaded
            // A day begun on another device, or under a player this one just
            // joined, carries on from where it got to. Best effort: a miss here
            // only means starting from what this device remembers.
            if progress.played.count < loaded.rounds.count,
                let recorded = try? await client.progress(on: date, for: player)
            {
                progress = progress.seeded(from: recorded, in: loaded)
                Saved.progress = progress
            }
        } catch {
            // The server says why — nothing scheduled, or a date not yet open.
            message = (error as? GuessrError)?.errorDescription ?? String(localized: "Could not reach the rounds")
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

    /// The reveal's view: both pins with room around them, and never closer
    /// than a few degrees, so a near miss still shows where it was.
    static func fit(_ a: Coordinate, _ b: Coordinate) -> MKCoordinateRegion {
        let span = max(abs(a.lat - b.lat), abs(a.lng - b.lng), 2) * 1.8
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (a.lat + b.lat) / 2, longitude: (a.lng + b.lng) / 2),
            span: MKCoordinateSpan(latitudeDelta: min(span, 90), longitudeDelta: min(span, 180)))
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
            if progress.played.count == 1 { await Reminder.refreshBadge() }
            // Off the reveal's path: the server reads the standing off its
            // own table, so this carries nothing the reveal waits on.
            if score.recorded { Task { await gameCenter.sync(player, with: client) } }
            (revealed, message, camera) = (true, nil, .region(Self.fit(at, score.answer)))
        } catch let error as GuessrError where error.isFinal {
            // Refused, so retrying gets the same answer: say what the server said.
            day = nil
            message = error.localizedDescription
        } catch {
            message = String(localized: "Could not reach the scorer. Try that guess again.")
        }
    }
}

/// Joins the player on another device by the code it shows under About → Link
/// a device. This device's plays fold onto that player, and it plays as them
/// from here on, keeping its own name. The code is looked up first, so the
/// question names who this device is about to become.
struct JoinView: View {
    @Binding var player: Player
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var joining = false
    @State private var message: String?
    @State private var preview: LinkPreview?

    private let client = GuessrClient()

    var body: some View {
        Form {
            Section {
                TextField("Code", text: $code)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.title3.monospaced())
                Button(joining ? "Joining…" : "Join") { Task { await look() } }
                    .disabled(code.isEmpty || joining)
            } footer: {
                if let message { Text(message) } else { Text("On the web, open About and tap Link a device to see a code.") }
            }
        }
        .paper()
        .navigationTitle("Enter your code")
        .confirmationDialog(
            preview.map { Text("Play as \($0.to.name)?") } ?? Text(verbatim: ""), isPresented: Binding(get: { preview != nil }, set: { if !$0 { preview = nil } }),
            titleVisibility: .visible, presenting: preview
        ) { _ in
            Button("Join") { Task { await join() } }
        } message: { p in
            Text("This device becomes \(p.to.name) (\(p.to.points.formatted()) points), replacing \(p.from.name) (\(p.from.points.formatted()) points). Its plays go with it.")
        }
    }

    private func look() async {
        joining = true
        defer { joining = false }
        do {
            preview = try await client.previewLink(code: code, from: player)
        } catch {
            fail(error)
        }
    }

    private func join() async {
        joining = true
        defer { joining = false }
        do {
            let claim = try await client.claimLink(code: code, from: player)
            player = Player(id: claim.playerId, alias: player.alias)
            dismiss()
        } catch {
            fail(error)
        }
    }

    private func fail(_ error: Error) {
        if let error = error as? GuessrError, error.isFinal {
            message = String(localized: "That code is unknown or has expired. Show a new one on the web.")
        } else {
            message = String(localized: "Could not reach the server. Try the code again.")
        }
    }
}

/// The finished day: every round on the map, the total, and the text to share it.
struct DayResultView: View {
    let progress: DayProgress
    @State private var copied = false
    /// The round whose clip is playing again, by image: a map pin's selection
    /// tag sets it.
    @State private var replaying: String?

    static var nextDaily: Date {
        Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: .now)) ?? .now
    }

    /// "Play again in 6 h, 10 min", dropping the hours in the last one.
    static func playAgain(from now: Date) -> String {
        let left = Calendar.current.dateComponents([.hour, .minute], from: now, to: nextDaily)
        let (h, m) = (left.hour ?? 0, left.minute ?? 0)
        return h > 0 ? String(localized: "Play again in \(h) h, \(m) min") : String(localized: "Play again in \(m) min")
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
                if let text = progress.shareText() {
                    Button(copied ? "Copied" : "Copy share text", systemImage: copied ? "checkmark" : "doc.on.doc") {
                        UIPasteboard.general.string = text
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            copied = false
                        }
                    }
                }
                // The next date opens at the player's own midnight, the day
                // `GuessrClient.today()` turns over; the timeline recounts each minute.
                TimelineView(.everyMinute) { context in
                    Text(Self.playAgain(from: context.date)).foregroundStyle(.secondary)
                }
            }
        }
        .readableWidth(title: "Guessr")
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
    /// The content's own height, so the sheet stops where the sentence does.
    @State private var height: CGFloat = 320
    @AppStorage("kilometers") private var kilometers = false

    var body: some View {
        VStack(spacing: 12) {
            ClipView(url: Guessr.baseURL.appending(path: round.image)).aspectRatio(ClipView.aspect, contentMode: .fit)
            Text(
                "**\(round.score.state)**, \(round.score.filmed). Off by **\(round.score.distance(kilometers: kilometers))** for **\(round.score.points.formatted())** points."
            )
            .font(.system(.callout, design: .serif))
            .multilineTextAlignment(.center)
        }
        .padding()
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .presentationDetents([.height(height)])
        .presentationBackground(Color.paper)
    }
}

/// A clip on a muted loop. No scrubber: a scrubber is a way to hunt for a
/// frame the round didn't mean to show. A pinch zooms in and a drag pans the
/// zoomed picture, a tap pauses it and names the other gestures for a moment,
/// and a double tap opens it full screen, or closes the full screen, zoomed
/// back out. `fills` crops it to cover its frame rather than letterboxing
/// inside it.
struct ClipView: View {
    /// Every clip's shape: 1280 wide with the dashcam HUD cropped off the
    /// bottom. A frame of this shape leaves nothing to letterbox.
    static let aspect = 1280.0 / 674.0

    let url: URL
    var fills = false
    @State private var player = AVQueuePlayer()
    @State private var looper: AVPlayerLooper?
    @State private var paused = false
    @State private var hint = false
    /// The zoom between gestures, and the one a gesture in progress shows.
    @State private var zoom = ClipZoom()
    @State private var live: ClipZoom?
    /// Full screen is the same player and gestures on a cover of their own,
    /// so the loop carries on across the switch rather than restarting.
    @State private var full = false

    var body: some View {
        surface(fills: fills)
            .accessibilityElement()
            .accessibilityLabel(paused ? "Clip, paused" : "Clip")
            .accessibilityAction(named: paused ? "Play" : "Pause") { togglePause() }
            .accessibilityAction(named: "Full screen") { toggleFull() }
            .fullScreenCover(isPresented: $full, onDismiss: { zoom = ClipZoom() }) {
                // The whole screen is the frame, so a pinch can grow the clip
                // past its own shape until it fills the screen.
                surface(fills: false, screen: true)
                    .ignoresSafeArea()
                    .overlay(alignment: .topTrailing) {
                        Button("Close", systemImage: "xmark") { full = false }
                            .labelStyle(.iconOnly)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Color.ink)
                            .frame(width: 44, height: 44)
                            .background(.regularMaterial, in: Circle())
                            .padding()
                    }
                    .paper()
                    .statusBarHidden()
                    .accessibilityElement(children: .contain)
                    .accessibilityAction(.escape) { full = false }
            }
            // A tab switch runs this again on the way back, and a second looper on
            // a player still holding the first one's items leaves it with nothing
            // to play: the looper is built once, and each appearance only resumes.
            .onAppear {
                if looper == nil {
                    player.isMuted = true
                    looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
                }
                if !paused { player.play() }
                #if DEBUG
                    // `-fullscreen 1` opens the cover on launch, so it can be
                    // screenshotted from the shell.
                    if UserDefaults.standard.bool(forKey: "fullscreen") { full = true }
                    // `-zoom 4` opens the clip zoomed by that much.
                    let scale = UserDefaults.standard.double(forKey: "zoom")
                    if scale > 1 { zoom = ClipZoom(scale: min(scale, ClipZoom.maxScale)) }
                #endif
            }
            // The cover hides this view without ending the clip.
            .onDisappear { if !full { player.pause() } }
    }

    /// The clip and its gestures. `screen` is the full-screen cover's: the
    /// frame is the screen, the clip fitted inside it on the bare page.
    private func surface(fills: Bool, screen: Bool = false) -> some View {
        GeometryReader { geo in
            let shown = live ?? zoom
            let aspect = screen ? ClipView.aspect : nil
            PlayerLayer(player: player, gravity: fills ? .resizeAspectFill : .resizeAspect, placeholder: !screen)
                .allowsHitTesting(false)
                .scaleEffect(shown.scale)
                .offset(x: shown.x, y: shown.y)
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
                .contentShape(Rectangle())
                .gesture(pinch(geo.size, aspect: aspect))
                .gesture(pan(geo.size, aspect: aspect), isEnabled: zoom.scale > 1)
                .onTapGesture(count: 2) { toggleFull() }
                .onTapGesture {
                    togglePause()
                    withAnimation { hint = true }
                }
                .overlay {
                    if paused {
                        Image(systemName: "pause.circle.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.white.opacity(0.8))
                            .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .bottom) {
                    if hint {
                        Text("Pinch to zoom, double tap for full screen")
                            .font(.caption)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(.black.opacity(0.6), in: Capsule())
                            .padding(8)
                            .transition(.opacity)
                            .allowsHitTesting(false)
                    }
                }
                .task(id: hint) {
                    guard hint else { return }
                    try? await Task.sleep(for: .seconds(2))
                    withAnimation { hint = false }
                }
        }
    }

    private func toggleFull() {
        zoom = ClipZoom()
        full.toggle()
    }

    private func togglePause() {
        paused.toggle()
        if paused { player.pause() } else { player.play() }
    }

    private func pinch(_ size: CGSize, aspect: Double?) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                live = zoom.zoomed(
                    by: value.magnification,
                    aboutX: value.startLocation.x - size.width / 2, y: value.startLocation.y - size.height / 2,
                    width: size.width, height: size.height, aspect: aspect)
            }
            .onEnded { _ in
                zoom = live ?? zoom
                live = nil
            }
    }

    private func pan(_ size: CGSize, aspect: Double?) -> some Gesture {
        DragGesture()
            .onChanged { value in
                live = zoom.panned(
                    dx: value.translation.width, dy: value.translation.height, width: size.width, height: size.height,
                    aspect: aspect)
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
    /// Off where the clip is fitted inside a larger frame, whose bands would
    /// otherwise carry the shade.
    var placeholder = true

    final class View: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> View {
        let view = View()
        // Seen only until the first frame: a shade off the page, so the slot
        // reads as a clip on its way rather than a hole in the paper.
        view.backgroundColor = placeholder ? UIColor(Color.ink.opacity(0.08)) : .clear
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

    private static let chatKey = "guessr-chat"
    /// The tail of the chat ring, kept so the tab opens on last time's lines
    /// rather than a blank page. ponytail: fifty lines in defaults, rewritten
    /// as they arrive; a file if the ring ever needs to persist whole.
    static var chat: [ChatLine] {
        get { UserDefaults.standard.data(forKey: chatKey).flatMap { try? JSONDecoder().decode([ChatLine].self, from: $0) } ?? [] }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue.suffix(50)), forKey: chatKey) }
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
    @AppStorage("kilometers") private var kilometers = false
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
            Text("\(round.score.distance(kilometers: kilometers)) away · \(round.score.filmed)")
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

extension GuessrScore {
    /// How far off the guess was, in the unit Settings picks.
    func distance(kilometers: Bool) -> String {
        kilometers ? String(localized: "\(Int(km.rounded()).formatted()) km") : String(localized: "\(miles.formatted()) mi")
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
