import Foundation
import SwiftUI
import Testing
@testable import Plume

/// The reveal's pacing: how long a delta takes to draw, and how a delta
/// landing mid-reveal shortens what is left rather than queueing behind it.
@MainActor
struct RevealPacingTests {
    @Test func aShortDeltaRevealsFasterThanALongOne() {
        let short = RevealPacing.duration(pendingCharacters: 40, interruptions: 0)
        let long = RevealPacing.duration(pendingCharacters: 200, interruptions: 0)
        #expect(short < long)
        #expect(short >= RevealPacing.minDuration)
    }

    @Test func aParagraphIsCappedRatherThanScalingForever() {
        #expect(RevealPacing.duration(pendingCharacters: 5_000, interruptions: 0) == RevealPacing.maxDuration)
    }

    @Test func nothingPendingTakesNoTime() {
        #expect(RevealPacing.duration(pendingCharacters: 0, interruptions: 3) == 0)
    }

    @Test func eachInterruptionShortensTheReveal() {
        let durations = (0...4).map { RevealPacing.duration(pendingCharacters: 200, interruptions: $0) }
        #expect(durations == durations.sorted(by: >))
        #expect(durations.allSatisfy { $0 >= RevealPacing.minDuration })
    }

    @Test func theSpeedUpBottomsOutSoAStreamSettlesAtAPace() {
        #expect(RevealPacing.speedup(interruptions: 0) == 1)
        #expect(RevealPacing.speedup(interruptions: 100) == RevealPacing.minSpeedup)
    }

    @Test func theFirstTextSeenIsShownWithoutAnimating() {
        var progress = RevealProgress()
        #expect(progress.advance(to: "Hello") == nil)
        #expect(progress.revealedCount == 5)
    }

    @Test func laterTextAnimates() {
        var progress = RevealProgress()
        let start = Date()
        _ = progress.advance(to: "Hello", now: start)
        #expect(progress.advance(to: "Hello, world", now: start) != nil)
        #expect(progress.revealedCount == 12)
    }

    @Test func aRestartSnapsRatherThanRewindingThroughAnAnimation() {
        var progress = RevealProgress()
        let start = Date()
        _ = progress.advance(to: "A long first turn", now: start)
        _ = progress.advance(to: "A long first turn, continued", now: start)
        #expect(progress.advance(to: "New", now: start) == nil)
        #expect(progress.revealedCount == 3)
    }

    /// The deltas here all land inside the previous reveal's window, so each
    /// one counts as an interruption and shortens what follows.
    @Test func deltasArrivingMidRevealCompoundTheSpeedUp() {
        var progress = RevealProgress()
        var text = String(repeating: "x", count: 200)
        let start = Date()
        _ = progress.advance(to: text, now: start)

        var animations: [Animation?] = []
        for step in 1...4 {
            text += String(repeating: "x", count: 200)
            animations.append(progress.advance(to: text, now: start.addingTimeInterval(Double(step) * 0.01)))
        }
        // The first delta lands from rest; every later one interrupts.
        let expected: [Animation] = [.easeOut(duration: RevealPacing.duration(pendingCharacters: 200, interruptions: 0))]
            + (1...3).map { .linear(duration: RevealPacing.duration(pendingCharacters: 200, interruptions: $0)) }
        #expect(animations == expected.map { Optional($0) })
    }

    /// A reveal from rest eases out; one retargeted mid-flight runs linearly,
    /// so the curve names which case the progress decided it was in.
    @Test func aDeltaAfterTheRevealFinishedStartsFromRestAgain() {
        var progress = RevealProgress()
        let start = Date()
        _ = progress.advance(to: String(repeating: "x", count: 200), now: start)

        let fromRest = progress.advance(to: String(repeating: "x", count: 400), now: start)
        #expect(fromRest == .easeOut(duration: RevealPacing.duration(pendingCharacters: 200, interruptions: 0)))

        let midReveal = progress.advance(to: String(repeating: "x", count: 600), now: start.addingTimeInterval(0.01))
        #expect(midReveal == .linear(duration: RevealPacing.duration(pendingCharacters: 200, interruptions: 1)))

        // Well past the deadline, so this one is not an interruption.
        let afterRest = progress.advance(to: String(repeating: "x", count: 800), now: start.addingTimeInterval(10))
        #expect(afterRest == .easeOut(duration: RevealPacing.duration(pendingCharacters: 200, interruptions: 0)))
    }
}

/// Where `CharacterReveal` cuts a string so it always stops on a word
/// boundary, never mid-word — the mechanism behind revealing by word.
@MainActor
struct RevealWordBoundariesTests {
    private func prefix(_ text: String, _ count: Int) -> String {
        String(text.prefix(RevealWordBoundaries.prefixLength(of: text, upTo: count)))
    }

    @Test func fullLengthReturnsTheWholeString() {
        let text = "Hello, world"
        #expect(RevealWordBoundaries.prefixLength(of: text, upTo: text.count) == text.count)
        #expect(RevealWordBoundaries.prefixLength(of: text, upTo: text.count + 5) == text.count)
    }

    @Test func zeroReturnsNothing() {
        #expect(RevealWordBoundaries.prefixLength(of: "Hello", upTo: 0) == 0)
    }

    @Test func aWordAndItsClosingDelimiterRevealTogether() {
        let text = "Hello, **world**! end."
        // Mid-word: "world" without its "**" would flash as an opening bold
        // marker with no matching close.
        for count in 10...17 {
            #expect(prefix(text, count) == "Hello, **")
        }
        #expect(prefix(text, 18) == "Hello, **world**! ")
    }

    @Test func cjkRevealsInSmallRunsRatherThanAllAtOnce() {
        let text = "你好世界 done"
        // No whitespace inside the run, so a plain split on spaces would
        // reveal all four characters in one jump; word boundaries keep the
        // usual small steps instead.
        #expect(prefix(text, 1) == "你")
        #expect(prefix(text, 2) == "你好")
        #expect(prefix(text, 4) == "你好")
        #expect(prefix(text, 5) == "你好世界 ")
    }

    @Test func aStreamingTailShowsAsMuchAsHasArrived() {
        // The word in progress has no closing punctuation yet, so it should
        // still show what has streamed in rather than waiting for a
        // boundary that has not happened.
        let partial = "The **bol"
        #expect(prefix(partial, partial.count) == partial)
    }

    @Test func emptyTextRevealsNothing() {
        #expect(RevealWordBoundaries.prefixLength(of: "", upTo: 0) == 0)
        #expect(RevealWordBoundaries.prefixLength(of: "", upTo: 5) == 0)
    }
}

/// `WordFade.step` throttles how often the streaming overlay's prose
/// cross-fades a newly-revealed word: see `docs/handoff-idle-cpu.md`-style
/// evidence in `WordFade`'s own doc comment for why a wider bucket than
/// `RevealPacing.charactersPerSecond * WordFade.duration` matters.
struct WordFadeTests {
    @Test func theBucketWidensLessOftenThanEveryCharacter() {
        #expect(WordFade.step(forPrefixLength: 0) == 0)
        #expect(WordFade.step(forPrefixLength: WordFade.charactersPerFade - 1) == 0)
        #expect(WordFade.step(forPrefixLength: WordFade.charactersPerFade) == 1)
        #expect(WordFade.step(forPrefixLength: WordFade.charactersPerFade * 2 - 1) == 1)
    }

    @Test func theStepIsMonotonicAsThePrefixGrows() {
        let steps = (0...200).map { WordFade.step(forPrefixLength: $0) }
        #expect(steps == steps.sorted())
    }

    /// The measurement that set `charactersPerFade`: a bucket narrower than
    /// one fade's worth of reveal time lets consecutive fades overlap and
    /// keeps a transparency layer open continuously. Widening past that
    /// threshold is what took streaming CPU from ~84% of a core back to the
    /// no-fade baseline.
    @Test func theBucketWidthClearsOneFadeAtTheFastestRevealRate() {
        let charactersPerFadeDuration = RevealPacing.charactersPerSecond * WordFade.duration
        #expect(Double(WordFade.charactersPerFade) > charactersPerFadeDuration)
    }
}
