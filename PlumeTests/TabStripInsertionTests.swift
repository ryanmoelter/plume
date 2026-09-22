import CoreGraphics
import Testing
@testable import Plume

/// Three 100pt chips 6pt apart, starting at x = 8: 8...108, 114...214, 220...320.
struct TabStripInsertionTests {
    private let chips: [ClosedRange<CGFloat>] = [8...108, 114...214, 220...320]

    @Test func leadingHalfOfAChipLandsBeforeIt() {
        #expect(TabStripInsertion.gap(forX: 10, chips: chips) == 0)
        #expect(TabStripInsertion.gap(forX: 150, chips: chips) == 1)
        #expect(TabStripInsertion.gap(forX: 260, chips: chips) == 2)
    }

    @Test func trailingHalfOfAChipLandsAfterIt() {
        #expect(TabStripInsertion.gap(forX: 100, chips: chips) == 1)
        #expect(TabStripInsertion.gap(forX: 200, chips: chips) == 2)
    }

    @Test func spaceBetweenChipsLandsInThatGap() {
        #expect(TabStripInsertion.gap(forX: 111, chips: chips) == 1)
    }

    @Test func pastTheLastChipOrBeforeTheFirstLandsAtTheEnds() {
        #expect(TabStripInsertion.gap(forX: 600, chips: chips) == 3)
        #expect(TabStripInsertion.gap(forX: 0, chips: chips) == 0)
    }

    @Test func noChipsLandsAtZero() {
        #expect(TabStripInsertion.gap(forX: 50, chips: []) == 0)
    }

    @Test func markerSitsMidwayBetweenNeighbors() {
        #expect(TabStripInsertion.markerX(gap: 1, chips: chips, spacing: 6) == 111)
        #expect(TabStripInsertion.markerX(gap: 2, chips: chips, spacing: 6) == 217)
    }

    @Test func markerAtTheEndsSitsHalfASpacingOutside() {
        #expect(TabStripInsertion.markerX(gap: 0, chips: chips, spacing: 6) == 5)
        #expect(TabStripInsertion.markerX(gap: 3, chips: chips, spacing: 6) == 323)
    }

    @Test func markerRejectsAGapOutOfRange() {
        #expect(TabStripInsertion.markerX(gap: 4, chips: chips, spacing: 6) == nil)
        #expect(TabStripInsertion.markerX(gap: 0, chips: [], spacing: 6) == nil)
    }
}
