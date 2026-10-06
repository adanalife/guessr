#if canImport(SwiftUI)
    import SwiftUI

    /// What a slot shows while it waits for its content: the A Dana Life mark
    /// rolling across it like the wheel it is, with the caption underneath.
    /// Reduce Motion holds the mark still. The mark is the app's own `Logo`
    /// image, so each app ships its art and the package carries no catalog.
    ///
    /// The pop belongs to whoever presents this — the mark scales out on a
    /// spring as the content scales in (`landing(arrived:)`), so the landing
    /// plays *as* the content arrives and never holds it back.
    // ponytail: one lane, one pop. The mark leaves at whatever angle it was
    // turning through; landing it upright, or any particle trick, wants the mark
    // to outlive the wait as an overlay rather than ride a transition.
    public struct LoadingMark: View {
        /// The mark's diameter, which is also what it travels per turn (times π).
        var size: CGFloat
        /// Shown in place of the caption when the wait ended badly. An error
        /// also stops the mark: nothing is on its way any more.
        var error: String?

        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var rolled = false

        /// Seconds per full turn — the rolling speed, held constant however wide
        /// the slot is, so the same animation reads the same on a phone and a Mac.
        private static let secondsPerTurn: Double = 1.6

        public init(size: CGFloat = 96, error: String? = nil) {
            self.size = size
            self.error = error
        }

        private var rolls: Bool { error == nil && !reduceMotion }
        private var caption: String { error ?? String(localized: "Loading…", bundle: .module) }

        public var body: some View {
            VStack(spacing: size / 5) {
                if rolls { lane } else { mark }
                Text(caption)
                    .font(.callout)
                    .foregroundStyle(error == nil ? Color.secondary : Color.red)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, size / 2)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(error ?? String(localized: "Loading", bundle: .module))
            // The exit: the mark grows a little and fades as the content it was
            // standing in for arrives underneath. Reduce Motion keeps the
            // cross-fade and drops the growth — gentler, rather than nothing.
            .transition(reduceMotion ? .opacity : .scale(scale: 1.15).combined(with: .opacity))
        }

        /// The mark crossing the slot and wrapping. It starts and ends fully off
        /// the edge it is nearest, so `repeatForever`'s jump back to the start
        /// happens where there is nothing to see — the wheel simply leaves on the
        /// right and arrives on the left.
        private var lane: some View {
            GeometryReader { geo in
                // Turning the mark by the distance it covers is the whole trick: a
                // wheel whose rotation doesn't match its travel reads as a skid.
                let travel = geo.size.width + size
                let turns = travel / (.pi * size)
                mark
                    .rotationEffect(.degrees(rolled ? 360 * turns : 0))
                    .offset(x: (rolled ? travel : 0) - size)
                    .animation(
                        .linear(duration: Self.secondsPerTurn * turns).repeatForever(autoreverses: false),
                        value: rolled)
            }
            .frame(height: size)
            // The lane is the slot's width; off its edges the mark is hidden, not
            // drawn over whatever sits beside the slot.
            .clipped()
            .onAppear { rolled = true }
        }

        private var mark: some View {
            Image("Logo")
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .foregroundStyle(.secondary)
        }
    }

    /// The landing: the mark scales out on a spring as the content scales in
    /// under it, so the pop plays *as* the content arrives. Reduce Motion takes
    /// the bounce out and leaves a plain settle, which is the same information
    /// without the overshoot.
    private struct Landing: ViewModifier {
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        var arrived: Bool

        func body(content: Content) -> some View {
            content.animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(bounce: 0.35), value: arrived)
        }
    }

    extension View {
        /// Plays the loading mark's hand-off to the content that replaces it.
        public func landing(arrived: Bool) -> some View { modifier(Landing(arrived: arrived)) }
    }

    #Preview { LoadingMark() }

    #Preview("Small") { LoadingMark(size: 48) }

    #Preview("Error") { LoadingMark(error: "Can't reach the server") }
#endif
