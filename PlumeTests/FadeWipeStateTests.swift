import Testing
@testable import Plume

/// A wipe draws the old and new text at once until it finishes. Changes that
/// land mid-wipe only retarget it, so it always settles on the latest text,
/// and a completion from a retired wipe changes nothing.
@MainActor
struct FadeWipeStateTests {
    @Test func aChangeWipesFromTheOldTextToTheNew() {
        var wipe = FadeWipeState("Old")
        #expect(wipe.retarget("New") == .wipe)
        #expect(wipe.outgoing == "Old")
        #expect(wipe.shown == "New")
        #expect(wipe.finish() == .none)
        #expect(wipe.outgoing == nil)
        #expect(wipe.phase == .idle)
    }

    @Test func theSameTextStartsNothing() {
        var wipe = FadeWipeState("Same")
        #expect(wipe.retarget("Same") == .none)
        #expect(wipe.phase == .idle)
        #expect(wipe.outgoing == nil)
    }

    @Test func changesMidWipeRunOneMoreWipeToTheLatest() {
        var wipe = FadeWipeState("A")
        _ = wipe.retarget("B")
        #expect(wipe.retarget("C") == .none)
        #expect(wipe.retarget("D") == .none)
        #expect(wipe.shown == "B")
        #expect(wipe.finish() == .wipe)
        #expect(wipe.outgoing == "B")
        #expect(wipe.shown == "D")
        #expect(wipe.finish() == .none)
        #expect(wipe.phase == .idle)
    }

    @Test func changingBackMidWipeWipesBackToTheOriginal() {
        var wipe = FadeWipeState("A")
        _ = wipe.retarget("B")
        _ = wipe.retarget("A")
        #expect(wipe.finish() == .wipe)
        #expect(wipe.outgoing == "B")
        #expect(wipe.shown == "A")
    }

    @Test func settlingDropsTheWipeInFlight() {
        var wipe = FadeWipeState("A")
        _ = wipe.retarget("B")
        wipe.settle(on: "C")
        #expect(wipe.shown == "C")
        #expect(wipe.outgoing == nil)
        #expect(wipe.finish() == .none)
    }

    @Test func aCompletionFromASettledWipeChangesNothing() {
        var wipe = FadeWipeState("A")
        _ = wipe.retarget("B")
        let stale = wipe.step
        wipe.settle(on: "B")
        _ = wipe.retarget("C")
        #expect(wipe.stepFinished(stale) == .none)
        #expect(wipe.phase == .wiping)
        #expect(wipe.outgoing == "B")
        #expect(wipe.shown == "C")
    }

    @Test func aCompletionFromAnEarlierWipeChangesNothing() {
        var wipe = FadeWipeState("A")
        _ = wipe.retarget("B")
        let first = wipe.step
        _ = wipe.retarget("C")
        _ = wipe.finish()
        #expect(wipe.stepFinished(first) == .none)
        #expect(wipe.outgoing == "B")
        #expect(wipe.shown == "C")
    }
}

private extension FadeWipeState {
    mutating func finish() -> Step {
        stepFinished(step)
    }
}
