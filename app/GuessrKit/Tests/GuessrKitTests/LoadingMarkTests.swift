#if canImport(SwiftUI)
    import CoreGraphics
    import Testing

    @testable import GuessrKit

    @Test func everyPassRollsInsideTheSlotAndAwayFromTheLastOne() {
        for pass in 0..<200 {
            let here = LoadingMark.lane(Double(pass))
            let next = LoadingMark.lane(Double(pass + 1))
            #expect((0..<1).contains(here))
            #expect(abs(next - here) > 0.3)
        }
    }

    @Test func theMarkSpinsInPlaceThenRollsOffBeforeTheLanes() {
        let slot = CGSize(width: 400, height: 300)
        let opening = LoadingMark.opening.reduce(0) { $0 + $1.seconds }
        let start = LoadingMark.pose(at: 0, in: slot, size: 96)
        let settled = LoadingMark.pose(at: opening - 0.001, in: slot, size: 96)
        #expect(start.x == 152 && start.y == 48 && start.degrees == 0)
        #expect(settled.x == start.x && settled.y == start.y)
        #expect(abs(settled.degrees - 1080) < 1)
        // A while later the mark is in the lanes, not still parked mid-slot.
        let later = LoadingMark.pose(at: opening + 10, in: slot, size: 96)
        #expect(later.x != start.x || later.y != start.y)
    }
#endif
