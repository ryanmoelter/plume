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
        #expect(task.workspaceKind == .unset)
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
        source.workingDirectoryPath = "/tmp/repo"
        source.repoPath = "/tmp/repo"
        source.branchName = "main"
        source.workspaceKind = .directory

        let task = TaskStore.createTask(in: context, siblings: [source], inheritingFrom: source)

        #expect(task.workingDirectoryPath == "/tmp/repo")
        #expect(task.repoPath == "/tmp/repo")
        #expect(task.branchName == "main")
        #expect(task.workspaceKind == .directory)
    }

    /// A worktree task is inherited as a plain directory, not a new worktree
    /// of its own — the new task just points at the same folder.
    @Test func inheritingFromAWorktreeTaskYieldsAPlainDirectory() throws {
        let context = try makeContext()
        let source = TaskStore.createTask(in: context, siblings: [])
        source.workingDirectoryPath = "/tmp/repo/.worktrees/feature"
        source.repoPath = "/tmp/repo"
        source.branchName = "plume/feature"
        source.workspaceKind = .worktree

        let task = TaskStore.createTask(in: context, siblings: [source], inheritingFrom: source)

        #expect(task.workingDirectoryPath == "/tmp/repo/.worktrees/feature")
        #expect(task.workspaceKind == .directory)
    }

    @Test func inheritingFromATaskWithNoWorkspaceLeavesItUnset() throws {
        let context = try makeContext()
        let source = TaskStore.createTask(in: context, siblings: [])

        let task = TaskStore.createTask(in: context, siblings: [source], inheritingFrom: source)

        #expect(task.workingDirectoryPath == nil)
        #expect(task.workspaceKind == .unset)
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
    @Test func aQuestionTheUserNeverAnsweredReadsAsInterrupted() {
        for status in [TaskStatus.planApproval, .questionAsked, .permissionNeeded, .needsTerminalInput] {
            #expect(status.afterRelaunch == .interrupted, "\(status)")
        }
    }

    /// These describe an outcome rather than a process, so they stay true.
    @Test func anOutcomeSurvivesAQuit() {
        for status in [TaskStatus.interrupted, .error, .done] {
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

        #expect(engine.status(forTab: tab) == .working)
    }
}
