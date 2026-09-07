import Testing
import Foundation
import SwiftData
@testable import Plume

/// The fallback chain a tab's directory resolves through: what the tab last
/// reported, else the task's own folder.
@MainActor
struct TabDirectoryStoreTests {
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Schema([TaskGroup.self, WorkTask.self, TaskTab.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        return ModelContext(container)
    }

    @Test func aTabWithNothingReportedFallsBackToTheTaskFolder() throws {
        let context = try makeContext()
        let task = TaskStore.createTask(in: context, siblings: [])
        task.workingDirectoryPath = "/repo"

        #expect(TabDirectoryStore().directory(for: task.tabs[0]) == "/repo")
    }

    @Test func aReportedDirectoryWinsOverTheTaskFolder() throws {
        let context = try makeContext()
        let task = TaskStore.createTask(in: context, siblings: [])
        task.workingDirectoryPath = "/repo"
        let store = TabDirectoryStore()
        store.setDirectory("/repo/../worktrees/feature", forTab: task.tabs[0].id)

        #expect(store.directory(for: task.tabs[0]) == "/repo/../worktrees/feature")
    }

    @Test func aTaskWithNoFolderAnywhereResolvesToNothing() throws {
        let context = try makeContext()
        let task = TaskStore.createTask(in: context, siblings: [])

        #expect(TabDirectoryStore().directory(for: task.tabs[0]) == nil)
    }

    @Test func anEmptyReportIsIgnored() {
        let store = TabDirectoryStore()
        let id = UUID()
        store.setDirectory("/repo", forTab: id)
        store.setDirectory("   ", forTab: id)
        store.setDirectory(nil, forTab: id)

        #expect(store.directory(forTab: id) == "/repo")
    }

    @Test func forgettingATabDropsItsDirectory() {
        let store = TabDirectoryStore()
        let id = UUID()
        store.setDirectory("/repo", forTab: id)
        store.forget(tabID: id)

        #expect(store.directory(forTab: id) == nil)
    }

    /// A new terminal tab opens where the agent went, not where the task began.
    @Test func aNewTabStartsInTheAgentsWorktree() throws {
        let context = try makeContext()
        let task = TaskStore.createTask(in: context, siblings: [])
        task.workingDirectoryPath = "/repo"
        let agentTab = task.tabs[0]
        task.lastFocusedAgentTabID = agentTab.id
        let store = TabDirectoryStore()
        store.setDirectory("/worktrees/feature", forTab: agentTab.id)

        _ = TaskStore.addTab(to: task, kind: .terminal, in: context)

        #expect(store.startingDirectory(for: task) == "/worktrees/feature")
    }

    @Test func aTaskWhoseTabsReportedNothingStartsInItsOwnFolder() throws {
        let context = try makeContext()
        let task = TaskStore.createTask(in: context, siblings: [])
        task.workingDirectoryPath = "/repo"

        #expect(TabDirectoryStore().startingDirectory(for: task) == "/repo")
    }

    /// Sitting in a terminal tab must not make a new tab forget the worktree.
    @Test func theLastFocusedAgentTabWinsOverASelectedTerminal() throws {
        let context = try makeContext()
        let task = TaskStore.createTask(in: context, siblings: [])
        task.workingDirectoryPath = "/repo"
        let agentTab = task.tabs[0]
        let terminalTab = TaskStore.addTab(to: task, kind: .terminal, in: context)
        task.lastFocusedAgentTabID = agentTab.id
        task.selectedTabID = terminalTab.id

        let store = TabDirectoryStore()
        store.setDirectory("/worktrees/feature", forTab: agentTab.id)
        store.setDirectory("/somewhere/else", forTab: terminalTab.id)

        #expect(store.startingDirectory(for: task) == "/worktrees/feature")
    }

    /// With no agent tab to speak for the task, the selected tab does.
    @Test func theSelectedTabAnswersWhenNoAgentTabHasReported() throws {
        let context = try makeContext()
        let task = TaskStore.createTask(in: context, siblings: [])
        task.workingDirectoryPath = "/repo"
        let terminalTab = TaskStore.addTab(to: task, kind: .terminal, in: context)
        task.selectedTabID = terminalTab.id

        let store = TabDirectoryStore()
        store.setDirectory("/somewhere/else", forTab: terminalTab.id)

        #expect(store.startingDirectory(for: task) == "/somewhere/else")
    }
}
