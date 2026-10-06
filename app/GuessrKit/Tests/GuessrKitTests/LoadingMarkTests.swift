#if canImport(SwiftUI)
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
#endif
