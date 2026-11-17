import Foundation
import Testing
@testable import Plume

/// The hover magnification: full at the hovered row, none past the radius,
/// and smooth between.
@MainActor
struct MinimapGenieTests {
    @Test func fullAtTheRowAndNoneBeyondTheRadius() {
        #expect(MinimapGenie.scale(distance: 0, radius: 18, maximum: 2.4) == 2.4)
        #expect(MinimapGenie.scale(distance: 18, radius: 18, maximum: 2.4) == 1)
        #expect(MinimapGenie.scale(distance: -40, radius: 18, maximum: 2.4) == 1)
    }

    @Test func fallsOffMonotonicallyAndSymmetrically() {
        var previous = CGFloat.infinity
        for step in 0...18 {
            let distance = CGFloat(step)
            let scale = MinimapGenie.scale(distance: distance, radius: 18, maximum: 2)
            #expect(scale <= previous)
            #expect(scale == MinimapGenie.scale(distance: -distance, radius: 18, maximum: 2))
            previous = scale
        }
    }

    @Test func strengthFadesTheWholeEffect() {
        #expect(MinimapGenie.scale(distance: 0, radius: 18, maximum: 3, strength: 0) == 1)
        #expect(MinimapGenie.scale(distance: 0, radius: 18, maximum: 3, strength: 0.5) == 2)
    }
}
