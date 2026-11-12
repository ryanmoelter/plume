import Testing
import Foundation
import SwiftData
@testable import Plume

/// The decision of whether delete or archive needs to ask about worktrees
/// first, which worktrees it removes, and what the resulting dialog says —
/// kept separate from the SwiftUI dialog itself so it's testable without
/// presenting one.
@MainActor
struct WorktreeRemovalPromptTests {
    private func makeTask(_ workspaces: TabWorkspace...) -> WorkTask {
        let task = WorkTask(title: "Some Task", orderIndex: 0)
        task.tabs = workspaces.enumerated().map { index, workspace in
            let tab = TaskTab(kind: .agent, orderIndex: index, task: task)
            tab.workspace = workspace
            return tab
        }
        return task
    }

    private func worktree(_ path: String, branch: String?) -> TabWorkspace {
        TabWorkspace(kind: .worktree, directory: path, repoPath: "/repo", branchName: branch)
    }

    private let feature = WorktreeRemovalTarget(repository: "/repo", path: "/repo/.worktrees/feature", branch: "feature")
    private let other = WorktreeRemovalTarget(repository: "/repo", path: "/repo/.worktrees/other", branch: "other")

    private let listing = [
        GitWorktree(path: "/repo", branch: "main", isMain: true),
        GitWorktree(path: "/repo/.worktrees/feature", branch: "feature", isMain: false),
        GitWorktree(path: "/repo/.worktrees/other", branch: "other", isMain: false),
        GitWorktree(path: "/repo/.worktrees/detached", branch: nil, isMain: false),
    ]

    private func targets(for task: WorkTask) -> [WorktreeRemovalTarget] {
        WorktreeRemovalPrompt.targets(for: WorktreeRemovalPrompt.claims(for: task)) { $0 == "/repo" ? listing : [] }
    }

    @Test func aPlainDirectoryTaskNeedsNoConfirmation() {
        let task = makeTask(.directory("/tmp/foo"))
        #expect(!WorktreeRemovalPrompt.needsConfirmation(for: task))
    }

    @Test func anUnsetWorkspaceNeedsNoConfirmation() {
        let task = makeTask(TabWorkspace())
        #expect(!WorktreeRemovalPrompt.needsConfirmation(for: task))
    }

    @Test func aWorktreeOnAnyTabNeedsConfirmation() {
        let task = makeTask(.directory("/repo"), worktree("/tmp/foo", branch: nil))
        #expect(WorktreeRemovalPrompt.needsConfirmation(for: task))
    }

    // MARK: - Which worktrees

    @Test func tabsSharingAWorktreeRemoveItOnce() {
        let task = makeTask(
            worktree("/repo/.worktrees/feature", branch: "feature"),
            worktree("/repo/.worktrees/feature/sub", branch: "feature"),
            worktree("/repo/.worktrees/other", branch: "other"),
            .directory("/repo")
        )
        #expect(targets(for: task) == [feature, other])
    }

    /// A tab's folder follows it, so a terminal that `cd`s into another
    /// worktree must not take that worktree with it.
    @Test func aTabThatMovedStillRemovesTheWorktreeItsBranchNames() {
        let task = makeTask(worktree("/repo/.worktrees/other/src", branch: "feature"))
        #expect(targets(for: task) == [feature])
    }

    @Test func aBranchlessWorktreeIsFoundByTheFolderInIt() {
        let task = makeTask(worktree("/repo/.worktrees/detached/src", branch: nil))
        #expect(targets(for: task) == [
            WorktreeRemovalTarget(repository: "/repo", path: "/repo/.worktrees/detached", branch: nil),
        ])
    }

    @Test func theMainCheckoutIsNeverRemoved() {
        let task = makeTask(worktree("/repo", branch: "main"), worktree("/repo/src", branch: nil))
        #expect(targets(for: task).isEmpty)
    }

    @Test func aRenamedBranchIsFoundByTheFolderInItsWorktree() {
        let task = makeTask(worktree("/repo/.worktrees/feature/src", branch: "renamed-away"))
        #expect(targets(for: task) == [feature])
    }

    /// The listing failed or came back empty, so the saved folder is all there
    /// is to go on, and the dialog still offers it.
    @Test func aRepositoryWithNoListingFallsBackToTheSavedFolder() {
        let task = makeTask(TabWorkspace(kind: .worktree, directory: "/unlisted/.wt/x", repoPath: "/unlisted", branchName: "x"))
        #expect(targets(for: task) == [
            WorktreeRemovalTarget(repository: "/unlisted", path: "/unlisted/.wt/x", branch: "x"),
        ])
    }

    @Test func theFallbackNeverTargetsTheRepositoryItself() {
        let task = makeTask(TabWorkspace(kind: .worktree, directory: "/unlisted", repoPath: "/unlisted", branchName: "main"))
        #expect(targets(for: task).isEmpty)
    }

    /// Closing a task's last tab must not leak the worktree it was using.
    @Test func aTaskWithNoTabsOffersTheWorktreeItHolds() {
        let task = makeTask()
        task.heldWorkspace = worktree("/repo/.worktrees/feature", branch: "feature")
        #expect(WorktreeRemovalPrompt.needsConfirmation(for: task))
        #expect(targets(for: task) == [feature])
    }

    /// A tab moved into an empty task leaves the task's held worktree in place.
    @Test func aHeldWorktreeCountsAlongsideTabs() {
        let task = makeTask(.directory("/elsewhere"))
        task.heldWorkspace = worktree("/repo/.worktrees/feature", branch: "feature")
        #expect(WorktreeRemovalPrompt.needsConfirmation(for: task))
        #expect(targets(for: task) == [feature])
    }

    @Test func aWorktreeGitNoLongerListsIsSkipped() {
        let task = makeTask(worktree("/repo/.worktrees/gone", branch: "gone"))
        #expect(targets(for: task).isEmpty)
    }

    // MARK: - Dialog copy

    private func removal(
        _ worktrees: [WorktreeRemovalTarget],
        verb: WorktreeRemovalVerb = .delete,
        dirty: [String: String] = [:]
    ) -> WorktreeRemovalPrompt.PendingRemoval {
        .init(task: makeTask(), verb: verb, worktrees: worktrees, dirtySummaries: dirty)
    }

    @Test func deleteAndArchiveWordTheirButtonsDifferently() {
        let delete = removal([feature], verb: .delete)
        #expect(delete.dialogTitle == "Delete “Some Task”?")
        #expect(delete.primaryButtonTitle == "Delete and Remove Worktree")
        #expect(delete.withBranchButtonTitle == "Delete, Remove Worktree and Branch")
        #expect(delete.taskOnlyButtonTitle == "Delete Task Only")

        let archive = removal([feature], verb: .archive)
        #expect(archive.dialogTitle == "Archive “Some Task”?")
        #expect(archive.primaryButtonTitle == "Archive and Remove Worktree")
        #expect(archive.withBranchButtonTitle == "Archive, Remove Worktree and Branch")
        #expect(archive.taskOnlyButtonTitle == "Archive Task Only")
    }

    @Test func severalWorktreesArePluralInTheButtons() {
        let delete = removal([feature, other])
        #expect(delete.primaryButtonTitle == "Delete and Remove Worktrees")
        #expect(delete.withBranchButtonTitle == "Delete, Remove Worktrees and Branches")
    }

    @Test func theMessageNamesTheWorktreeAndBranch() {
        #expect(removal([feature]).message == "This task uses the worktree at /repo/.worktrees/feature on branch feature.")
    }

    /// Once the async uncommitted-changes check resolves, the warning is
    /// appended rather than replacing the base sentence.
    @Test func aDirtySummaryWarnsAboutLosingWork() {
        let message = removal([feature], dirty: [feature.path: "1 file has uncommitted changes:\n• a.txt"]).message
        #expect(message.hasPrefix("This task uses the worktree at /repo/.worktrees/feature on branch feature."))
        #expect(message.contains("uncommitted changes"))
        #expect(message.contains("cannot be recovered"))
    }

    @Test func severalWorktreesAreListedAndOnlyTheDirtyOnesWarn() {
        let message = removal([feature, other], dirty: [other.path: "1 file has uncommitted changes:\n• a.txt"]).message
        #expect(message.hasPrefix("""
            This task uses 2 worktrees:
            • /repo/.worktrees/feature on branch feature
            • /repo/.worktrees/other on branch other
            """))
        #expect(message.contains("In /repo/.worktrees/other, 1 file has uncommitted changes"))
        #expect(!message.contains("In /repo/.worktrees/feature,"))
        #expect(message.contains("cannot be recovered"))
    }

    @Test func cleanWorktreesCarryNoWarning() {
        #expect(!removal([feature, other]).message.contains("cannot be recovered"))
    }

    @Test func describeSummarizesPorcelainStatusAsPaths() {
        let summary = WorktreeRemovalPrompt.describe([" M a.txt", "?? b.txt"])
        #expect(summary.contains("2 files have uncommitted changes"))
        #expect(summary.contains("a.txt"))
        #expect(summary.contains("b.txt"))
    }

    @Test func describeCapsTheListAndCountsTheRest() {
        let changes = (1...7).map { " M file\($0).txt" }
        let summary = WorktreeRemovalPrompt.describe(changes)
        #expect(summary.contains("7 files have uncommitted changes"))
        #expect(summary.contains("and 2 more"))
    }
}
