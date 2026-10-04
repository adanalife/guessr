import SwiftUI

/// What a slot shows while it waits for its content: the A Dana Life mark
/// rolling across it like the wheel it is, with the caption underneath.
/// Reduce Motion holds the mark still.
// ponytail: one lane, no landing. The mark fades out at whatever angle it was
// turning through; landing it upright wants it to outlive the wait as an
// overlay rather than ride a transition.
struct LoadingMark: View {
    /// The mark's diameter, which is also what it travels per turn (times π).
    var size: CGFloat = 96

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rolled = false

    /// Seconds per full turn — the rolling speed, held constant however wide
    /// the slot is, so the same animation reads the same on a phone and an iPad.
    private static let secondsPerTurn: Double = 1.6

    var body: some View {
        VStack(spacing: size / 5) {
            if reduceMotion { mark } else { lane }
            Text("Loading…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading")
        .transition(.opacity)
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

#Preview { LoadingMark() }

#Preview("Small") { LoadingMark(size: 48) }
