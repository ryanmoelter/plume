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
        #expect(swipe.finish() == .pause)
        #expect(swipe.shown == "Old")
        #expect(swipe.finish() == .fadeIn)
        #expect(swipe.shown == "New")
        #expect(swipe.finish() == .none)
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
        _ = swipe.finish()
        #expect(swipe.retarget("D") == .none)
        #expect(swipe.finish() == .fadeIn)
        #expect(swipe.shown == "D")
    }

    @Test func aChangeDuringTheFadeInRunsAnotherSwipeAfterIt() {
        var swipe = FadeSwipe("A")
        _ = swipe.retarget("B")
        _ = swipe.finish()
        _ = swipe.finish()
        #expect(swipe.retarget("C") == .none)
        #expect(swipe.finish() == .fadeOut)
        _ = swipe.finish()
        #expect(swipe.finish() == .fadeIn)
        #expect(swipe.shown == "C")
    }

    @Test func changingBackMidSwipeStillFadesTheOriginalBackIn() {
        var swipe = FadeSwipe("A")
        _ = swipe.retarget("B")
        _ = swipe.retarget("A")
        _ = swipe.finish()
        #expect(swipe.finish() == .fadeIn)
        #expect(swipe.shown == "A")
        #expect(swipe.finish() == .none)
    }

    @Test func settlingDropsTheSwipeInFlight() {
        var swipe = FadeSwipe("A")
        _ = swipe.retarget("B")
        swipe.settle(on: "C")
        #expect(swipe.shown == "C")
        #expect(swipe.finish() == .none)
    }

    @Test func aCallbackFromASettledSwipeChangesNothing() {
        var swipe = FadeSwipe("A")
        _ = swipe.retarget("B")
        let stale = swipe.step
        swipe.settle(on: "B")
        _ = swipe.retarget("C")
        #expect(swipe.stepFinished(stale) == .none)
        #expect(swipe.phase == .fadingOut)
        #expect(swipe.shown == "B")
    }

    @Test func aCallbackFromAnEarlierStepChangesNothing() {
        var swipe = FadeSwipe("A")
        _ = swipe.retarget("B")
        let fadeOut = swipe.step
        _ = swipe.finish()
        #expect(swipe.stepFinished(fadeOut) == .none)
        #expect(swipe.phase == .pausing)
    }
}

private extension FadeSwipe {
    mutating func finish() -> Step {
        stepFinished(step)
    }
}
