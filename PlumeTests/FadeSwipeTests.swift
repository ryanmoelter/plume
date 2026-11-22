import Testing
@testable import Plume

/// A fade swipe fades the old text out, pauses, then fades the new one in.
/// Changes that land mid-swipe only retarget it, so it always settles on the
/// latest text.
@MainActor
struct FadeSwipeTests {
    @Test func aChangeFadesOutPausesThenFadesInTheNewText() {
        var swipe = FadeSwipe("Old")
        #expect(swipe.retarget("New") == .fadeOut)
        #expect(swipe.shown == "Old")
        #expect(swipe.stepFinished() == .pause)
        #expect(swipe.shown == "Old")
        #expect(swipe.stepFinished() == .fadeIn)
        #expect(swipe.shown == "New")
        #expect(swipe.stepFinished() == .none)
        #expect(swipe.phase == .idle)
    }

    @Test func theSameTextStartsNothing() {
        var swipe = FadeSwipe("Same")
        #expect(swipe.retarget("Same") == .none)
        #expect(swipe.phase == .idle)
    }

    @Test func changesBeforeTheNewTextShowsLandOnTheLatest() {
        var swipe = FadeSwipe("A")
        _ = swipe.retarget("B")
        #expect(swipe.retarget("C") == .none)
        _ = swipe.stepFinished()
        #expect(swipe.retarget("D") == .none)
        #expect(swipe.stepFinished() == .fadeIn)
        #expect(swipe.shown == "D")
    }

    @Test func aChangeDuringTheFadeInRunsAnotherSwipeAfterIt() {
        var swipe = FadeSwipe("A")
        _ = swipe.retarget("B")
        _ = swipe.stepFinished()
        _ = swipe.stepFinished()
        #expect(swipe.retarget("C") == .none)
        #expect(swipe.stepFinished() == .fadeOut)
        _ = swipe.stepFinished()
        #expect(swipe.stepFinished() == .fadeIn)
        #expect(swipe.shown == "C")
    }

    @Test func changingBackMidSwipeStillFadesTheOriginalBackIn() {
        var swipe = FadeSwipe("A")
        _ = swipe.retarget("B")
        _ = swipe.retarget("A")
        _ = swipe.stepFinished()
        #expect(swipe.stepFinished() == .fadeIn)
        #expect(swipe.shown == "A")
        #expect(swipe.stepFinished() == .none)
    }

    @Test func settlingDropsTheSwipeInFlight() {
        var swipe = FadeSwipe("A")
        _ = swipe.retarget("B")
        swipe.settle(on: "C")
        #expect(swipe.shown == "C")
        #expect(swipe.stepFinished() == .none)
    }
}
