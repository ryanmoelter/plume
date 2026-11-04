import Foundation
import Testing
@testable import Plume

/// A Running item's chips: unsettled subagents in store order, then
/// background tasks, and none at all on an item that isn't running.
struct HomeSideWorkTests {
    private func subagent(_ id: String, type: String?, status: TaskStatus) -> SubagentTranscript {
        SubagentTranscript(
            id: id,
            transcript: Transcript(),
            modifiedAt: nil,
            descriptor: SubagentDescriptor(description: "do \(id)", agentType: type),
            status: status
        )
    }

    private func background(_ id: String, _ kind: BackgroundTaskTracker.Kind) -> BackgroundTaskTracker.Entry {
        BackgroundTaskTracker.Entry(id: id, kind: kind, startedAt: Date(), expiresAt: nil)
    }

    @Test func subagentsLeadBackgroundTasksAndSettledOnesAreDropped() {
        let items = HomeSideWork.items(
            subagents: [
                subagent("a", type: "Explore", status: .working),
                subagent("b", type: "Plan", status: .done),
                subagent("c", type: nil, status: .done),
            ],
            hasSettled: { $0.id == "b" },
            backgroundTasks: [background("m", .monitor), background("w", .workflow)]
        )
        #expect(items.map(\.typeName) == ["Explore", "Agent", "Monitor", "Workflow"])
        #expect(items.map(\.status) == [.working, .done, .working, .working])
        #expect(items.first?.detail == "do a")
    }

    @Test func aSubagentAndABackgroundTaskSharingAnIDStayDistinct() {
        let items = HomeSideWork.items(
            subagents: [subagent("x", type: "Explore", status: .working)],
            hasSettled: { _ in false },
            backgroundTasks: [background("x", .backgroundCommand)]
        )
        #expect(Set(items.map(\.id)).count == 2)
    }

    @Test func onlyARunningItemCarriesItsSideWork() {
        let work = HomeSideWork.items(
            subagents: [],
            hasSettled: { _ in false },
            backgroundTasks: [background("m", .monitor)]
        )
        func entry(_ status: TaskStatus) -> HomeFeed.Entry {
            var entry = HomeFeed.Entry(
                taskID: UUID(), tabID: UUID(), taskTitle: "Task", tabTitle: "Tab",
                status: status, hasSession: true
            )
            entry.sideWork = work
            return entry
        }
        let feed = HomeFeed(entries: [entry(.working), entry(.waitingOnSubagents), entry(.awaitingReply)])
        #expect(feed.running.map(\.sideWork) == [work, work])
        #expect(feed.idle.map(\.sideWork) == [[]])
    }
}
