import Testing
import Foundation
@testable import Plume

/// Holding a finished subagent among the live rows for its linger, then
/// letting it settle into the completed section — including across the view
/// being unmounted, which is what selecting another task does.
@MainActor
struct SubagentCompletionTrackerTests {
    private let tab = UUID()

    private func subagent(_ id: String, _ status: TaskStatus) -> SubagentTranscript {
        SubagentTranscript(id: id, transcript: Transcript(), modifiedAt: nil, descriptor: nil, status: status)
    }

    @Test func aWorkingSubagentNeverSettles() {
        let tracker = SubagentCompletionTracker(linger: .zero)
        let working = subagent("a1", .working)

        tracker.observe([working], tabID: tab)

        #expect(!tracker.hasSettled(working, tabID: tab))
    }

    @Test func aFinishedSubagentStaysLiveForItsLinger() {
        let tracker = SubagentCompletionTracker(linger: .seconds(30))
        let done = subagent("a1", .done)

        tracker.observe([done], tabID: tab)

        #expect(!tracker.hasSettled(done, tabID: tab))
    }

    @Test func aFinishedSubagentSettlesOnceTheLingerElapses() async throws {
        let tracker = SubagentCompletionTracker(linger: .milliseconds(20))
        let done = subagent("a1", .done)

        tracker.observe([done], tabID: tab)
        try await Task.sleep(for: .milliseconds(80))

        #expect(tracker.hasSettled(done, tabID: tab))
    }

    /// A failure is finished too, so it folds away like a success.
    @Test func aFailedSubagentSettlesAsWell() async throws {
        let tracker = SubagentCompletionTracker(linger: .milliseconds(20))
        let failed = subagent("a1", .error)

        tracker.observe([failed], tabID: tab)
        try await Task.sleep(for: .milliseconds(80))

        #expect(tracker.hasSettled(failed, tabID: tab))
    }

    /// The clock starts when Plume first sees the subagent finish, so
    /// re-observing an already-settled one does not restart its linger.
    @Test func reobservingDoesNotRestartTheLinger() async throws {
        let tracker = SubagentCompletionTracker(linger: .milliseconds(20))
        let done = subagent("a1", .done)

        tracker.observe([done], tabID: tab)
        try await Task.sleep(for: .milliseconds(80))
        tracker.observe([done], tabID: tab)

        #expect(tracker.hasSettled(done, tabID: tab))
    }

    /// A subagent that goes back to work rejoins the live rows and earns a
    /// fresh linger when it finishes again.
    @Test func returningToWorkClearsTheCompletion() async throws {
        let tracker = SubagentCompletionTracker(linger: .milliseconds(20))
        let done = subagent("a1", .done)

        tracker.observe([done], tabID: tab)
        try await Task.sleep(for: .milliseconds(80))
        tracker.observe([subagent("a1", .working)], tabID: tab)

        #expect(!tracker.hasSettled(done, tabID: tab))

        tracker.observe([done], tabID: tab)
        #expect(!tracker.hasSettled(done, tabID: tab))
    }

    /// The bug this store exists to fix: selecting another task unmounts the
    /// chat, so a view that owned the tracker forgot when the row finished and
    /// restarted its countdown on the way back. A lookup from a fresh view has
    /// to find the linger already part-elapsed.
    @Test func aLingerSurvivesTheViewThatStartedIt() async throws {
        // Long enough that no scheduling delay can elapse it mid-test; the
        // point is that re-observing does not reset the clock, not the timing.
        let tracker = SubagentCompletionTracker(linger: .seconds(30))
        let done = subagent("a1", .done)

        tracker.observe([done], tabID: tab)
        let started = tracker.completionInstant(forSubagentID: "a1", tabID: tab)

        // Coming back to the task re-observes from scratch.
        tracker.observe([done], tabID: tab)

        #expect(tracker.completionInstant(forSubagentID: "a1", tabID: tab) == started)
        #expect(!tracker.hasSettled(done, tabID: tab))
    }

    /// The timer has to live in the store too, so a row whose linger elapsed
    /// while the task was off screen has already settled on return.
    @Test func aLingerElapsesWhileNoViewIsMounted() async throws {
        let tracker = SubagentCompletionTracker(linger: .milliseconds(20))
        let done = subagent("a1", .done)

        tracker.observe([done], tabID: tab)
        try await Task.sleep(for: .milliseconds(80))

        #expect(tracker.hasSettled(done, tabID: tab))
    }

    /// Two tabs can run subagents that share an id, so one tab's linger must
    /// not answer for the other's.
    @Test func lingersAreKeptPerTab() async throws {
        let tracker = SubagentCompletionTracker(linger: .milliseconds(20))
        let done = subagent("a1", .done)
        let other = UUID()

        tracker.observe([done], tabID: tab)
        try await Task.sleep(for: .milliseconds(80))

        #expect(tracker.hasSettled(done, tabID: tab))
        #expect(!tracker.hasSettled(done, tabID: other))
    }

    @Test func closingATabForgetsItsRows() async throws {
        let tracker = SubagentCompletionTracker(linger: .milliseconds(20))
        let done = subagent("a1", .done)
        let other = UUID()

        tracker.observe([done], tabID: tab)
        tracker.observe([done], tabID: other)
        try await Task.sleep(for: .milliseconds(80))

        tracker.forget(tabID: tab)

        #expect(!tracker.hasSettled(done, tabID: tab))
        #expect(tracker.hasSettled(done, tabID: other))
    }

    /// A subagent waiting on a person is not finished — it needs to stay
    /// visible rather than fold away.
    @Test func aSubagentNeedingInputNeverSettles() async throws {
        let tracker = SubagentCompletionTracker(linger: .milliseconds(20))
        let waiting = subagent("a1", .needsInput)

        tracker.observe([waiting], tabID: tab)
        try await Task.sleep(for: .milliseconds(80))

        #expect(!tracker.hasSettled(waiting, tabID: tab))
    }
}
