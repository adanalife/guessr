import CoreHaptics
import GuessrKit
import MapKit
import SwiftUI

/// Today's rounds: watch the clip, drop a pin, see how close it was.
struct PlayView: View {
    @Binding var player: Player

    /// The date the rounds on screen belong to, rechecked whenever the app
    /// comes back and at midnight, since iOS can resume it days later.
    @State private var date = GuessrClient.today()
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
    /// Each score as it lands, with the day so far. The app hangs the Game
    /// Center sync and the badge off it; the App Clip hangs nothing.
    var scored: (GuessrScore, DayProgress) -> Void = { _, _ in }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

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
                // Stands in for the clip and the map alike: neither exists until
                // the day does, and MapKit says nothing about its first frame.
                LoadingMark()
            }
        }
        .paper()
        .navigationTitle("Guessr")
        // Keyed on the player and the date: a link to another device's player
        // is a new record to resume from, and a new day is new rounds.
        .task(id: [player.id, date]) { await load() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { turnOver() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            turnOver()
        }
    }

    /// Moves to today's rounds once the date has changed, clearing the old
    /// day so none of its rounds show while the new one loads.
    private func turnOver() {
        let today = GuessrClient.today()
        guard today != date else { return }
        (day, message, revealed, pin, camera) = (nil, nil, false, nil, PlayView.lower48)
        date = today
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
                    clip.aspectRatio(Guessr.clipAspect, contentMode: .fit)
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
                    clip.aspectRatio(Guessr.clipAspect, contentMode: .fit)
                    map(shown)
                    controls(day, image: image, shown: shown)
                }
                .padding()
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        // A tick as a pin lands, and none as "Next round" clears it.
        .sensoryFeedback(.selection, trigger: pin?.latitude) { _, now in now != nil }
        .sensoryFeedback(trigger: revealed) { _, shown in
            shown ? progress.played.last.flatMap { Self.feedback(for: $0.score.points) } : nil
        }
        .onChange(of: revealed) { _, shown in
            if shown, let points = progress.played.last?.score.points { RevealHaptics.play(for: points) }
        }
    }

    /// A reveal lands as hard as it scored: a thud that softens down the bands
    /// below green, and from green up `RevealHaptics`' own patterns — or a
    /// success, on hardware without them.
    static func feedback(for points: Int) -> SensoryFeedback? {
        switch points {
        case 4000...: RevealHaptics.supported ? nil : .success
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
                        .stroke(.green, lineWidth: 1.5)
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
            // A new pin cancels the last lookup, and the label keeps the last
            // state until the new one answers, so moving the pin doesn't flash
            // plain "Guess" between states. Outside the US, or when the lookup
            // fails, it says plain "Guess". ponytail: CLGeocoder is deprecated
            // in iOS 26, but MKReverseGeocodingRequest's addresses carry a city
            // and a country and no state field to read.
            .task(id: pin.map { [$0.latitude, $0.longitude] }) {
                guard let pin else {
                    pinState = nil
                    return
                }
                let placemark = try? await CLGeocoder()
                    .reverseGeocodeLocation(CLLocation(latitude: pin.latitude, longitude: pin.longitude)).first
                guard !Task.isCancelled else { return }
                guard placemark?.isoCountryCode == "US", let area = placemark?.administrativeArea else {
                    pinState = nil
                    return
                }
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
            Telemetry.requestFailed("day", error: error)
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
            scored(score, progress)
            // The map travels from the guess out to the answer, and the reveal
            // grows in around it, rather than cutting to both.
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.8)) {
                (revealed, message, camera) = (true, nil, .region(Self.fit(at, score.answer)))
            }
        } catch let error as GuessrError where error.isFinal {
            // Refused, so retrying gets the same answer: say what the server said.
            day = nil
            message = error.localizedDescription
        } catch {
            Telemetry.requestFailed("score", error: error)
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
    /// The total's size, grown and shrunk with the reader's text size.
    @ScaledMetric(relativeTo: .largeTitle) private var headline = 44.0

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
                            .stroke(.green, lineWidth: 1.5)
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
                            .font(.system(size: headline, weight: .bold, design: .serif))
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
                    if let streak = progress.streak() {
                        Text("🔥 \(streak)-day streak").font(.headline)
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
        .readableWidth(title: "Guessr", logo: true)
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
            ClipView(url: Guessr.baseURL.appending(path: round.image)).aspectRatio(Guessr.clipAspect, contentMode: .fit)
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
                    .font(.system(.headline, design: .serif, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity)
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
    @ScaledMetric(relativeTo: .largeTitle) private var headline = 44.0
    @AppStorage("kilometers") private var kilometers = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let band = Share.square(for: round.score.points) == "⬜" ? nil : Color.band(for: round.score.points)
        VStack(spacing: 2) {
            CountUp(value: counted)
                .font(.system(size: headline, weight: .bold, design: .serif))
                .monospacedDigit()
                .accessibilityLabel(round.score.points.formatted())
            Text("points").font(.caption).textCase(.uppercase).foregroundStyle(.secondary)
            Text(round.score.state)
                .font(.system(.title2, design: .serif, weight: .semibold))
                .padding(.top, 6)
            Text("\(round.score.distance(kilometers: kilometers)) away")
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

/// The reveal's buzz for a green round and a trophy one, bigger than any stock
/// `SensoryFeedback`: both play across the 0.8 s the points count up over and
/// land a hit as the number does.
@MainActor
enum RevealHaptics {
    static let supported = CHHapticEngine.capabilitiesForHardware().supportsHaptics
    private static var engine: CHHapticEngine?

    static func play(for points: Int) {
        guard supported, let events = pattern(for: points) else { return }
        do {
            if engine == nil {
                let fresh = try CHHapticEngine()
                fresh.playsHapticsOnly = true
                fresh.isAutoShutdownEnabled = true
                engine = fresh
            }
            guard let engine else { return }
            try engine.start()
            try engine.makePlayer(with: CHHapticPattern(events: events, parameters: [])).start(atTime: CHHapticTimeImmediate)
        } catch {
            // A haptic that can't play is a reveal without one, nothing worse.
            engine = nil
        }
    }

    // ponytail: hand-tuned on paper, not on a device yet; the intensities and
    // timings are the knobs.
    static func pattern(for points: Int) -> [CHHapticEvent]? {
        switch Share.square(for: points) {
        case "🏆":
            // Ticks that climb in strength and sharpness with the count, a
            // rumble swelling under them, then three slams.
            let ticks = stride(from: 0.0, to: 0.8, by: 0.05).map { t in
                hit(at: t, intensity: Float(0.3 + 0.7 * t / 0.8), sharpness: Float(0.2 + 0.8 * t / 0.8))
            }
            let slams = [0.8, 0.92, 1.04].map { hit(at: $0, intensity: 1, sharpness: 1) }
            return ticks + [rumble(at: 0, for: 0.8, intensity: 0.7, sharpness: 0.3)] + slams
                + [rumble(at: 1.04, for: 0.5, intensity: 1, sharpness: 0.5)]
        case "🟩":
            // A thump, a swell through the count, and a hit as it lands.
            return [
                hit(at: 0, intensity: 0.8, sharpness: 0.4),
                rumble(at: 0, for: 0.8, intensity: 0.5, sharpness: 0.2),
                hit(at: 0.8, intensity: 1, sharpness: 0.7),
            ]
        default:
            return nil
        }
    }

    private static func hit(at time: Double, intensity: Float, sharpness: Float) -> CHHapticEvent {
        CHHapticEvent(eventType: .hapticTransient, parameters: parameters(intensity, sharpness), relativeTime: time)
    }

    private static func rumble(at time: Double, for duration: Double, intensity: Float, sharpness: Float) -> CHHapticEvent {
        CHHapticEvent(
            eventType: .hapticContinuous, parameters: parameters(intensity, sharpness), relativeTime: time,
            duration: duration)
    }

    private static func parameters(_ intensity: Float, _ sharpness: Float) -> [CHHapticEventParameter] {
        [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
        ]
    }
}
