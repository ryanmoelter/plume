import Foundation
import Testing
@testable import Plume

@MainActor
struct CommandModeRunsTests {
    @Test func aFinishedRunWaitsToBeRetired() async throws {
        let runs = CommandModeRuns()
        let tabID = UUID()
        let result = await withCheckedContinuation { continuation in
            runs.start("echo hi", in: nil, tabID: tabID) { continuation.resume(returning: $0) }
            #expect(runs.runs(forTab: tabID).map(\.command) == ["echo hi"])
        }
        #expect(result.stdout == "hi")

        // The chip stays up until its output is actually on the wire: the
        // text it carries is tagged markup, not the command the user ran.
        let run = try #require(runs.runs(forTab: tabID).first)
        #expect(run.isQueued)
        #expect(runs.queuedText(forTab: tabID) == [result.transcriptText])

        runs.finish(run.id, tabID: tabID)
        #expect(runs.runs(forTab: tabID).isEmpty)
        #expect(runs.queuedText(forTab: tabID).isEmpty)
    }

    @Test func aCancelledRunSendsNothing() async throws {
        let runs = CommandModeRuns()
        let tabID = UUID()
        var delivered = false
        runs.start("sleep 60", in: nil, tabID: tabID) { _ in delivered = true }
        let run = try #require(runs.runs(forTab: tabID).first)

        runs.cancel(run.id, tabID: tabID)
        #expect(runs.runs(forTab: tabID).isEmpty)
        // Long enough for the killed command's result to come back.
        try await Task.sleep(for: .seconds(1))
        #expect(!delivered)
    }

    @Test func forgettingATabCancelsItsRuns() async throws {
        let runs = CommandModeRuns()
        let tabID = UUID()
        var delivered = false
        runs.start("sleep 60", in: nil, tabID: tabID) { _ in delivered = true }

        runs.forget(tabID: tabID)
        #expect(runs.runs(forTab: tabID).isEmpty)
        try await Task.sleep(for: .seconds(1))
        #expect(!delivered)
    }
}

/// A command's output is queued like any other turn, but its own chip already
/// tells that story — so the queued list hides it. The list's visibility has
/// to follow the filtered result, not the raw queue.
@MainActor
struct QueuedProseTests {
    private let command = "<bash-input>ls</bash-input>\n<bash-stdout>foo</bash-stdout><bash-stderr></bash-stderr>"

    @Test func aCommandsOutputIsLeftToItsChip() {
        let prose = ChatTabView.prose(
            in: [[.text(command)]],
            spokenFor: [command]
        )
        #expect(prose.isEmpty)
    }

    @Test func aTypedMessageStillShows() {
        let prose = ChatTabView.prose(
            in: [[.text("hello")]],
            spokenFor: [command]
        )
        #expect(prose.map(\.element.plainText) == ["hello"])
    }

    /// The offset indexes the real queue, since removing a row calls through
    /// to `removeQueuedMessage(at:)` — a filtered index would drop the wrong
    /// message.
    @Test func offsetsIndexTheUnfilteredQueue() {
        let prose = ChatTabView.prose(
            in: [[.text(command)], [.text("hello")]],
            spokenFor: [command]
        )
        #expect(prose.map(\.offset) == [1])
    }
}

/// Retiring the last run empties the chip list, so whatever observes the
/// queue has to outlive that list — otherwise the run stays queued, its text
/// stays "spoken for", and the message it stood in for is hidden forever.
@MainActor
struct RunRetirementTests {
    @Test func retiringTheLastRunClearsWhatItSpokeFor() async throws {
        let runs = CommandModeRuns()
        let tabID = UUID()
        let result = await withCheckedContinuation { continuation in
            runs.start("echo hi", in: nil, tabID: tabID) { continuation.resume(returning: $0) }
        }
        let run = try #require(runs.runs(forTab: tabID).first)
        #expect(runs.queuedText(forTab: tabID) == [result.transcriptText])

        runs.finish(run.id, tabID: tabID)

        // Nothing is spoken for any more, so a queued message with this text
        // would show rather than stay hidden behind a chip that is gone.
        #expect(runs.queuedText(forTab: tabID).isEmpty)
        #expect(ChatTabView.prose(
            in: [[.text(result.transcriptText)]],
            spokenFor: runs.queuedText(forTab: tabID)
        ).count == 1)
    }
}
