#if canImport(SwiftUI)
    import SwiftUI

    /// What a slot shows while it waits for its content: the A Dana Life mark,
    /// first spinning in place — once, a beat, twice, a beat — then rolling off
    /// and across the slot like the wheel it is, a new lane each pass, under the
    /// caption.
    /// Reduce Motion holds the mark still. The mark is the app's own `Logo`
    /// image, so each app ships its art and the package carries no catalog.
    ///
    /// The pop belongs to whoever presents this — the mark scales out on a
    /// spring as the content scales in (`landing(arrived:)`), so the landing
    /// plays *as* the content arrives and never holds it back.
    // ponytail: one pop. The mark leaves at whatever angle it was turning
    // through; landing it upright, or any particle trick, wants the mark to
    // outlive the wait as an overlay rather than ride a transition.
    public struct LoadingMark: View {
        /// The mark's diameter, which is also what it travels per turn (times π).
        var size: CGFloat
        /// Shown in place of the caption when the wait ended badly. An error
        /// also stops the mark: nothing is on its way any more.
        var error: String?

        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var started = Date.now

        /// Seconds per full turn — the rolling speed, held constant however wide
        /// the slot is, so the same animation reads the same on a phone and a Mac.
        nonisolated static let secondsPerTurn: Double = 1.6

        public init(size: CGFloat = 96, error: String? = nil) {
            self.size = size
            self.error = error
        }

        private var rolls: Bool { error == nil && !reduceMotion }
        private var caption: String { error ?? String(localized: "Loading…", bundle: .module) }

        public var body: some View {
            VStack(spacing: size / 5) {
                // The rolling mark draws behind the whole slot, so this space only
                // holds the caption where the resting mark would sit.
                if rolls { Color.clear.frame(height: size) } else { mark }
                Text(caption)
                    .font(.callout)
                    .foregroundStyle(error == nil ? Color.secondary : Color.red)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, size / 2)
            // Behind the caption, so a pass low enough to cross it rolls under
            // the text rather than over it.
            .background { if rolls { lanes } }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(error ?? String(localized: "Loading", bundle: .module))
            // The exit: the mark grows a little and fades as the content it was
            // standing in for arrives underneath. Reduce Motion keeps the
            // cross-fade and drops the growth — gentler, rather than nothing.
            .transition(reduceMotion ? .opacity : .scale(scale: 1.15).combined(with: .opacity))
        }

        /// The opening, then the mark crossing the slot and wrapping, one pass
        /// after another, each at a new height. A pass starts and ends fully off
        /// the edge it is nearest, so the jump to the next lane happens where
        /// there is nothing to see — the wheel leaves on the right and arrives on
        /// the left.
        private var lanes: some View {
            GeometryReader { geo in
                TimelineView(.animation) { context in
                    let pose = Self.pose(
                        at: context.date.timeIntervalSince(started), in: geo.size, size: size)
                    mark
                        .rotationEffect(.degrees(pose.degrees))
                        .offset(x: pose.x, y: pose.y)
                }
            }
            // The lane is the slot; off its edges the mark is hidden, not drawn
            // over whatever sits beside the slot.
            .clipped()
            .accessibilityHidden(true)
        }

        /// The opening's beats: turns and seconds each. The mark starts where the
        /// still mark rests, so a short wait shows a whole gesture rather than a
        /// wheel already mid-roll.
        nonisolated static let opening: [(turns: Double, seconds: Double)] = [(1, 0.7), (0, 0.5), (2, 1.1), (0, 0.5)]

        /// Where the mark sits in the slot and how far it has turned, `t` seconds
        /// into the wait: the opening's spins in place, a roll off the right
        /// edge, then the lanes.
        nonisolated static func pose(at t: Double, in slot: CGSize, size: CGFloat) -> (x: CGFloat, y: CGFloat, degrees: Double) {
            let rest = (x: (slot.width - size) / 2, y: size / 2)
            var t = t
            var turned = 0.0
            for beat in opening {
                if t < beat.seconds {
                    let p = t / beat.seconds
                    let eased = p * p * (3 - 2 * p)
                    return (rest.x, rest.y, 360 * (turned + beat.turns * eased))
                }
                t -= beat.seconds
                turned += beat.turns
            }

            // Turning the mark by the distance it covers is the whole trick: a
            // wheel whose rotation doesn't match its travel reads as a skid.
            let exit = slot.width - rest.x
            let exitTurns = exit / (.pi * size)
            let exitSeconds = secondsPerTurn * exitTurns
            if t < exitSeconds {
                let p = t / exitSeconds
                return (rest.x + exit * p, rest.y, 360 * exitTurns * p)
            }
            t -= exitSeconds

            let travel = slot.width + size
            let turns = travel / (.pi * size)
            let passes = t / (secondsPerTurn * turns)
            let pass = passes.rounded(.down)
            let progress = passes - pass
            return (travel * progress - size, max(0, slot.height - size) * lane(pass), 360 * turns * progress)
        }

        /// Where pass `n` rolls, from 0 (the slot's top) to 1 (its bottom). Steps
        /// of the golden ratio never land two passes in a row closer than ~0.38
        /// of the slot apart, and never settle into a visible cycle.
        nonisolated static func lane(_ pass: Double) -> Double {
            (pass * 0.618_034).truncatingRemainder(dividingBy: 1)
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
