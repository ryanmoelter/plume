import Testing
import Foundation
import SwiftData
@testable import Plume

@MainActor
struct TaskStoreTests {
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Schema([TaskGroup.self, WorkTask.self, TaskTab.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        return ModelContext(container)
    }

    @Test func newTaskStartsWithOneSelectedAgentTab() throws {
        let context = try makeContext()
        let task = TaskStore.createTask(in: context, siblings: [])

        #expect(task.tabs.count == 1)
        #expect(task.tabs.first?.kind == .agent)
        #expect(task.selectedTabID == task.tabs.first?.id)
        #expect(task.tabs[0].workspaceKind == .unset)
    }

    @Test func createdTasksGetIncreasingOrderIndexes() throws {
        let context = try makeContext()
        var tasks: [WorkTask] = []
        for _ in 0..<3 {
            tasks.append(TaskStore.createTask(in: context, siblings: tasks))
        }
        #expect(tasks.map(\.orderIndex) == [0, 1, 2])
    }

    @Test func movingTaskRewritesDenseOrder() throws {
        let context = try makeContext()
        var tasks: [WorkTask] = []
        for index in 0..<3 {
            tasks.append(TaskStore.createTask(in: context, title: "T\(index)", siblings: tasks))
        }

        TaskStore.move(tasks, from: IndexSet(integer: 2), to: 0)

        let ordered = tasks.sorted { $0.orderIndex < $1.orderIndex }
        #expect(ordered.map(\.title) == ["T2", "T0", "T1"])
        #expect(ordered.map(\.orderIndex) == [0, 1, 2])
    }

    @Test func deletingGroupKeepsTasksAsUngrouped() throws {
        let context = try makeContext()
        let group = TaskStore.createGroup(in: context, existing: [])
        let task = TaskStore.createTask(in: context, group: group, siblings: [])

        TaskStore.deleteGroup(group, in: context)

        #expect(task.group == nil)
        #expect(!task.isDeleted)
    }

    @Test func closingSelectedTabSelectsAnother() throws {
        let context = try makeContext()
        let task = TaskStore.createTask(in: context, siblings: [])
        let first = try #require(task.tabs.first)
        let second = TaskStore.addTab(to: task, kind: .terminal, in: context)
        #expect(task.selectedTabID == second.id)

        TaskStore.closeTab(second, in: context)

        #expect(task.selectedTabID == first.id)
    }

    /// Closing one tab used to forget less than deleting its whole task did,
    /// so a reused id could come back holding another tab's draft.
    @Test func closingATabAndDeletingATaskBothClearThePerTabStores() throws {
        let context = try makeContext()
        let closed = TaskStore.createTask(in: context, siblings: [])
        let deleted = TaskStore.createTask(in: context, siblings: [closed])
        let closedTab = try #require(closed.tabs.first)
        let deletedTab = try #require(deleted.tabs.first)

        for tab in [closedTab, deletedTab] {
            DraftStore.shared.setDraft("half a message", forTab: tab.id)
            BellStore.shared.recordBell(tabID: tab.id, isOnScreen: false)
        }

        TaskStore.closeTab(closedTab, in: context)
        TaskStore.delete(deleted, in: context)

        for id in [closedTab.id, deletedTab.id] {
            #expect(DraftStore.shared.draft(forTab: id).isEmpty)
            #expect(!BellStore.shared.hasUnseenBell(tabID: id))
        }
    }

    @Test func newTaskInheritsTheSourceTasksWorkspace() throws {
        let context = try makeContext()
        let source = TaskStore.createTask(in: context, siblings: [])
        source.tabs[0].workingDirectoryPath = "/tmp/repo"
        source.tabs[0].repoPath = "/tmp/repo"
        source.tabs[0].branchName = "main"
        source.tabs[0].workspaceKind = .directory

        let task = TaskStore.createTask(in: context, siblings: [source], inheritingFrom: source)

        #expect(task.tabs[0].workingDirectoryPath == "/tmp/repo")
        #expect(task.tabs[0].repoPath == "/tmp/repo")
        #expect(task.tabs[0].branchName == "main")
        #expect(task.tabs[0].workspaceKind == .directory)
    }

    /// A worktree task is inherited as a plain directory, not a new worktree
    /// of its own — the new task just points at the same folder.
    @Test func inheritingFromAWorktreeTaskYieldsAPlainDirectory() throws {
        let context = try makeContext()
        let source = TaskStore.createTask(in: context, siblings: [])
        source.tabs[0].workingDirectoryPath = "/tmp/repo/.worktrees/feature"
        source.tabs[0].repoPath = "/tmp/repo"
        source.tabs[0].branchName = "plume/feature"
        source.tabs[0].workspaceKind = .worktree

        let task = TaskStore.createTask(in: context, siblings: [source], inheritingFrom: source)

        #expect(task.tabs[0].workingDirectoryPath == "/tmp/repo/.worktrees/feature")
        #expect(task.tabs[0].workspaceKind == .directory)
    }

    @Test func inheritingFromATaskWithNoWorkspaceLeavesItUnset() throws {
        let context = try makeContext()
        let source = TaskStore.createTask(in: context, siblings: [])

        let task = TaskStore.createTask(in: context, siblings: [source], inheritingFrom: source)

        #expect(task.tabs[0].workingDirectoryPath == nil)
        #expect(task.tabs[0].workspaceKind == .unset)
    }

    @Test func inheritingTakesTheSelectedTabsWorkspace() throws {
        let context = try makeContext()
        let source = TaskStore.createTask(in: context, siblings: [])
        source.tabs[0].workspace = .directory("/tmp/repo", repoPath: "/tmp/repo")
        let selected = TaskStore.addTab(to: source, kind: .terminal, in: context)
        selected.workspace = .directory("/tmp/other", repoPath: "/tmp/other", branchName: "feature")

        let task = TaskStore.createTask(in: context, siblings: [source], inheritingFrom: source)

        #expect(task.tabs[0].workspace == .directory("/tmp/other", repoPath: "/tmp/other", branchName: "feature"))
    }
}

/// A new tab opens in the workspace of the tab the user is on: the selected
/// tab, else the last focused agent tab, else the first tab with a folder.
/// A worktree stays with its task when a tab leaves, even its last tab.
@MainActor
struct AddTabWorkspaceTests {
    private func makeContext() throws -> ModelContext {
        ModelContext(try ModelContainer(
            for: Schema([TaskGroup.self, WorkTask.self, TaskTab.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        ))
    }

    private let worktree = TabWorkspace(
        kind: .worktree, directory: "/repo/.worktrees/feature", repoPath: "/repo", branchName: "feature"
    )

    @Test func aNewTabTakesTheSelectedTabsWholeWorkspace() throws {
        let context = try makeContext()
        let task = TaskStore.createTask(in: context, siblings: [])
        task.tabs[0].workspace = worktree

        let tab = TaskStore.addTab(to: task, kind: .terminal, in: context)

        #expect(tab.workspace == worktree)
    }

    @Test func aNewTabTakesTheSelectedTabsLiveDirectory() throws {
        let context = try makeContext()
        let task = TaskStore.createTask(in: context, siblings: [])
        let source = task.tabs[0]
        source.workspace = worktree
        TabDirectoryStore.shared.setDirectory("/repo/.worktrees/feature/sub", forTab: source)
        defer { TabDirectoryStore.shared.forget(tabID: source.id) }

        let tab = TaskStore.addTab(to: task, kind: .agent, in: context)

        #expect(tab.workingDirectoryPath == "/repo/.worktrees/feature/sub")
        #expect(tab.branchName == "feature")
        #expect(tab.workspaceKind == .worktree)
    }

    @Test func aSelectedTabWithNoFolderFallsBackToTheLastFocusedAgentTab() throws {
        let context = try makeContext()
        let task = TaskStore.createTask(in: context, siblings: [])
        let first = TaskStore.addTab(to: task, kind: .terminal, in: context)
        first.workspace = .directory("/first")
        let agent = TaskStore.addTab(to: task, kind: .agent, in: context)
        agent.workspace = worktree
        let device = TaskStore.addTab(to: task, kind: .device, in: context)
        device.workspace = TabWorkspace()
        #expect(task.selectedTabID == device.id)
        #expect(task.lastFocusedAgentTabID == agent.id)

        let tab = TaskStore.addTab(to: task, kind: .terminal, in: context)

        #expect(tab.workspace == worktree)
    }

    @Test func aTaskWithNoFolderLeavesTheNewTabUnset() throws {
        let context = try makeContext()
        let task = TaskStore.createTask(in: context, siblings: [])

        let tab = TaskStore.addTab(to: task, kind: .terminal, in: context)

        #expect(tab.workspace == TabWorkspace())
    }

    // MARK: - Leaving the task

    @Test func aTabMovedToAnotherTaskLeavesTheWorktreeBehind() throws {
        let context = try makeContext()
        let source = TaskStore.createTask(in: context, siblings: [])
        source.tabs[0].workspace = worktree
        let tab = TaskStore.addTab(to: source, kind: .terminal, in: context)
        let destination = TaskStore.createTask(in: context, siblings: [source])

        TaskStore.moveTab(tab, to: destination)

        #expect(tab.workspace == .directory("/repo/.worktrees/feature", repoPath: "/repo", branchName: "feature"))
        #expect(!WorktreeRemovalPrompt.needsConfirmation(for: destination))
        #expect(WorktreeRemovalPrompt.needsConfirmation(for: source))
    }

    @Test func aTabSplitIntoANewTaskLeavesTheWorktreeBehind() throws {
        let context = try makeContext()
        let source = TaskStore.createTask(in: context, siblings: [])
        source.tabs[0].workspace = worktree
        let tab = TaskStore.addTab(to: source, kind: .terminal, in: context)

        let split = TaskStore.splitTabIntoNewTask(tab, in: context, siblings: [source])

        #expect(tab.workspaceKind == .directory)
        #expect(!WorktreeRemovalPrompt.needsConfirmation(for: split))
    }

    @Test func closingTheLastTabKeepsItsWorkspaceForTheNextOne() throws {
        let context = try makeContext()
        let task = TaskStore.createTask(in: context, siblings: [])
        task.tabs[0].workspace = worktree

        TaskStore.closeTab(task.tabs[0], in: context)

        #expect(task.tabs.isEmpty)
        #expect(WorktreeRemovalPrompt.needsConfirmation(for: task))
        let tab = TaskStore.addTab(to: task, kind: .terminal, in: context)
        #expect(tab.workspace == worktree)
        #expect(task.heldWorkspace == TabWorkspace())
    }

    @Test func movingTheLastTabAwayKeepsTheWorktreeClaim() throws {
        let context = try makeContext()
        let source = TaskStore.createTask(in: context, siblings: [])
        source.tabs[0].workspace = worktree
        let destination = TaskStore.createTask(in: context, siblings: [source])

        TaskStore.moveTab(source.tabs[0], to: destination)

        #expect(source.heldWorkspace == worktree)
        #expect(WorktreeRemovalPrompt.needsConfirmation(for: source))
    }

    @Test func aTabMovedInAndClosedLeavesTheHeldWorktree() throws {
        let context = try makeContext()
        let empty = TaskStore.createTask(in: context, siblings: [])
        empty.tabs[0].workspace = worktree
        TaskStore.closeTab(empty.tabs[0], in: context)
        let other = TaskStore.createTask(in: context, siblings: [empty])
        other.tabs[0].workspace = .directory("/elsewhere")
        let visitor = TaskStore.addTab(to: other, kind: .terminal, in: context)

        TaskStore.moveTab(visitor, to: empty)
        TaskStore.closeTab(visitor, in: context)

        #expect(empty.heldWorkspace == worktree)
        #expect(WorktreeRemovalPrompt.needsConfirmation(for: empty))
    }

    /// A task holds one worktree, so the one it already held wins.
    @Test func aSecondWorktreeLeavingDoesNotReplaceTheHeldOne() throws {
        let context = try makeContext()
        let task = TaskStore.createTask(in: context, siblings: [])
        task.tabs[0].workspace = worktree
        TaskStore.closeTab(task.tabs[0], in: context)
        let source = TaskStore.createTask(in: context, siblings: [task])
        source.tabs[0].workspace = .directory("/elsewhere")
        let visitor = TaskStore.addTab(to: source, kind: .terminal, in: context)
        TaskStore.moveTab(visitor, to: task)
        visitor.workspace = TabWorkspace(kind: .worktree, directory: "/repo/.worktrees/other", repoPath: "/repo", branchName: "other")

        TaskStore.closeTab(visitor, in: context)

        #expect(task.heldWorkspace == worktree)
    }

    @Test func closingATabThatIsNotTheLastHoldsNothing() throws {
        let context = try makeContext()
        let task = TaskStore.createTask(in: context, siblings: [])
        task.tabs[0].workspace = worktree
        let other = TaskStore.addTab(to: task, kind: .terminal, in: context)

        TaskStore.closeTab(other, in: context)

        #expect(task.heldWorkspace == TabWorkspace())
    }
}

/// Deleting a task drops the git and pull request watches on its folders, but
/// not on a folder another live task's tab still uses.
@MainActor
struct DeletedTaskFolderTests {
    @Test func aFolderAnotherTaskUsesIsKept() throws {
        let context = ModelContext(try ModelContainer(
            for: Schema([TaskGroup.self, WorkTask.self, TaskTab.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        ))
        let deleted = TaskStore.createTask(in: context, siblings: [])
        deleted.tabs[0].workspace = .directory("/shared")
        TaskStore.addTab(to: deleted, kind: .terminal, in: context).workspace = .directory("/own")
        let other = TaskStore.createTask(in: context, siblings: [deleted])
        other.tabs[0].workspace = .directory("/shared")
        let archived = TaskStore.createTask(in: context, siblings: [deleted, other])
        archived.tabs[0].workspace = .directory("/own")
        archived.isArchived = true

        let folders = TaskStore.foldersOnlyUsed(
            by: deleted, among: [deleted, other, archived], directories: TabDirectoryStore()
        )

        #expect(folders == ["/own"])
    }
}

@MainActor
struct SavedWorkspaceReaderTests {
    private func makeContext() throws -> ModelContext {
        ModelContext(try ModelContainer(
            for: Schema([TaskGroup.self, WorkTask.self, TaskTab.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        ))
    }

    /// Home builds its inputs in a view body, so a terminal's `cd` must not
    /// reach them.
    @Test func homeReadsTheSavedFolderNotTheLiveOne() throws {
        let context = try makeContext()
        let task = TaskStore.createTask(in: context, siblings: [])
        let tab = task.tabs[0]
        tab.workspace = .directory("/saved", repoPath: "/repo")
        TabDirectoryStore.shared.setDirectory("/live", forTab: tab.id)
        defer { TabDirectoryStore.shared.forget(tabID: tab.id) }

        let input = try #require(HomeComposerInputs(tasks: [task], groups: []).tasks.first)

        #expect(input.path == "/repo")
        #expect(input.workspaceKindRaw == WorkspaceKind.directory.rawValue)
    }

    @Test func theStoredBranchSkipsATabWithNone() throws {
        let context = try makeContext()
        let task = TaskStore.createTask(in: context, siblings: [])
        task.tabs[0].workspace = .directory("/repo")
        TaskStore.addTab(to: task, kind: .terminal, in: context).workspace = .directory("/repo", branchName: "feature")

        #expect(task.storedBranchName(in: "/repo") == "feature")
    }
}

struct TaskStatusTests {
    @Test func wantingAttentionOutranksWorking() {
        #expect(TaskStatus.aggregate([.awaitingReply, .working, .questionAsked]) == .questionAsked)
    }

    /// Among tabs that all want the user, the one whose answer decides the
    /// most is the one worth surfacing.
    @Test func namedReasonsRankByConsequence() {
        #expect(TaskStatus.aggregate([.permissionNeeded, .planApproval]) == .planApproval)
        #expect(TaskStatus.aggregate([.permissionNeeded, .questionAsked]) == .questionAsked)
        #expect(TaskStatus.aggregate([.needsTerminalInput, .permissionNeeded]) == .permissionNeeded)
    }

    @Test func workingOutranksErrorAndRest() {
        #expect(TaskStatus.aggregate([.awaitingReply, .error, .working]) == .working)
    }

    /// An interruption is a settled state, so it loses to anything still
    /// running — but it outranks a finished turn on a sibling tab, since a
    /// tab the user stopped is the one worth going back to.
    @Test func interruptedSitsBetweenAwaitingReplyAndError() {
        #expect(TaskStatus.aggregate([.awaitingReply, .interrupted]) == .interrupted)
        #expect(TaskStatus.aggregate([.interrupted, .error]) == .error)
        #expect(TaskStatus.aggregate([.interrupted, .working]) == .working)
    }

    @Test func aRestartInterruptionSitsBetweenInterruptedAndError() {
        #expect(TaskStatus.aggregate([.interrupted, .interruptedByRestart]) == .interruptedByRestart)
        #expect(TaskStatus.aggregate([.interruptedByRestart, .error]) == .error)
    }

    @Test func emptyAggregatesToNotStarted() {
        #expect(TaskStatus.aggregate([]) == .notStarted)
    }

    @Test func onlyTheStatusesWaitingOnSomeoneWantAttention() {
        let wanting: Set<TaskStatus> = [.planApproval, .questionAsked, .permissionNeeded, .needsTerminalInput]
        for status in TaskStatus.allCases {
            #expect(status.wantsAttention == wanting.contains(status), "\(status)")
        }
    }

    @Test(arguments: [
        ("unset", TaskStatus.notStarted),
        ("idle", .awaitingReply),
        ("needsInput", .needsTerminalInput),
        ("working", .working),
        ("interrupted", .interrupted),
        ("interruptedByRestart", .interruptedByRestart),
        ("error", .error),
    ])
    func aSnapshotFromTheOldVocabularyStillReads(raw: String, expected: TaskStatus) {
        #expect(TaskStatus(migratingRawValue: raw) == expected)
    }

    /// A finished subagent is over; a tab handing its turn back is not. The
    /// two must not aggregate to the same thing, or a task holding a done
    /// subagent would read as finished itself.
    @Test func aFinishedSubagentDoesNotOutrankATabWaitingOnTheUser() {
        #expect(TaskStatus.aggregate([.done, .awaitingReply]) == .awaitingReply)
        #expect(TaskStatus.aggregate([.done, .questionAsked]) == .questionAsked)
        #expect(TaskStatus.aggregate([.done, .working]) == .working)
    }

    @Test func anUnreadableSnapshotClaimsNothing() {
        #expect(TaskStatus(migratingRawValue: "banana") == .notStarted)
    }

    @Test func everyCurrentRawValueSurvivesMigration() {
        for status in TaskStatus.allCases {
            #expect(TaskStatus(migratingRawValue: status.rawValue) == status)
        }
    }
}

/// Quitting kills every agent, so a snapshot that claimed activity is stale by
/// the time it is read back.
@MainActor
struct RelaunchStatusTests {
    @Test func aStatusClaimingActivityDoesNotSurviveAQuit() {
        for status in [TaskStatus.working, .awaitingReply] {
            #expect(status.afterRelaunch == .notStarted, "\(status)")
        }
    }

    /// Quitting is what stopped a tab that was waiting on an answer, and the
    /// unanswered question is still sitting in the transcript.
    @Test func aQuestionTheUserNeverAnsweredReadsAsInterruptedByRestart() {
        for status in [TaskStatus.planApproval, .questionAsked, .permissionNeeded, .needsTerminalInput] {
            #expect(status.afterRelaunch == .interruptedByRestart, "\(status)")
        }
    }

    /// These describe an outcome rather than a process, so they stay true.
    @Test func anOutcomeSurvivesAQuit() {
        for status in [TaskStatus.interrupted, .interruptedByRestart, .error, .done] {
            #expect(status.afterRelaunch == status, "\(status)")
        }
    }

    /// A restored tab's old transcript still lists whatever was in flight when
    /// the app quit. Nothing read from it may raise the tab to working.
    @Test func aRestoredTabIgnoresItsOldTranscriptsSubagents() {
        let engine = StatusEngine()
        let (task, tab) = (UUID(), UUID())
        engine.restore(tabID: tab, taskID: task)

        engine.setSubagentActivity(tabID: tab, working: true)

        #expect(engine.status(forTab: tab) == .notStarted)
        #expect(engine.status(forTask: task) == .notStarted)
    }

    /// Once a real session reports, the tab is live and behaves normally.
    @Test func aLiveReportWakesARestoredTab() {
        let engine = StatusEngine()
        let (task, tab) = (UUID(), UUID())
        engine.restore(tabID: tab, taskID: task)

        engine.setStatus(.awaitingReply, taskID: task, tabID: tab)
        engine.setSubagentActivity(tabID: tab, working: true)

        #expect(engine.status(forTab: tab) == .waitingOnSubagents)
    }
}
