import CoreGraphics
import Testing
@testable import Plume

/// Opening a section takes longer the more rows it reveals, up to a cap; rows
/// wait for the opening height to reach them, top down, and all start before
/// it settles; and the page scrolls only as far as it must to show them,
/// never past the section's header.
struct HomeSectionRevealTests {
    @Test func durationGrowsWithTheRowCountUpToACap() {
        let durations = (1...20).map { HomeSectionReveal.expandDuration(count: $0) }
        #expect(durations == durations.sorted())
        #expect(HomeSectionReveal.expandDuration(count: 1) < HomeSectionReveal.expandDuration(count: 4))
        #expect(durations.max() == HomeSectionReveal.expandMaxDuration)
        #expect(HomeSectionReveal.expandDuration(count: 100) == HomeSectionReveal.expandMaxDuration)

        let collapses = (1...20).map { HomeSectionReveal.collapseDuration(count: $0) }
        #expect(collapses == collapses.sorted())
        #expect(collapses.max() == HomeSectionReveal.collapseMaxDuration)
    }

    @Test(arguments: [1, 2, 5, 8, 30, 200])
    func rowDelaysRunTopDownWithinTheHeightAnimation(count: Int) {
        let delays = (0..<count).map { HomeSectionReveal.rowDelay(index: $0, count: count) }
        #expect(delays == delays.sorted())
        #expect(delays.first! > 0)
        #expect(delays.last! <= HomeSectionReveal.expandDuration(count: count))
    }

    /// A critically damped spring with ω = 2π / duration covers half its
    /// distance when 1 − (1 + ωt)e^(−ωt) = ½, at ωt ≈ 1.678.
    @Test func theSpringInverseMatchesACriticallyDampedSpring() {
        #expect(abs(HomeSectionReveal.time(reaching: 0.5, duration: 1) - 1.678 / (2 * .pi)) < 0.002)
        #expect(HomeSectionReveal.time(reaching: 0, duration: 1) < 0.001)
        #expect(HomeSectionReveal.time(reaching: 1, duration: 1) == 1)
    }

    @Test func noScrollWhenTheOpenedSectionFits() {
        let delta = HomeSectionReveal.scrollDelta(
            headerTop: 250, sectionBottom: 650, visibleHeight: 750
        )
        #expect(delta == 0)
    }

    @Test func scrollsJustEnoughToShowTheLastRow() {
        let delta = HomeSectionReveal.scrollDelta(
            headerTop: 450, sectionBottom: 850, visibleHeight: 750
        )
        #expect(delta == 100)
    }

    @Test func neverScrollsTheHeaderPastTheTop() {
        let delta = HomeSectionReveal.scrollDelta(
            headerTop: 350, sectionBottom: 1550, visibleHeight: 750
        )
        #expect(delta == 350)
    }

    @Test func neverScrollsUpWhenTheHeaderIsAlreadyAboveTheTop() {
        let delta = HomeSectionReveal.scrollDelta(
            headerTop: -30, sectionBottom: 1550, visibleHeight: 750
        )
        #expect(delta == 0)
    }
}
