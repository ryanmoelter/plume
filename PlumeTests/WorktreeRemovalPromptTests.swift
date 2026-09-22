import Testing
import Foundation
import SwiftData
@testable import Plume

/// The decision of whether delete or archive needs to ask about a worktree
/// first, and what the resulting dialog says — kept separate from the SwiftUI
/// dialog itself so it's testable without presenting one.
@MainActor
struct WorktreeRemovalPromptTests {
    private func makeTask(workspaceKind: WorkspaceKind, path: String? = nil, branch: String? = nil) -> WorkTask {
        let task = WorkTask(title: "Some Task", orderIndex: 0)
        task.workspaceKind = workspaceKind
        task.workingDirectoryPath = path
        task.branchName = branch
        return task
    }

    @Test func aPlainDirectoryTaskNeedsNoConfirmation() {
        let task = makeTask(workspaceKind: .directory, path: "/tmp/foo")
        #expect(!WorktreeRemovalPrompt.needsConfirmation(for: task))
    }

    @Test func anUnsetWorkspaceNeedsNoConfirmation() {
        let task = makeTask(workspaceKind: .unset)
        #expect(!WorktreeRemovalPrompt.needsConfirmation(for: task))
    }

    @Test func aWorktreeTaskNeedsConfirmation() {
        let task = makeTask(workspaceKind: .worktree, path: "/tmp/foo")
        #expect(WorktreeRemovalPrompt.needsConfirmation(for: task))
    }

    @Test func deleteAndArchiveWordTheirButtonsDifferently() {
        let task = makeTask(workspaceKind: .worktree, path: "/tmp/foo", branch: "feature")

        let delete = WorktreeRemovalPrompt.PendingRemoval(task: task, verb: .delete, dirtySummary: nil)
        #expect(delete.dialogTitle == "Delete “Some Task”?")
        #expect(delete.primaryButtonTitle == "Delete and Remove Worktree")
        #expect(delete.withBranchButtonTitle == "Delete, Remove Worktree and Branch")
        #expect(delete.taskOnlyButtonTitle == "Delete Task Only")

        let archive = WorktreeRemovalPrompt.PendingRemoval(task: task, verb: .archive, dirtySummary: nil)
        #expect(archive.dialogTitle == "Archive “Some Task”?")
        #expect(archive.primaryButtonTitle == "Archive and Remove Worktree")
        #expect(archive.withBranchButtonTitle == "Archive, Remove Worktree and Branch")
        #expect(archive.taskOnlyButtonTitle == "Archive Task Only")
    }

    @Test func theMessageNamesTheWorktreeAndBranch() {
        let task = makeTask(workspaceKind: .worktree, path: "/tmp/foo", branch: "feature")
        let removal = WorktreeRemovalPrompt.PendingRemoval(task: task, verb: .delete, dirtySummary: nil)
        #expect(removal.message == "This task uses the worktree at /tmp/foo on branch feature.")
    }

    /// Once the async uncommitted-changes check resolves, the warning is
    /// appended rather than replacing the base sentence.
    @Test func aDirtySummaryWarnsAboutLosingWork() {
        let task = makeTask(workspaceKind: .worktree, path: "/tmp/foo", branch: "feature")
        let removal = WorktreeRemovalPrompt.PendingRemoval(
            task: task, verb: .delete, dirtySummary: "1 file has uncommitted changes:\n• a.txt"
        )
        #expect(removal.message.contains("uncommitted changes"))
        #expect(removal.message.contains("cannot be recovered"))
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
