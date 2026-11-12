import Testing
import Foundation
import SwiftData
@testable import Plume

/// Tabs saved before they owned a workspace take their task's at launch:
/// every field the tab lacks, none it already has, and only once. A task
/// whose workspace was a worktree owns it.
@MainActor
struct TabWorkspaceMigrationTests {
    private func makeContext() throws -> ModelContext {
        ModelContext(try ModelContainer(
            for: Schema([TaskGroup.self, WorkTask.self, TaskTab.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        ))
    }

    /// A task and tabs as an older build saved them.
    private func makeLegacyTask(in context: ModelContext, tabCount: Int = 1) -> WorkTask {
        let task = WorkTask(title: "Legacy", orderIndex: 0)
        task.workspaceKindRaw = WorkspaceKind.worktree.rawValue
        task.workingDirectoryPath = "/repo/.worktrees/feature"
        task.repoPath = "/repo"
        task.branchName = "feature"
        context.insert(task)
        for index in 0..<tabCount {
            let tab = TaskTab(kind: .agent, orderIndex: index, task: task)
            tab.isWorkspaceMigrated = false
            context.insert(tab)
            task.tabs.append(tab)
        }
        return task
    }

    private let taskWorkspace = TabWorkspace(
        kind: .worktree, directory: "/repo/.worktrees/feature", repoPath: "/repo", branchName: "feature"
    )

    @Test func everyTabTakesTheTasksWorkspace() throws {
        let context = try makeContext()
        let task = makeLegacyTask(in: context, tabCount: 2)

        try TabWorkspaceMigration.run(in: context)

        #expect(task.tabs.map(\.workspace) == [taskWorkspace, taskWorkspace])
        #expect(task.tabs.allSatisfy { $0.isWorkspaceMigrated })
    }

    private let ownedFeature = OwnedWorktree(path: "/repo/.worktrees/feature", repoPath: "/repo", branch: "feature")

    @Test func aWorktreeTaskOwnsItsWorktreeOnce() throws {
        let context = try makeContext()
        let task = makeLegacyTask(in: context, tabCount: 2)

        try TabWorkspaceMigration.run(in: context)
        try TabWorkspaceMigration.run(in: context)

        #expect(task.ownedWorktrees == [ownedFeature])
        #expect(task.tabs.map(\.workspace) == [taskWorkspace, taskWorkspace])
    }

    @Test func aTaskWithNoTabsStillOwnsItsWorktree() throws {
        let context = try makeContext()
        let empty = makeLegacyTask(in: context, tabCount: 0)

        try TabWorkspaceMigration.run(in: context)

        #expect(empty.ownedWorktrees == [ownedFeature])
    }

    @Test func aSavedSubfolderOwnsTheWorktreeRoot() throws {
        let scratch = FileManager.default.temporaryDirectory.appending(path: "plume-migration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let root = scratch.appending(path: "wt")
        let subfolder = root.appending(path: "app")
        try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)
        try "gitdir: /repo/.git/worktrees/wt".write(to: root.appending(path: ".git"), atomically: true, encoding: .utf8)
        let context = try makeContext()
        let task = makeLegacyTask(in: context)
        task.workingDirectoryPath = subfolder.path

        try TabWorkspaceMigration.run(in: context)

        #expect(task.ownedWorktrees.map(\.path) == [OwnedWorktree.standardized(root.path)])
    }

    @Test func aFolderThatNoLongerExistsIsKeptAsSaved() {
        #expect(TabWorkspaceMigration.checkoutRoot(containing: "/nonexistent/wt/app") == "/nonexistent/wt/app")
    }

    @Test func aDirectoryTaskOwnsNoWorktree() throws {
        let context = try makeContext()
        let task = makeLegacyTask(in: context)
        task.workspaceKindRaw = WorkspaceKind.directory.rawValue

        try TabWorkspaceMigration.run(in: context)

        #expect(task.ownedWorktrees.isEmpty)
    }

    /// Once read, the task's fields are cleared, so nothing reads them again.
    @Test func theTasksOwnFieldsAreCleared() throws {
        let context = try makeContext()
        let task = makeLegacyTask(in: context)

        try TabWorkspaceMigration.run(in: context)

        #expect(task.workspaceKindRaw == WorkspaceKind.unset.rawValue)
        #expect(task.workingDirectoryPath == nil)
        #expect(task.repoPath == nil)
        #expect(task.branchName == nil)
    }

    @Test func aFolderTheTabAlreadyReportedIsKept() throws {
        let context = try makeContext()
        let tab = makeLegacyTask(in: context).tabs[0]
        tab.workingDirectoryPath = "/repo/.worktrees/elsewhere"

        try TabWorkspaceMigration.run(in: context)

        #expect(tab.workspace == TabWorkspace(
            kind: .worktree, directory: "/repo/.worktrees/elsewhere", repoPath: "/repo", branchName: "feature"
        ))
    }

    @Test func runningAgainChangesNothing() throws {
        let context = try makeContext()
        let task = makeLegacyTask(in: context)
        try TabWorkspaceMigration.run(in: context)
        let tab = task.tabs[0]
        tab.workspace = .directory("/chosen/later")

        try TabWorkspaceMigration.run(in: context)

        #expect(tab.workspace == .directory("/chosen/later"))
    }

    /// A tab made after the migration owns its workspace from the start, so an
    /// empty one stays empty rather than picking up the task's stale folder.
    @Test func aNewTabIsNeverMigrated() throws {
        let context = try makeContext()
        let task = makeLegacyTask(in: context)
        let tab = TaskTab(kind: .terminal, orderIndex: 1, task: task)
        context.insert(tab)
        task.tabs.append(tab)

        try TabWorkspaceMigration.run(in: context)

        #expect(tab.workspace == TabWorkspace())
    }

    @Test func aTaskWithNoWorkspaceLeavesItsTabsUnset() throws {
        let context = try makeContext()
        let task = WorkTask(title: "Bare", orderIndex: 0)
        context.insert(task)
        let tab = TaskTab(kind: .agent, orderIndex: 0, task: task)
        tab.isWorkspaceMigrated = false
        context.insert(tab)
        task.tabs = [tab]

        try TabWorkspaceMigration.run(in: context)

        #expect(tab.workspace == TabWorkspace())
        #expect(tab.isWorkspaceMigrated)
    }

    /// What an upgrade sees: unmigrated rows read back from disk.
    @Test func reopenedRowsFromAnOlderBuildMigrate() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "plume-migration-\(UUID().uuidString).store")
        defer {
            for suffix in ["", "-shm", "-wal"] {
                try? FileManager.default.removeItem(atPath: url.path + suffix)
            }
        }
        let schema = Schema([TaskGroup.self, WorkTask.self, TaskTab.self])
        let tabID: UUID
        do {
            let context = ModelContext(try ModelContainer(for: schema, configurations: [ModelConfiguration(url: url)]))
            tabID = makeLegacyTask(in: context).tabs[0].id
            try context.save()
        }

        let context = ModelContext(try ModelContainer(for: schema, configurations: [ModelConfiguration(url: url)]))
        try TabWorkspaceMigration.run(in: context)

        let tab = try #require(try context.fetch(FetchDescriptor<TaskTab>()).first { $0.id == tabID })
        #expect(tab.workspace == taskWorkspace)
    }
}
