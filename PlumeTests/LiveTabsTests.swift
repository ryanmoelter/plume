import Foundation
import SwiftData
import Testing
@testable import Plume

/// A deleted task can keep listing its cascade-deleted tabs in `tabs`, even
/// after a save, while its sidebar row is still evaluated. `liveTabs` and the
/// sidebar reads built on it skip those tabs, so they never read a property of
/// a deleted model.
@MainActor
struct LiveTabsTests {
    private let context: ModelContext

    init() throws {
        let container = try ModelContainer(
            for: Schema([TaskGroup.self, WorkTask.self, TaskTab.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        context = ModelContext(container)
    }

    /// A headless agent tab that has had a session, plus a terminal tab.
    private func makeStartedTask() throws -> (WorkTask, agent: TaskTab, terminal: TaskTab) {
        let task = TaskStore.createTask(in: context, siblings: [])
        let agent = try #require(task.tabs.first)
        agent.agentSessionID = "session-1"
        agent.transport = .headless
        let terminal = TaskStore.addTab(to: task, kind: .terminal, in: context)
        try context.save()
        return (task, agent, terminal)
    }

    @Test func aDeletedTasksTabsAreNotLive() throws {
        let (task, _, _) = try makeStartedTask()
        #expect(!task.hasNeverStarted)

        TaskStore.delete(task, in: context)
        try context.save()

        #expect(task.liveTabs.isEmpty)
        #expect(task.orderedLiveTabs.isEmpty)
        #expect(task.hasNeverStarted)
        #expect(TaskRemoteControl.toggleableTab(in: task) == nil)
    }

    @Test func anUnsavedDeleteIsAlreadyNotLive() throws {
        let (task, _, _) = try makeStartedTask()

        TaskStore.delete(task, in: context)

        #expect(task.liveTabs.isEmpty)
        #expect(task.hasNeverStarted)
    }

    @Test func aClosedTabLeavesTheOthersLive() throws {
        let (task, agent, terminal) = try makeStartedTask()

        TaskStore.closeTab(terminal, in: context)
        try context.save()

        #expect(task.liveTabs.map(\.id) == [agent.id])
        #expect(task.orderedLiveTabs.map(\.id) == [agent.id])
        #expect(!task.hasNeverStarted)
        #expect(TaskRemoteControl.toggleableTab(in: task)?.id == agent.id)
    }

    @Test func closingTheOnlyStartedAgentTabMakesTheTaskNeverStarted() throws {
        let (task, agent, terminal) = try makeStartedTask()

        TaskStore.closeTab(agent, in: context)
        try context.save()

        #expect(task.liveTabs.map(\.id) == [terminal.id])
        #expect(task.hasNeverStarted)
    }
}
