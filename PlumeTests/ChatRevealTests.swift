import Foundation
import SwiftUI
import Testing
@testable import Plume

/// `RevealSpring`: the damped spring that pulls a message's reveal position
/// toward the characters it has received so far.
@MainActor
struct RevealSpringTests {
    private let tuning = RevealTuning.Values(
        response: 0.3,
        dampingRatio: 1,
        minimumSpeed: 40,
        maximumSpeed: 0,
        fadeDuration: 0.3,
        frameRate: 120
    )

    @Test func stepNeverPassesTheTarget() {
        var spring = RevealSpring(position: 0, velocity: 0)
        for _ in 0..<200 {
            spring.step(toward: 100, by: 1.0 / 60, tuning: tuning)
            #expect(spring.position <= 100)
        }
    }

    @Test func stepReachesTheTargetEventually() {
        var spring = RevealSpring(position: 0, velocity: 0)
        for _ in 0..<600 {
            spring.step(toward: 100, by: 1.0 / 60, tuning: tuning)
            if spring.position >= 100 { break }
        }
        #expect(spring.position == 100)
        #expect(spring.velocity == 0)
    }

    /// The floor that keeps a reveal from idling short of text it already
    /// has, even when the spring's own pull would be gentler than that.
    @Test func stepNeverDropsBelowTheMinimumSpeedWhileBehind() {
        let slow = RevealTuning.Values(response: 5, dampingRatio: 1, minimumSpeed: 40, maximumSpeed: 0, fadeDuration: 0.3, frameRate: 120)
        var spring = RevealSpring(position: 0, velocity: 0)
        spring.step(toward: 100, by: 1.0 / 60, tuning: slow)
        #expect(spring.velocity >= slow.minimumSpeed)
    }

    @Test func stepNeverExceedsTheMaximumSpeed() {
        let capped = RevealTuning.Values(response: 0.05, dampingRatio: 1, minimumSpeed: 0, maximumSpeed: 50, fadeDuration: 0.3, frameRate: 120)
        var spring = RevealSpring(position: 0, velocity: 0)
        for _ in 0..<600 {
            spring.step(toward: 100_000, by: 1.0 / 60, tuning: capped)
            #expect(spring.velocity <= capped.maximumSpeed)
        }
    }

    @Test func stepNeverMovesBackward() {
        var spring = RevealSpring(position: 0, velocity: 0)
        var previous = spring.position
        for _ in 0..<200 {
            spring.step(toward: 100, by: 1.0 / 60, tuning: tuning)
            #expect(spring.position >= previous)
            previous = spring.position
        }
    }

    /// A message growing mid-reveal retargets the same spring rather than
    /// starting a new one, so the pace it had built up must carry through.
    @Test func velocityCarriesThroughARetargetBeforeSettling() {
        var spring = RevealSpring(position: 0, velocity: 0)
        spring.step(toward: 1_000, by: 0.05, tuning: tuning)
        #expect(spring.position < 1_000)
        let velocityBeforeRetarget = spring.velocity
        #expect(velocityBeforeRetarget > 0)

        // A bigger target arrives before the spring reached the old one; one
        // more tiny step should continue accelerating, not restart from rest.
        spring.step(toward: 2_000, by: 1.0 / 240, tuning: tuning)
        #expect(spring.velocity > velocityBeforeRetarget * 0.9)
    }
}

/// `WordReveal`: fades a `Text`'s words in as the reveal crosses them.
@MainActor
struct WordRevealTests {
    /// Markdown and a multi-unit emoji in one string, so counting `Character`s
    /// instead of UTF-16 units would give the wrong offsets.
    @Test func wordStartsAlwaysBeginsAtZeroInUTF16Units() {
        let starts = WordReveal.wordStarts(in: "Hi there, 👋🏽 friend")
        #expect(starts == [0, 3, 15])
    }

    @Test func wordContainingFindsTheWordHoldingAnIndex() {
        let starts = [0, 3, 15]
        #expect(WordReveal.word(containing: 5, in: starts, length: 20) == 3..<15)
        #expect(WordReveal.word(containing: 8, in: starts, length: 20) == 3..<15)
        #expect(WordReveal.word(containing: 16, in: starts, length: 20) == 15..<20)
    }

    @Test func aWordIsHiddenUntilTheRevealReachesIt() {
        let reveal = WordReveal(position: 5, wordStarts: [0, 5], length: 10)
        #expect(reveal.opacity(at: 7) == 0)
    }

    @Test func withoutTimingAWordShowsWholeOnceReached() {
        let reveal = WordReveal(position: 5.5, wordStarts: [0, 5], length: 10)
        #expect(reveal.opacity(at: 7) == 1)
    }
}

/// `ChatReveal.length(of:)`: how many characters of a piece the reveal
/// crosses, counted the way `Text.Layout` counts them.
@MainActor
struct ChatRevealLengthTests {
    @Test func paragraphCountsRenderedCharactersNotMarkdown() {
        #expect(ChatReveal.length(of: .paragraph("**bold** x")) == 6)
    }

    @Test func listSumsEachItemsRenderedText() {
        let items = [
            MarkdownBlock.ListItem(text: "one"),
            MarkdownBlock.ListItem(text: "two")
        ]
        #expect(ChatReveal.length(of: .list(items)) == 6)
    }

    @Test func codeBlockCountsUTF16Units() {
        let code = "let x = 1"
        #expect(ChatReveal.length(of: .codeBlock(language: "swift", code: code)) == code.utf16.count)
    }

    @Test func mermaidCodeHasNoRevealLength() {
        #expect(ChatReveal.length(of: .codeBlock(language: "mermaid", code: "graph TD\nA-->B")) == 0)
    }

    @Test func tableIncludesTheHeaderOnlyWhenItIsMeaningful() {
        let meaningful = MarkdownBlock.table(header: ["Name", "Age"], alignments: [.leading, .leading], rows: [["Alice", "30"]])
        let blank = MarkdownBlock.table(header: ["", ""], alignments: [.leading, .leading], rows: [["Alice", "30"]])
        let rowsLength = "Alice".count + "30".count
        #expect(ChatReveal.length(of: meaningful) == "Name".count + "Age".count + rowsLength)
        #expect(ChatReveal.length(of: blank) == rowsLength)
    }

    @Test func tableCellOffsetsAccumulateAcrossCellsInOrder() {
        let header = ["Name", "Age"]
        let rows = [["Alice", "30"]]
        // Header first (it's meaningful here), then the body, row-major.
        #expect(ChatReveal.tableCellOffsets(header: header, rows: rows) == [0, 4, 7, 12])
    }
}

/// `ChatRevealModel`: settles history instantly and only reveals what
/// arrives after the first update, per message.
@MainActor
struct ChatRevealModelTests {
    @Test func theFirstUpdateSettlesEverythingAtItsTarget() {
        let model = ChatRevealModel()
        model.update(targets: [(messageID: "a", length: 40)])
        let reveal = model.reveal(for: "a")
        #expect(reveal?.position == 40)
        #expect(reveal?.isSettled == true)
    }

    /// Guarded on the live setting: with animation off, `update` settles
    /// every message immediately, so there is nothing to test here.
    @Test func aMessageAddedAfterPrimingStartsFromZero() throws {
        guard AppSettings.shared.animateCharacterReveal else { return }
        let model = ChatRevealModel()
        model.update(targets: [(messageID: "a", length: 40)])
        model.update(targets: [(messageID: "a", length: 40), (messageID: "b", length: 20)])
        let reveal = try #require(model.reveal(for: "b"))
        #expect(reveal.position == 0)
        #expect(reveal.target == 20)
    }

    @Test func advanceMovesAnUnsettledRevealTowardItsTarget() throws {
        guard AppSettings.shared.animateCharacterReveal else { return }
        let model = ChatRevealModel()
        model.update(targets: [(messageID: "a", length: 40)])
        model.update(targets: [(messageID: "a", length: 40), (messageID: "b", length: 100)])
        let reveal = try #require(model.reveal(for: "b"))
        #expect(!reveal.isSettled)
        model.advance(by: 0.5)
        #expect(reveal.position > 0)
        #expect(reveal.position <= 100)
    }
    @Test func aPieceIsHeldUntilTheRevealReachesItsOffset() {
        guard AppSettings.shared.animateCharacterReveal else { return }
        let model = ChatRevealModel()
        model.update(targets: [(messageID: "a", length: 0)])
        model.update(targets: [(messageID: "a", length: 0), (messageID: "b", length: 100)])
        var later = ChatPiece(id: "b/1", messageID: "b", role: .assistant, content: .thinking(""), wash: .none)
        later.revealOffset = 50
        #expect(!model.hasReached(later))

        var fired = 0
        model.watch(["b": 50]) { fired += 1 }
        for _ in 0..<600 where !model.hasReached(later) { model.advance(by: 1.0 / 60) }
        #expect(model.hasReached(later))
        #expect(fired == 1)
    }

    @Test func onlyAMessageStillRevealingHasAnUnsettledTarget() {
        guard AppSettings.shared.animateCharacterReveal else { return }
        let model = ChatRevealModel()
        model.update(targets: [(messageID: "a", length: 40)])
        #expect(model.unsettledTargets.isEmpty)

        model.update(targets: [(messageID: "a", length: 40), (messageID: "b", length: 100)])
        #expect(model.unsettledTargets == ["b": 100])

        for _ in 0..<600 where !model.unsettledTargets.isEmpty { model.advance(by: 1.0 / 60) }
        #expect(model.unsettledTargets.isEmpty)
    }
}

/// Confirms `Text.Layout.CharacterIndex` counts the same unit
/// `ChatReveal.length` does: UTF-16, not `Character`s or source characters.
@MainActor
struct ChatRevealLayoutUnitTests {
    @Test func theLayoutCountsTheSameUnitAsTheLength() throws {
        let markdown = "Café 👋🏽 **naïve** text"
        let recorder = IndexRecorder()
        let renderer = ImageRenderer(content: Text(MarkdownCache.inline(markdown))
            .textRenderer(recorder)
            .frame(width: 400))
        _ = renderer.nsImage
        let indices = try #require(recorder.box.indices.isEmpty ? nil : recorder.box.indices)
        let span = try #require(indices.first).distance(to: try #require(indices.last))
        #expect(span == ChatReveal.length(of: markdown) - 1)
    }
}

private final class IndexBox {
    var indices: [Text.Layout.CharacterIndex] = []
}

private struct IndexRecorder: TextRenderer {
    let box = IndexBox()

    func draw(layout: Text.Layout, in ctx: inout GraphicsContext) {
        for line in layout {
            for run in line {
                box.indices.append(contentsOf: run.characterIndices)
                ctx.draw(run)
            }
        }
    }
}

struct RevealTimedFadeTests {
    private let samples = [
        RevealSample(time: 10, position: 0),
        RevealSample(time: 11, position: 100)
    ]

    @Test func aPositionIsReachedWhenTheSamplesPassIt() {
        #expect(RevealSample.time(reaching: 25, in: samples) == 10.25)
        #expect(RevealSample.time(reaching: 0, in: samples) == -.infinity)
        #expect(RevealSample.time(reaching: 150, in: samples) == .infinity)
    }

    @Test func aWordFadesOverTheDurationFromWhenTheRevealReachedIt() {
        // The reveal reached 25 at t = 10.25, so at 10.5 a 0.5s fade is half in.
        let frame = RevealFrame(position: 100, time: 10.5, faded: 0, samples: samples)
        let reveal = WordReveal(
            position: 100,
            wordStarts: [0, 25],
            length: 100,
            timing: .init(offset: 0, frame: frame, duration: 0.5)
        )
        #expect(abs(reveal.opacity(at: 30) - 0.5) < 0.0001)
    }

    @Test func aWordReachedBeforeTheSamplesIsWhole() {
        let frame = RevealFrame(position: 100, time: 10.5, faded: 0, samples: samples)
        let reveal = WordReveal(
            position: 100,
            wordStarts: [0, 25],
            length: 100,
            timing: .init(offset: 0, frame: frame, duration: 0.5)
        )
        #expect(reveal.opacity(at: 3) == 1)
    }
}
