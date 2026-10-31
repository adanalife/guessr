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
    /// When the current round's clip went up, for the think time sent with the
    /// guess. In memory only, so a relaunch mid-round starts the clock again.
    @State private var roundShown = ContinuousClock.now
    @State private var message: String?
    @State private var camera = PlayView.lower48
    /// Where the map is looking, whoever moved it last: the zoom buttons scale it.
    @State private var region: MKCoordinateRegion?
    /// The corner map grown to a panel over a full-screen clip, up until the
    /// guess is scored.
    @State private var showingMap = false
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// Compact on a phone held on its side, the one shape with no room to
    /// stack the clip over the map.
    @Environment(\.verticalSizeClass) private var heightClass
    /// Each score as it lands, with the day so far. The app hangs the Game
    /// Center sync and the badge off it; the App Clip hangs nothing.
    var scored: (GuessrScore, DayProgress) -> Void = { _, _ in }
    /// The finished day on screen, whether just played or reopened. The App
    /// Clip offers the full app off it; the app hangs nothing.
    var finished: () -> Void = {}
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
                        .onAppear {
                            finished()
                            Telemetry.step(
                                .resultShown, date: progress.date,
                                data: ["rounds": progress.played.count, "total": progress.total])
                        }
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
        // The page fills the screen, so the mark waits on paper rather than in a
        // paper band across the system background.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        let clip = ClipView(url: Guessr.baseURL.appending(path: image)).id(image)
        return Group {
            if heightClass == .compact || sizeClass == .regular {
                // A phone on its side, an iPad, an unfolded iPhone Duo: the clip
                // takes the whole screen, letterboxed so none of the road is
                // cropped, since squinting at it is the game. The map waits small
                // in its corner until the player opens it, then grows into a panel
                // down the trailing side with the guess under it. It stays a panel
                // through the reveal, with the score card on the clip's other corner.
                GeometryReader { screen in
                    let open = showingMap || shown != nil
                    let panel = min(screen.size.width * 0.45, 420)
                    ZStack(alignment: .bottomTrailing) {
                        Color.black.ignoresSafeArea()
                        clip.ignoresSafeArea()
                        if let shown {
                            RevealCard(round: shown)
                                .padding(8)
                                .frame(width: 280)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                                .padding()
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        }
                        VStack(spacing: 8) {
                            ProgressSquares(progress: progress, of: day.rounds.count)
                            map(shown, zoomable: open)
                                // No taller than wide, so an upright screen's panel
                                // doesn't stretch the map into a strip.
                                .frame(maxHeight: open ? panel : 110)
                                .allowsHitTesting(open)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay {
                                    if !open {
                                        Button { showingMap = true } label: {
                                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                                .padding(6)
                                                .background(.regularMaterial, in: Circle())
                                                .padding(6)
                                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                                                .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                        .foregroundStyle(Color.ink)
                                        .accessibilityLabel("Open the map")
                                    }
                                }
                                .overlay(alignment: .topTrailing) {
                                    if open && shown == nil {
                                        Button { showingMap = false } label: {
                                            Image(systemName: "xmark").frame(width: 44, height: 44).contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                        .foregroundStyle(Color.ink)
                                        .background(.regularMaterial, in: Circle().inset(by: 6))
                                        .accessibilityLabel("Hide the map")
                                    }
                                }
                                .layoutPriority(-1)
                            if open {
                                if shown == nil, let message {
                                    Text(message).font(.callout).multilineTextAlignment(.center)
                                }
                                button(day, image: image).inkButton()
                            }
                        }
                        .padding(8)
                        .frame(width: open ? panel : 200)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .padding()
                    }
                    .animation(reduceMotion ? nil : .smooth, value: open)
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
        // Scored, the map shows the answer inline, so the opened one closes and
        // the next round starts on the clip.
        .onChange(of: revealed) { if revealed { showingMap = false } }
        // The image holds through the reveal and changes with the next round, so
        // this starts the clock once per clip.
        .onChange(of: image, initial: true) {
            roundShown = .now
            Telemetry.step(.roundShown, date: progress.date, round: progress.played.count + 1, clip: image)
        }
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

    /// `zoomable: false` drops the zoom buttons, for a map too small to hold them.
    private func map(_ shown: PlayedRound?, zoomable: Bool = true) -> some View {
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
                if zoomable { zoomButtons }
            }
        }
    }

    private var zoomButtons: some View {
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
            // fails, it says plain "Guess". MapKit's addresses have no state
            // field, so the state is the postal code that ends a US pin's
            // `cityWithContext` ("Austin, NV" — the nearest town, even in a
            // national forest). ponytail: a pin near a border names the
            // nearest town's state; bundle state polygons if that misleads.
            .task(id: pin.map { [$0.latitude, $0.longitude] }) {
                guard let pin else {
                    pinState = nil
                    return
                }
                let request = MKReverseGeocodingRequest(location: CLLocation(latitude: pin.latitude, longitude: pin.longitude))
                let address = try? await request?.mapItems.first?.addressRepresentations
                guard !Task.isCancelled else { return }
                guard address?.region?.identifier == "US",
                      let area = address?.cityWithContext?.split(separator: ",").last?.trimmingCharacters(in: .whitespaces)
                else {
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
            Telemetry.step(
                .dayLoaded, date: progress.date,
                data: ["rounds": loaded.rounds.count, "played": progress.played.count])
        } catch {
            Telemetry.requestFailed("day", error: error)
            // The server says why — nothing scheduled, or a date not yet open.
            message = (error as? GuessrError)?.errorDescription ?? String(localized: "Could not reach the rounds")
        }
        #if DEBUG
            showingMap = UserDefaults.standard.bool(forKey: "map")
            if UserDefaults.standard.bool(forKey: "landscape"),
                let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
            {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
            }
            await autoplay()
        #endif
    }

    #if DEBUG
        /// `-autoplay 1` plays the rest of the day unattended, pausing on each
        /// round and each reveal long enough to screenshot it. `-map 1` opens
        /// the corner map on launch, and `-landscape 1` turns the
        /// phone on its side, two things the shell can't do.
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
            let score = try await client.score(
                image: image, guess: at, date: progress.date, player: player, elapsed: .now - roundShown)
            progress.played.append(PlayedRound(image: image, guess: at, score: score))
            Saved.progress = progress
            Telemetry.step(
                .guessed, date: progress.date, round: progress.played.count, clip: image,
                data: ["points": score.points, "seconds": Int((ContinuousClock.now - roundShown).components.seconds)])
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
    @State private var joined = false

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
        .sheet(
            isPresented: Binding(get: { preview != nil }, set: { if !$0 { preview = nil } }),
            onDismiss: { if joined { dismiss() } }
        ) {
            if let preview {
                LinkCompareView(
                    preview: preview, alias: player.alias, codeHeading: String(localized: "Entered code"), join: join)
            }
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

    /// Claims the code; this view closes once the comparison sheet has, and a
    /// failure is left in the footer.
    private func join() async -> Bool {
        do {
            let claim = try await client.claimLink(code: code, from: player)
            // Today's rounds are the joined player's now, as the server holds them.
            Saved.progress = nil
            player = Player(id: claim.playerId, alias: player.alias)
            joined = true
        } catch {
            fail(error)
        }
        return joined
    }

    private func fail(_ error: Error) {
        if let error = error as? GuessrError, error.isFinal {
            message = String(localized: "That code is unknown or has expired. Show a new one on the web.")
        } else {
            message = String(localized: "Could not reach the server. Try the code again.")
        }
    }
}

/// The question a link code asks before this device joins its player: both
/// players side by side, then one button that joins and one that doesn't.
/// `join` answers whether the merge ran; the sheet closes either way, and the
/// caller says what went wrong.
struct LinkCompareView: View {
    let preview: LinkPreview
    /// This device's own name, which joining keeps.
    let alias: String
    /// The other column's heading: where the code came from.
    let codeHeading: String
    let join: () async -> Bool
    @State private var joining = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    /// A row of the table: what it is, then this device's value and the code's.
    private struct Row: Identifiable {
        var label: String
        var mine: String
        var theirs: String
        var id: String { label }
    }

    private var rows: [Row] {
        var rows = [
            // This device's own alias, which a link keeps and the button names; the
            // server's name for this player can differ.
            Row(label: String(localized: "Name"), mine: alias, theirs: preview.to.name),
            Row(
                label: String(localized: "Points"), mine: preview.from.points.formatted(),
                theirs: preview.to.points.formatted()),
        ]
        // A server that sends only names and points says nothing of the rest.
        if let mine = preview.from.days, let theirs = preview.to.days {
            rows.append(Row(label: String(localized: "Days played"), mine: mine.formatted(), theirs: theirs.formatted()))
            rows.append(
                Row(
                    label: String(localized: "Last played"), mine: preview.from.lastPlayedText,
                    theirs: preview.to.lastPlayedText))
        }
        return rows
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("This code belongs to another player.")
                    if typeSize.isAccessibilitySize { stacked } else { table }
                }
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding()
            }
            .safeAreaInset(edge: .bottom) { choices }
            .paper()
            .navigationTitle("Link this device?")
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled(joining)
    }

    private var table: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 12) {
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                Text("This device")
                Text(codeHeading)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
            Divider()
            ForEach(rows) { row in
                GridRow {
                    Text(row.label).foregroundStyle(.secondary)
                    Text(row.mine)
                    Text(row.theirs)
                }
                .monospacedDigit()
                // One element per row: the label, then each column's value
                // named by its heading.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(row.label)
                .accessibilityValue(String(localized: "This device: \(row.mine)") + ", \(codeHeading): \(row.theirs)")
            }
        }
    }

    /// The table one player at a time, for text too large to sit three across.
    private var stacked: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach([(String(localized: "This device"), \Row.mine), (codeHeading, \Row.theirs)], id: \.0) { heading, value in
                VStack(alignment: .leading, spacing: 8) {
                    Text(heading).font(.headline).accessibilityAddTraits(.isHeader)
                    ForEach(rows) { row in
                        LabeledContent(row.label, value: row[keyPath: value])
                    }
                }
            }
        }
    }

    /// What joining does to this device's plays, counted in days when the
    /// server says how many.
    private var merging: Text {
        switch preview.from.days {
        case 0?: Text("Nothing has been played on this device yet.")
        case let days?: Text("\(days) days played on this device will be merged with \(preview.to.name).")
        case nil: Text("This device's plays will be merged with \(preview.to.name).")
        }
    }

    private var choices: some View {
        VStack(spacing: 12) {
            Button {
                Task {
                    joining = true
                    _ = await join()
                    joining = false
                    dismiss()
                }
            } label: {
                Group {
                    if joining { ProgressView() } else { Text("Play as \(preview.to.name)").fixedSize(horizontal: false, vertical: true) }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            merging
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                dismiss()
            } label: {
                // A long name at a large text size wraps rather than truncating.
                Text("Keep playing as \(alias)").fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .disabled(joining)
        .frame(maxWidth: 560)
        .padding()
        .background(.bar)
    }
}

extension LinkPreview.Standing {
    /// The last play's date for the reader's locale, read in UTC so it is the
    /// date the server sent.
    var lastPlayedText: String {
        lastPlayed?.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: .gmt))
            ?? String(localized: "Never")
    }
}

#if DEBUG
    extension LinkPreview {
        /// What `-linkPreview 1` shows, so the comparison can be screenshotted
        /// without scanning a code.
        static let sample = LinkPreview(
            to: Standing(name: "Patient Delta", points: 12345, days: 30, last: "2026-10-18"),
            from: Standing(name: "Lucky Overpass", points: 500, days: 2, last: "2026-10-12"), overlap: 1)
    }
#endif

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
                        Telemetry.step(.shared, date: progress.date, data: ["total": progress.total])
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
