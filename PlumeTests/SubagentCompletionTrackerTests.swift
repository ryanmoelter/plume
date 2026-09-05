import Testing
import Foundation
@testable import Plume

/// Holding a finished subagent among the live rows for its linger, then
/// letting it settle into the completed section.
@MainActor
struct SubagentCompletionTrackerTests {
    private func subagent(_ id: String, _ status: TaskStatus) -> SubagentTranscript {
        SubagentTranscript(id: id, transcript: Transcript(), modifiedAt: nil, descriptor: nil, status: status)
    }

    @Test func aWorkingSubagentNeverSettles() {
        let tracker = SubagentCompletionTracker(linger: .zero)
        let working = subagent("a1", .working)

        tracker.observe([working])

        #expect(!tracker.hasSettled(working))
    }

    @Test func aFinishedSubagentStaysLiveForItsLinger() {
        let tracker = SubagentCompletionTracker(linger: .seconds(30))
        let done = subagent("a1", .done)

        tracker.observe([done])

        #expect(!tracker.hasSettled(done))
    }

    @Test func aFinishedSubagentSettlesOnceTheLingerElapses() async throws {
        let tracker = SubagentCompletionTracker(linger: .milliseconds(20))
        let done = subagent("a1", .done)

        tracker.observe([done])
        try await Task.sleep(for: .milliseconds(80))

        #expect(tracker.hasSettled(done))
    }

    /// A failure is finished too, so it folds away like a success.
    @Test func aFailedSubagentSettlesAsWell() async throws {
        let tracker = SubagentCompletionTracker(linger: .milliseconds(20))
        let failed = subagent("a1", .error)

        tracker.observe([failed])
        try await Task.sleep(for: .milliseconds(80))

        #expect(tracker.hasSettled(failed))
    }

    /// The clock starts when Plume first sees the subagent finish, so
    /// re-observing an already-settled one does not restart its linger.
    @Test func reobservingDoesNotRestartTheLinger() async throws {
        let tracker = SubagentCompletionTracker(linger: .milliseconds(20))
        let done = subagent("a1", .done)

        tracker.observe([done])
        try await Task.sleep(for: .milliseconds(80))
        tracker.observe([done])

        #expect(tracker.hasSettled(done))
    }

    /// A subagent that goes back to work rejoins the live rows and earns a
    /// fresh linger when it finishes again.
    @Test func returningToWorkClearsTheCompletion() async throws {
        let tracker = SubagentCompletionTracker(linger: .milliseconds(20))
        let done = subagent("a1", .done)

        tracker.observe([done])
        try await Task.sleep(for: .milliseconds(80))
        tracker.observe([subagent("a1", .working)])

        #expect(!tracker.hasSettled(done))

        tracker.observe([done])
        #expect(!tracker.hasSettled(done))
    }

    /// A subagent waiting on a person is not finished — it needs to stay
    /// visible rather than fold away.
    @Test func aSubagentNeedingInputNeverSettles() async throws {
        let tracker = SubagentCompletionTracker(linger: .milliseconds(20))
        let waiting = subagent("a1", .needsInput)

        tracker.observe([waiting])
        try await Task.sleep(for: .milliseconds(80))

        #expect(!tracker.hasSettled(waiting))
    }
}
