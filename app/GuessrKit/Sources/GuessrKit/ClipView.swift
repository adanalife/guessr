// The clip player, shared by every app that shows guessr clips, so a fix to
// how a clip loads, fits or zooms lands in each. iPhone and iPad only: the
// gestures and the full-screen cover are UIKit's.
#if os(iOS)
    import AVFoundation
    import SwiftUI
    import UIKit

    /// A clip on a muted loop. No scrubber: a scrubber is a way to hunt for a
    /// frame the round didn't mean to show. A pinch zooms in and a drag pans the
    /// zoomed picture, a tap pauses it and names the other gestures for a moment,
    /// and a double tap opens it full screen, or closes the full screen, zoomed
    /// back out. `fills` crops it to cover its frame rather than letterboxing
    /// inside it.
    public struct ClipView: View {
        /// Told of every clip that fails to load, with the attempt it was and
        /// why. AVPlayer fetches outside URLSession, so an app's crash reporter
        /// never sees these unless it sets this.
        @MainActor public static var failed: (_ url: URL, _ attempt: Int, _ error: (any Error)?) -> Void = { _, _, _ in }

        let url: URL
        var fills = false
        @State private var player = AVQueuePlayer()
        @State private var looper: AVPlayerLooper?
        /// Where the loop was when the view last went away, for the next appearance.
        @State private var resume: CMTime?
        /// Loads in a row that failed, for the backoff before the next; above zero
        /// the clip says it is trying again.
        @State private var failures = 0
        /// The clip's item can play; until then the slot rolls the mark.
        @State private var ready = false
        @State private var paused = false
        @State private var hint = false
        /// The zoom between gestures, and the one a gesture in progress shows.
        @State private var zoom = ClipZoom()
        @State private var live: ClipZoom?
        /// Full screen is the same player and gestures on a cover of their own,
        /// so the loop carries on across the switch rather than restarting.
        @State private var full = false
        /// Full screen grows out of the clip and shrinks back into it.
        @Namespace private var cover

        public init(url: URL, fills: Bool = false) {
            self.url = url
            self.fills = fills
        }

        public var body: some View {
            surface(fills: fills)
                .matchedTransitionSource(id: url, in: cover)
                .accessibilityElement()
                .accessibilityLabel(failures > 0 ? L("Clip, loading again") : paused ? L("Clip, paused") : L("Clip"))
                .accessibilityAction(named: paused ? L("Play") : L("Pause")) { togglePause() }
                .accessibilityAction(named: L("Full screen")) { toggleFull() }
                .fullScreenCover(isPresented: $full, onDismiss: { zoom = ClipZoom() }) {
                    // The whole screen is the frame, so a pinch can grow the clip
                    // past its own shape until it fills the screen.
                    surface(fills: false, screen: true)
                        .ignoresSafeArea()
                        .overlay(alignment: .topTrailing) {
                            Button(L("Close"), systemImage: "xmark") { full = false }
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
                        .navigationTransition(.zoom(sourceID: url, in: cover))
                        // The zoom's swipe down to close would take a zoomed
                        // picture's downward pan.
                        .interactiveDismissDisabled(zoom.scale > 1)
                }
                // A tab switch runs this again on the way back, onto the player the
                // disappearance emptied: a fresh looper picks up where the last one left.
                .onAppear {
                    if looper == nil { load() }
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
                // The cover hides this view without ending the clip. Anything else
                // empties the player: a paused player still holding its items keeps
                // a video decoder, and iOS runs out of those after enough rounds and
                // replays, when every clip after draws as a black rectangle.
                .onDisappear {
                    guard !full else { return }
                    resume = player.currentTime()
                    looper?.disableLooping()
                    looper = nil
                    player.removeAllItems()
                }
                // A clip that fails to load -- a server error, a dropped connection --
                // would otherwise stay a black panel for the rest of the round. Load it
                // again, backing off to every 16 seconds, for as long as it's on screen.
                .task(id: looper.map(ObjectIdentifier.init)) {
                    guard let looper else { return }
                    for await status in changes(of: looper, \.status) {
                        guard status == .failed else { continue }
                        failures += 1
                        Self.failed(url, failures, player.currentItem?.error ?? looper.error)
                        guard (try? await Task.sleep(for: .seconds(1 << min(failures, 4)))) != nil else { return }
                        looper.disableLooping()
                        player.removeAllItems()
                        load()
                        if !paused { player.play() }
                        return
                    }
                }
                // The looper reads `.ready` as soon as it is set up, before the clip
                // has arrived; the item playing is the clip in hand.
                .task(id: looper.map(ObjectIdentifier.init)) {
                    guard looper != nil else { return }
                    for await status in changes(of: player, \.currentItem?.status) where status == .readyToPlay {
                        failures = 0
                        withAnimation { ready = true }
                        return
                    }
                }
        }

        private func load() {
            ready = false
            player.isMuted = true
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            if let resume { player.seek(to: resume, toleranceBefore: .zero, toleranceAfter: .zero) }
        }

        /// The clip and its gestures. `screen` is the full-screen cover's: the
        /// frame is the screen, the clip fitted inside it on the bare page.
        private func surface(fills: Bool, screen: Bool = false) -> some View {
            GeometryReader { geo in
                let shown = live ?? zoom
                let aspect = screen ? Guessr.clipAspect : nil
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
                        if failures > 0 {
                            // Says the black panel is on its way rather than broken.
                            VStack(spacing: 8) {
                                ProgressView().tint(.white)
                                Text(L("The clip didn't load. Trying again…"))
                                    .font(.caption)
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                            .allowsHitTesting(false)
                        } else if !ready {
                            LoadingMark(size: 48)
                                .allowsHitTesting(false)
                        } else if paused {
                            Image(systemName: "pause.circle.fill")
                                .font(.largeTitle)
                                .foregroundStyle(.white.opacity(0.8))
                                .allowsHitTesting(false)
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if hint {
                            Text(L("Pinch to zoom, double tap for full screen"))
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

        /// A gesture stretches past the zoom's limits while the fingers are down,
        /// and on release springs back inside them, the way Photos does.
        private func pinch(_ size: CGSize, aspect: Double?) -> some Gesture {
            func zoomed(_ value: MagnifyGesture.Value, elastic: Bool) -> ClipZoom {
                zoom.zoomed(
                    by: value.magnification,
                    aboutX: value.startLocation.x - size.width / 2, y: value.startLocation.y - size.height / 2,
                    width: size.width, height: size.height, aspect: aspect, elastic: elastic)
            }
            return MagnifyGesture()
                .onChanged { live = zoomed($0, elastic: true) }
                .onEnded { value in settle(zoomed(value, elastic: false)) }
        }

        /// A pan carries on past the finger's release to where its speed was taking
        /// it, as a scroll view does, and stops at the picture's edge.
        private func pan(_ size: CGSize, aspect: Double?) -> some Gesture {
            DragGesture()
                .onChanged { value in
                    live = zoom.panned(
                        dx: value.translation.width, dy: value.translation.height, width: size.width, height: size.height,
                        aspect: aspect, elastic: true)
                }
                .onEnded { value in
                    settle(
                        zoom.panned(
                            dx: value.predictedEndTranslation.width, dy: value.predictedEndTranslation.height,
                            width: size.width, height: size.height, aspect: aspect))
                }
        }

        private func settle(_ to: ClipZoom) {
            withAnimation(.smooth(duration: 0.4)) { (zoom, live) = (to, nil) }
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

    /// A key path's values, the first one included. `publisher(for:).values`
    /// would be the obvious spelling, but it hands over that first value and
    /// then nothing: AVFoundation's later changes never arrive through it.
    @MainActor private func changes<Object: NSObject, Value: Sendable>(
        of object: Object, _ keyPath: KeyPath<Object, Value> & Sendable
    )
        -> AsyncStream<Value>
    {
        AsyncStream { continuation in
            let observation = object.observe(keyPath, options: [.initial, .new]) { object, _ in
                continuation.yield(object[keyPath: keyPath])
            }
            continuation.onTermination = { _ in observation.invalidate() }
        }
    }

    private func L(_ key: String.LocalizationValue) -> String { String(localized: key, bundle: .module) }
#endif
