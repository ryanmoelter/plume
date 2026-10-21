import Testing
import Foundation
@testable import Plume

/// A newly mentioned issue lingers among the working issues, then settles
/// into the Mentioned section. An issue already mentioned on a task's first
/// observation settles at once.
@MainActor
struct LinearMentionTrackerTests {
    private let task = UUID()

    private func settles(_ tracker: LinearMentionTracker, _ identifier: String) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !tracker.hasSettled(identifier, taskID: task) {
            try #require(ContinuousClock.now < deadline, "linger never elapsed")
            try await Task.sleep(for: .milliseconds(10))
        }
    }

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

        try await settles(tracker, "PLUME-2")
    }

    @Test func anIssueThatLeavesAndReturnsGetsAFreshLinger() async throws {
        let tracker = LinearMentionTracker(linger: .milliseconds(50))
        tracker.observe(mentioned: [], taskID: task)
        tracker.observe(mentioned: ["PLUME-2"], taskID: task)
        try await settles(tracker, "PLUME-2")

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
        tracker.observe(mentioned: ["PLUME-2"], taskID: task)
        tracker.observe(mentioned: ["PLUME-2", "PLUME-3"], taskID: task)

        #expect(tracker.hasSettled("PLUME-2", taskID: task))
        #expect(!tracker.hasSettled("PLUME-3", taskID: task))
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

    @Test func settleEndsTheLingerAtOnce() {
        let tracker = LinearMentionTracker(linger: .seconds(30))
        tracker.observe(mentioned: [], taskID: task)
        tracker.observe(mentioned: ["PLUME-2"], taskID: task)
        #expect(!tracker.hasSettled("PLUME-2", taskID: task))

        tracker.settle("PLUME-2", taskID: task)

        #expect(tracker.hasSettled("PLUME-2", taskID: task))
        tracker.observe(mentioned: ["PLUME-2"], taskID: task)
        #expect(tracker.hasSettled("PLUME-2", taskID: task))
    }

    @Test func aSettledIssueThatLeavesAndReturnsLingersAgain() {
        let tracker = LinearMentionTracker(linger: .seconds(30))
        tracker.observe(mentioned: [], taskID: task)
        tracker.observe(mentioned: ["PLUME-2"], taskID: task)
        tracker.settle("PLUME-2", taskID: task)

        tracker.observe(mentioned: [], taskID: task)
        tracker.observe(mentioned: ["PLUME-2"], taskID: task)

        #expect(!tracker.hasSettled("PLUME-2", taskID: task))
    }

    @Test func aTaskNeverObservedReadsAsSettled() {
        let tracker = LinearMentionTracker(linger: .seconds(30))
        #expect(tracker.hasSettled("PLUME-1", taskID: task))
    }
}
