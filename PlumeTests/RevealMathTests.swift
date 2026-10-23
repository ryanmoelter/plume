import Foundation
import Testing

@testable import Plume

struct RevealMathTests {
    @Test func collapsedTakesNoHeightAndShowsNothing() {
        #expect(RevealMath.height(natural: 40, progress: 0) == 0)
        #expect(RevealMath.opacity(progress: 0) == 0)
    }

    @Test func expandedTakesNaturalHeightAndIsOpaque() {
        #expect(RevealMath.height(natural: 40, progress: 1) == 40)
        #expect(RevealMath.opacity(progress: 1) == 1)
    }

    @Test func contentStaysHiddenWhileClippedThin() {
        #expect(RevealMath.opacity(progress: 0.4) == 0)
        #expect(RevealMath.opacity(progress: 0.7) > 0)
        #expect(RevealMath.opacity(progress: 0.7) < 1)
    }

    @Test func overshootingProgressIsClamped() {
        #expect(RevealMath.height(natural: 40, progress: 1.2) == 40)
        #expect(RevealMath.height(natural: 40, progress: -0.2) == 0)
    }
}
