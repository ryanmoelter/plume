import Testing
import Foundation
@testable import Plume

/// A newly mentioned issue lingers among the working issues, then settles
/// into the Mentioned section. An issue already mentioned on a task's first
/// observation settles at once.
@MainActor
struct LinearMentionTrackerTests {
    private let task = UUID()

    @Test func theFirstObservationPreSettlesWhatIsAlreadyMentioned() {
        let tracker = LinearMentionTracker(linger: .seconds(30))

        tracker.observe(mentioned: ["PLUME-1"], taskID: task)

        #expect(tracker.hasSettled("PLUME-1", taskID: task))
    }

    @Test func aLaterMentionIsUnsettledThenSettlesAfterTheLinger() async throws {
        let tracker = LinearMentionTracker(linger: .milliseconds(50))
        tracker.observe(mentioned: [], taskID: task)

        tracker.observe(mentioned: ["PLUME-2"], taskID: task)
        #expect(!tracker.hasSettled("PLUME-2", taskID: task))

        try await Task.sleep(for: .milliseconds(200))
        #expect(tracker.hasSettled("PLUME-2", taskID: task))
    }

    @Test func anIssueThatLeavesAndReturnsGetsAFreshLinger() async throws {
        let tracker = LinearMentionTracker(linger: .milliseconds(50))
        tracker.observe(mentioned: [], taskID: task)
        tracker.observe(mentioned: ["PLUME-2"], taskID: task)
        try await Task.sleep(for: .milliseconds(200))
        #expect(tracker.hasSettled("PLUME-2", taskID: task))

        tracker.observe(mentioned: [], taskID: task)
        tracker.observe(mentioned: ["PLUME-2"], taskID: task)

        #expect(!tracker.hasSettled("PLUME-2", taskID: task))
    }

    @Test func aPreSettledIssueThatLeavesAndReturnsLingers() {
        let tracker = LinearMentionTracker(linger: .seconds(30))
        tracker.observe(mentioned: ["PLUME-1"], taskID: task)

        tracker.observe(mentioned: [], taskID: task)
        tracker.observe(mentioned: ["PLUME-1"], taskID: task)

        #expect(!tracker.hasSettled("PLUME-1", taskID: task))
    }

    @Test func forgettingATaskResetsItsFirstObservation() {
        let tracker = LinearMentionTracker(linger: .seconds(30))
        tracker.observe(mentioned: [], taskID: task)
        tracker.observe(mentioned: ["PLUME-2"], taskID: task)
        #expect(!tracker.hasSettled("PLUME-2", taskID: task))

        tracker.forget(taskID: task)
        #expect(!tracker.hasSettled("PLUME-2", taskID: task))

        tracker.observe(mentioned: ["PLUME-2"], taskID: task)
        #expect(tracker.hasSettled("PLUME-2", taskID: task))
    }

    @Test func tasksAreTrackedIndependently() {
        let tracker = LinearMentionTracker(linger: .seconds(30))
        let other = UUID()
        tracker.observe(mentioned: [], taskID: task)
        tracker.observe(mentioned: ["PLUME-2"], taskID: task)

        tracker.observe(mentioned: ["PLUME-2"], taskID: other)

        #expect(!tracker.hasSettled("PLUME-2", taskID: task))
        #expect(tracker.hasSettled("PLUME-2", taskID: other))
    }
}
