import Testing
@testable import Plume

/// A wipe draws the old and new text at once until it finishes. Changes that
/// land mid-wipe only retarget it, so it always settles on the latest text,
/// and a completion from a retired wipe changes nothing.
@MainActor
struct FadeSwipeTests {
    @Test func aChangeWipesFromTheOldTextToTheNew() {
        var swipe = FadeSwipe("Old")
        #expect(swipe.retarget("New") == .wipe)
        #expect(swipe.outgoing == "Old")
        #expect(swipe.shown == "New")
        #expect(swipe.finish() == .none)
        #expect(swipe.outgoing == nil)
        #expect(swipe.phase == .idle)
    }

    @Test func theSameTextStartsNothing() {
        var swipe = FadeSwipe("Same")
        #expect(swipe.retarget("Same") == .none)
        #expect(swipe.phase == .idle)
        #expect(swipe.outgoing == nil)
    }

    @Test func changesMidWipeRunOneMoreWipeToTheLatest() {
        var swipe = FadeSwipe("A")
        _ = swipe.retarget("B")
        #expect(swipe.retarget("C") == .none)
        #expect(swipe.retarget("D") == .none)
        #expect(swipe.shown == "B")
        #expect(swipe.finish() == .wipe)
        #expect(swipe.outgoing == "B")
        #expect(swipe.shown == "D")
        #expect(swipe.finish() == .none)
        #expect(swipe.phase == .idle)
    }

    @Test func changingBackMidWipeWipesBackToTheOriginal() {
        var swipe = FadeSwipe("A")
        _ = swipe.retarget("B")
        _ = swipe.retarget("A")
        #expect(swipe.finish() == .wipe)
        #expect(swipe.outgoing == "B")
        #expect(swipe.shown == "A")
    }

    @Test func settlingDropsTheWipeInFlight() {
        var swipe = FadeSwipe("A")
        _ = swipe.retarget("B")
        swipe.settle(on: "C")
        #expect(swipe.shown == "C")
        #expect(swipe.outgoing == nil)
        #expect(swipe.finish() == .none)
    }

    @Test func aCompletionFromASettledWipeChangesNothing() {
        var swipe = FadeSwipe("A")
        _ = swipe.retarget("B")
        let stale = swipe.step
        swipe.settle(on: "B")
        _ = swipe.retarget("C")
        #expect(swipe.stepFinished(stale) == .none)
        #expect(swipe.phase == .wiping)
        #expect(swipe.outgoing == "B")
        #expect(swipe.shown == "C")
    }

    @Test func aCompletionFromAnEarlierWipeChangesNothing() {
        var swipe = FadeSwipe("A")
        _ = swipe.retarget("B")
        let first = swipe.step
        _ = swipe.retarget("C")
        _ = swipe.finish()
        #expect(swipe.stepFinished(first) == .none)
        #expect(swipe.outgoing == "B")
        #expect(swipe.shown == "C")
    }
}

private extension FadeSwipe {
    mutating func finish() -> Step {
        stepFinished(step)
    }
}
