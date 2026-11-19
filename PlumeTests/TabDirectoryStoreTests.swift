import Testing
import Foundation
import SwiftData
@testable import Plume

/// The fallback chain a tab's directory resolves through: what the tab last
/// reported, else the folder it saved. A task's own folder is never one.
@MainActor
struct TabDirectoryStoreTests {
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Schema([TaskGroup.self, WorkTask.self, TaskTab.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        return ModelContext(container)
    }

    @Test func aTabWithNothingReportedUsesItsSavedFolder() throws {
        let context = try makeContext()
        let task = TaskStore.createTask(in: context, siblings: [])
        task.tabs[0].workingDirectoryPath = "/repo"

        #expect(TabDirectoryStore().directory(for: task.tabs[0]) == "/repo")
    }

    /// Only `TabWorkspaceMigration` reads the task's folder.
    @Test func theTasksOwnFolderIsNeverAFallback() throws {
        let context = try makeContext()
        let task = TaskStore.createTask(in: context, siblings: [])
        task.workingDirectoryPath = "/legacy"

        #expect(TabDirectoryStore().directory(for: task.tabs[0]) == nil)
        #expect(TabDirectoryStore().startingDirectory(for: task) == nil)
    }

    @Test func aReportedDirectoryWinsOverTheSavedFolder() throws {
        let context = try makeContext()
        let task = TaskStore.createTask(in: context, siblings: [])
        task.tabs[0].workingDirectoryPath = "/repo"
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
        task.tabs[0].workingDirectoryPath = "/repo"
        let agentTab = task.tabs[0]
        task.lastFocusedAgentTabID = agentTab.id
        let store = TabDirectoryStore()
        store.setDirectory("/worktrees/feature", forTab: agentTab.id)

        #expect(store.startingDirectory(for: task) == "/worktrees/feature")
    }

    @Test func aTaskWhoseTabsReportedNothingStartsInASavedFolder() throws {
        let context = try makeContext()
        let task = TaskStore.createTask(in: context, siblings: [])
        task.tabs[0].workingDirectoryPath = "/repo"

        #expect(TabDirectoryStore().startingDirectory(for: task) == "/repo")
    }

    /// Sitting in a device tab, which has no folder, must not make a new tab
    /// forget the worktree.
    @Test func theLastFocusedAgentTabAnswersForASelectedTabWithNoFolder() throws {
        let context = try makeContext()
        let task = TaskStore.createTask(in: context, siblings: [])
        let agentTab = task.tabs[0]
        let terminalTab = TaskStore.addTab(to: task, kind: .terminal, in: context)
        let deviceTab = TaskStore.addTab(to: task, kind: .device, in: context)
        task.lastFocusedAgentTabID = agentTab.id
        task.selectedTabID = deviceTab.id

        let store = TabDirectoryStore()
        store.setDirectory("/somewhere/else", forTab: terminalTab.id)
        store.setDirectory("/worktrees/feature", forTab: agentTab.id)

        #expect(store.workspaceSource(in: task) === agentTab)
        #expect(store.startingDirectory(for: task) == "/worktrees/feature")
    }

    /// A new tab and a tab with no folder of its own pick the same source.
    @Test func theSelectedTabWinsOverTheLastFocusedAgent() throws {
        let context = try makeContext()
        let task = TaskStore.createTask(in: context, siblings: [])
        let agentTab = task.tabs[0]
        let terminalTab = TaskStore.addTab(to: task, kind: .terminal, in: context)
        task.lastFocusedAgentTabID = agentTab.id
        task.selectedTabID = terminalTab.id

        let store = TabDirectoryStore()
        store.setDirectory("/worktrees/feature", forTab: agentTab.id)
        store.setDirectory("/somewhere/else", forTab: terminalTab.id)

        #expect(store.workspaceSource(in: task) === terminalTab)
        #expect(store.startingDirectory(for: task) == "/somewhere/else")
    }

    // MARK: - Current workspace

    @Test func aTabStillInItsSavedFolderPassesOnItsWholeWorkspace() throws {
        let context = try makeContext()
        let tab = TaskStore.createTask(in: context, siblings: []).tabs[0]
        let saved = TabWorkspace(kind: .worktree, directory: "/repo/.wt/a", repoPath: "/repo", branchName: "a")
        tab.workspace = saved
        let store = TabDirectoryStore()

        #expect(store.currentWorkspace(of: tab) == saved)
        store.setDirectory("/repo/.wt/a", forTab: tab.id)
        #expect(store.currentWorkspace(of: tab) == saved)
    }

    /// The repository and branch describe the saved folder, not wherever the
    /// tab's process has gone since.
    @Test func aTabThatLeftItsSavedFolderPassesOnOnlyTheFolder() throws {
        let context = try makeContext()
        let tab = TaskStore.createTask(in: context, siblings: []).tabs[0]
        tab.workspace = TabWorkspace(kind: .worktree, directory: "/repo/.wt/a", repoPath: "/repo", branchName: "a")
        let store = TabDirectoryStore()
        store.setDirectory("/other-repo", forTab: tab.id)

        #expect(store.currentWorkspace(of: tab) == .directory("/other-repo"))
    }

    /// With no agent tab to speak for the task, the selected tab does.
    @Test func theSelectedTabAnswersWhenNoAgentTabHasReported() throws {
        let context = try makeContext()
        let task = TaskStore.createTask(in: context, siblings: [])
        let terminalTab = TaskStore.addTab(to: task, kind: .terminal, in: context)
        task.selectedTabID = terminalTab.id

        let store = TabDirectoryStore()
        store.setDirectory("/somewhere/else", forTab: terminalTab.id)

        #expect(store.startingDirectory(for: task) == "/somewhere/else")
    }

    // MARK: - Persistence

    @Test func reportingThroughTheTabPersistsTheDirectory() throws {
        let context = try makeContext()
        let task = TaskStore.createTask(in: context, siblings: [])
        let tab = task.tabs[0]

        TabDirectoryStore().setDirectory("/worktrees/feature", forTab: tab)

        #expect(tab.workingDirectoryPath == "/worktrees/feature")
    }

    /// What a relaunch sees: the store is empty, but the tab remembers.
    @Test func aPersistedDirectorySurvivesAnEmptyStore() throws {
        let context = try makeContext()
        let task = TaskStore.createTask(in: context, siblings: [])
        let tab = task.tabs[0]
        tab.workingDirectoryPath = "/worktrees/feature"

        #expect(TabDirectoryStore().directory(for: tab) == "/worktrees/feature")
    }

    @Test func aFreshReportWinsOverThePersistedOne() throws {
        let context = try makeContext()
        let task = TaskStore.createTask(in: context, siblings: [])
        let tab = task.tabs[0]
        tab.workingDirectoryPath = "/worktrees/stale"

        let store = TabDirectoryStore()
        store.setDirectory("/worktrees/current", forTab: tab)

        #expect(store.directory(for: tab) == "/worktrees/current")
    }

    /// The relaunch case for a new tab: nothing has reported yet this run, so
    /// the agent tab's persisted worktree is where a new terminal opens.
    @Test func aNewTabStartsInThePersistedWorktreeAfterARelaunch() throws {
        let context = try makeContext()
        let task = TaskStore.createTask(in: context, siblings: [])
        let agentTab = task.tabs[0]
        task.lastFocusedAgentTabID = agentTab.id
        agentTab.workingDirectoryPath = "/worktrees/feature"

        #expect(TabDirectoryStore().startingDirectory(for: task) == "/worktrees/feature")
    }

    @Test func anEmptyReportDoesNotClearThePersistedDirectory() throws {
        let context = try makeContext()
        let task = TaskStore.createTask(in: context, siblings: [])
        let tab = task.tabs[0]
        let store = TabDirectoryStore()

        store.setDirectory("/worktrees/feature", forTab: tab)
        store.setDirectory(nil, forTab: tab)
        store.setDirectory("   ", forTab: tab)

        #expect(tab.workingDirectoryPath == "/worktrees/feature")
    }

    /// A tab opened with a directory starts there, not beside the task's
    /// other work, and every reader agrees on it before its shell reports.
    @Test func aTabGivenADirectoryStartsThere() throws {
        let context = try makeContext()
        let task = TaskStore.createTask(in: context, siblings: [])
        let store = TabDirectoryStore()
        let tab = TaskStore.addTab(to: task, kind: .terminal, in: context)
        store.setDirectory("/elsewhere", forTab: tab)

        #expect(store.startingDirectory(for: tab, in: task) == "/elsewhere")
        #expect(store.directory(for: tab) == "/elsewhere")
        #expect(store.startingDirectory(for: task) == "/elsewhere")
    }

    @Test func aTabWithNoDirectoryStartsWhereANewTabWould() throws {
        let context = try makeContext()
        let task = TaskStore.createTask(in: context, siblings: [])
        TaskStore.addTab(to: task, kind: .terminal, in: context).workingDirectoryPath = "/repo"

        #expect(TabDirectoryStore().startingDirectory(for: task.tabs[0], in: task) == "/repo")
    }

    /// After a relaunch the store is empty, so only the tab's saved folder can
    /// keep it from following the task's selected tab.
    @Test func aSavedFolderWinsOverTheTaskAfterARelaunch() throws {
        let context = try makeContext()
        let task = TaskStore.createTask(in: context, siblings: [])
        let first = task.tabs[0]
        first.workingDirectoryPath = "/worktrees/feature"
        let tab = TaskStore.addTab(to: task, kind: .terminal, in: context)
        TaskStore.selectTab(first, in: task)
        let saved = FileManager.default.temporaryDirectory.path
        tab.workingDirectoryPath = saved

        #expect(TabDirectoryStore().startingDirectory(for: tab, in: task) == saved)
    }

    @Test func aDeletedSavedFolderFallsBackToWhereANewTabWouldStart() throws {
        let context = try makeContext()
        let task = TaskStore.createTask(in: context, siblings: [])
        task.tabs[0].workingDirectoryPath = "/repo"
        let tab = TaskStore.addTab(to: task, kind: .terminal, in: context)
        tab.workingDirectoryPath = "/nonexistent-\(UUID().uuidString)"

        #expect(TabDirectoryStore().startingDirectory(for: tab, in: task) == "/repo")
    }
}
