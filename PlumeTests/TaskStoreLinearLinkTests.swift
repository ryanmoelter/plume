import Testing
import Foundation
import SwiftData
@testable import Plume

/// The link helpers round-trip `LinearTaskLinks` through
/// `WorkTask.integrationsData` and leave it untouched when nothing changes.
@MainActor
struct TaskStoreLinearLinkTests {
    private func makeTask() throws -> (WorkTask, ModelContext) {
        let container = try ModelContainer(
            for: Schema([TaskGroup.self, WorkTask.self, TaskTab.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        return (TaskStore.createTask(in: context, siblings: []), context)
    }

    @Test func linkingNormalizesAndPersists() throws {
        let (task, context) = try makeTask()
        _ = context

        #expect(TaskStore.linkLinearIssue("https://linear.app/x/issue/plume-102/some-title", to: task))
        #expect(!TaskStore.linkLinearIssue("not an issue", to: task))

        #expect(TaskStore.linearLinks(for: task).manual == [LinearIssueRef(identifier: "PLUME-102")])
    }

    @Test func unlinkingRecordsUnlinkedAndRelinkingClearsIt() throws {
        let (task, context) = try makeTask()
        _ = context
        TaskStore.linkLinearIssue("PLUME-1", to: task)
        TaskStore.promoteLinearIssue("PLUME-2", in: task)

        TaskStore.unlinkLinearIssue("PLUME-1", from: task)
        #expect(TaskStore.linearLinks(for: task).manual.isEmpty)
        #expect(TaskStore.linearLinks(for: task).unlinked == ["PLUME-1"])
        #expect(TaskStore.linearLinks(for: task).promoted == [LinearIssueRef(identifier: "PLUME-2")])

        TaskStore.linkLinearIssue("PLUME-1", to: task)
        #expect(TaskStore.linearLinks(for: task).unlinked.isEmpty)
    }

    @Test func agentStartedIssuesLandOnTheTaskOwningTheTab() throws {
        let (task, context) = try makeTask()
        let other = TaskStore.createTask(in: context, siblings: [task])
        let tab = try #require(task.tabs.first)

        #expect(TaskStore.recordAgentStartedLinearIssues(["PLUME-3"], inTaskOwningTab: tab.id, among: [other, task]))
        let data = task.integrationsData
        TaskStore.recordAgentStartedLinearIssues(["PLUME-3"], inTaskOwningTab: tab.id, among: [other, task])

        #expect(TaskStore.linearLinks(for: task).agentStarted == [LinearIssueRef(identifier: "PLUME-3")])
        #expect(task.integrationsData == data)
        #expect(other.integrationsData == nil)
        #expect(!TaskStore.recordAgentStartedLinearIssues(["PLUME-3"], inTaskOwningTab: UUID(), among: [task]))
    }
}
