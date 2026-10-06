import CoreGraphics
import Testing
@testable import Plume

/// Which edges of the `/btw` answer fade: only those with more answer past them.
struct ScrollOverflowTests {
    @Test func anAnswerThatFitsFadesNeitherEdge() {
        let overflow = ScrollOverflow(visibleRect: CGRect(x: 0, y: 0, width: 300, height: 120), contentHeight: 120)
        #expect(overflow == ScrollOverflow())
    }

    @Test func aLongAnswerAtTheTopFadesOnlyTheBottom() {
        let overflow = ScrollOverflow(visibleRect: CGRect(x: 0, y: 0, width: 300, height: 220), contentHeight: 600)
        #expect(!overflow.above && overflow.below)
    }

    @Test func aLongAnswerMidwayFadesBothEdges() {
        let overflow = ScrollOverflow(visibleRect: CGRect(x: 0, y: 100, width: 300, height: 220), contentHeight: 600)
        #expect(overflow.above && overflow.below)
    }

    @Test func aLongAnswerAtTheBottomFadesOnlyTheTop() {
        let overflow = ScrollOverflow(visibleRect: CGRect(x: 0, y: 380, width: 300, height: 220), contentHeight: 600)
        #expect(overflow.above && !overflow.below)
    }

    /// 0.3pt short of the end is rounding at rest, not more answer.
    @Test func subPointRoundingAtAnEndIsNotOverflow() {
        let overflow = ScrollOverflow(visibleRect: CGRect(x: 0, y: 0.3, width: 300, height: 220), contentHeight: 220.6)
        #expect(overflow == ScrollOverflow())
    }
}
