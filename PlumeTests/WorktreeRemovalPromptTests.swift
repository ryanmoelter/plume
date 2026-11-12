import Testing
import Foundation
import SwiftData
import Synchronization
@testable import Plume

/// Archive and delete offer to remove only the worktrees a task owns: one git
/// still lists as a linked worktree, that no other task's tab is in. The
/// dialog says what happens to each, kept separate from the SwiftUI dialog
/// itself so it's testable without presenting one.
@MainActor
struct WorktreeRemovalPromptTests {
    private func makeContext() throws -> ModelContext {
        ModelContext(try ModelContainer(
            for: Schema([TaskGroup.self, WorkTask.self, TaskTab.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        ))
    }

    private func owned(_ name: String, branch: String? = nil) -> OwnedWorktree {
        OwnedWorktree(path: "/repo/.worktrees/\(name)", repoPath: "/repo", branch: branch ?? name)
    }

    private let feature = WorktreeRemovalTarget(repository: "/repo", path: "/repo/.worktrees/feature", branch: "feature")
    private let other = WorktreeRemovalTarget(repository: "/repo", path: "/repo/.worktrees/other", branch: "other")

    private let listing = [
        GitWorktree(path: "/repo", branch: "main", isMain: true),
        GitWorktree(path: "/repo/.worktrees/feature", branch: "feature", isMain: false),
        GitWorktree(path: "/repo/.worktrees/other", branch: "renamed", isMain: false),
    ]

    private func plan(
        _ worktrees: [OwnedWorktree],
        users: [WorktreeRemovalPrompt.User] = [],
        branches: Set<String> = ["feature", "other"]
    ) -> WorktreeRemovalPrompt.Plan {
        WorktreeRemovalPrompt.plan(
            for: worktrees,
            users: users,
            listing: { $0 == "/repo" ? listing : [] },
            branchExists: { _, branch in branches.contains(branch) }
        )
    }

    // MARK: - Which tasks ask

    @Test func aTaskThatOwnsNoWorktreeNeedsNoConfirmation() throws {
        let context = try makeContext()
        let task = TaskStore.createTask(in: context, siblings: [])
        task.tabs[0].workspace = TabWorkspace(
            kind: .worktree, directory: "/repo/.worktrees/feature", repoPath: "/repo", branchName: "feature"
        )
        #expect(!WorktreeRemovalPrompt.needsConfirmation(for: task))
    }

    @Test func aTaskThatOwnsAWorktreeAlwaysAsks() throws {
        let context = try makeContext()
        let task = TaskStore.createTask(in: context, siblings: [])
        TaskStore.closeTab(task.tabs[0], in: context)
        task.recordOwnedWorktree(owned("feature"))
        #expect(WorktreeRemovalPrompt.needsConfirmation(for: task))
    }

    // MARK: - The plan

    @Test func aListedWorktreeIsRemovableWithItsRecordedBranch() {
        #expect(plan([owned("feature")]).removable == [feature])
    }

    /// The recorded branch is what Plume made, whatever is checked out now.
    @Test func theRecordedBranchIsRemovedNotTheCheckedOutOne() {
        #expect(plan([owned("other")]).removable == [other])
    }

    @Test func aBranchThatNoLongerExistsIsNotRemoved() {
        let removable = plan([owned("feature")], branches: []).removable
        #expect(removable == [WorktreeRemovalTarget(repository: "/repo", path: "/repo/.worktrees/feature", branch: nil)])
    }

    @Test func aWorktreeGitNoLongerListsIsGone() {
        let result = plan([owned("deleted")])
        #expect(result.removable.isEmpty)
        #expect(result.gone == ["/repo/.worktrees/deleted"])
    }

    @Test func theMainCheckoutIsNeverRemoved() {
        let result = plan([OwnedWorktree(path: "/repo", repoPath: "/repo", branch: "main")])
        #expect(result == WorktreeRemovalPrompt.Plan())
    }

    /// The listing failed, so the record is all there is to go on.
    @Test func aRepositoryGitCannotListIsOfferedAnyway() {
        let record = OwnedWorktree(path: "/unlisted/.wt/x", repoPath: "/unlisted", branch: "x")
        #expect(plan([record]).removable == [
            WorktreeRemovalTarget(repository: "/unlisted", path: "/unlisted/.wt/x", branch: "x"),
        ])
    }

    private let otherTaskID = UUID()

    private func user(_ folder: String) -> WorktreeRemovalPrompt.User {
        .init(folder: folder, taskID: otherTaskID, taskTitle: "Other Task")
    }

    @Test func aWorktreeAnotherTaskIsInIsKept() {
        let result = plan([owned("feature"), owned("other")], users: [user(feature.path + "/src")])
        #expect(result.removable == [other])
        #expect(result.inUse == [.init(worktree: owned("feature"), taskID: otherTaskID, taskTitle: "Other Task")])
    }

    /// An older build could save a subfolder of the worktree as the task's.
    @Test func aSubfolderRecordRemovesItsWorktreesRoot() {
        let record = OwnedWorktree(path: "/repo/.worktrees/feature/app", repoPath: "/repo", branch: "feature")
        let result = plan([record])
        #expect(result.removable == [feature])
        #expect(result.gone.isEmpty)
    }

    @Test func aRecordInsideTheMainCheckoutIsGoneNotRemoved() {
        let record = OwnedWorktree(path: "/repo/app", repoPath: "/repo", branch: "main")
        #expect(plan([record]) == WorktreeRemovalPrompt.Plan(gone: ["/repo/app"]))
    }

    @Test func aUserAnywhereInTheRootKeepsASubfolderRecord() {
        let record = OwnedWorktree(path: "/repo/.worktrees/feature/app", repoPath: "/repo", branch: "feature")
        let result = plan([record], users: [user(feature.path + "/docs")])
        #expect(result.inUse.map(\.path) == [feature.path])
    }

    @Test func twoRecordsInOneWorktreeRemoveItOnce() {
        let sub = OwnedWorktree(path: "/repo/.worktrees/feature/app", repoPath: "/repo", branch: "feature")
        #expect(plan([owned("feature"), sub]).removable == [feature])
    }

    /// The branch check stands in for git: anything it is asked about
    /// fails the test, since a record without a branch must never delete one.
    @Test func noRecordedBranchIsNeverChecked() {
        let record = OwnedWorktree(path: "/repo/.worktrees/feature", repoPath: "/repo", branch: nil)
        let result = WorktreeRemovalPrompt.plan(
            for: [record], users: [], listing: { _ in listing },
            branchExists: { _, branch in Issue.record("checked \(branch)"); return true }
        )
        #expect(result.removable == [WorktreeRemovalTarget(repository: "/repo", path: feature.path, branch: nil)])
    }

    @Test func aRecordedPathIsStandardized() {
        let record = OwnedWorktree(path: "/repo/.worktrees/../.worktrees/feature", repoPath: "/repo", branch: "feature")
        #expect(record.path == "/repo/.worktrees/feature")
        #expect(OwnedWorktree(path: "/tmp", repoPath: "/", branch: nil).path == OwnedWorktree.standardized("/private/tmp"))
    }

    /// Called from the main actor, as the dialog does; every git call must
    /// still run off it.
    @Test func resolveRunsNoGitOnTheMainActor() async {
        let onMain = MainThreadCalls()
        let listing = listing
        let git = WorktreeRemovalPrompt.Git(
            worktrees: { _ in onMain.note("worktrees"); return listing },
            branchExists: { _, _ in onMain.note("branchExists"); return true },
            uncommittedChanges: { _ in onMain.note("uncommittedChanges"); return [" M a.txt"] }
        )

        let (plan, dirty) = await WorktreeRemovalPrompt.resolve([owned("feature")], users: [], git: git)

        #expect(plan.removable == [feature])
        #expect(dirty[feature.path] != nil)
        #expect(onMain.calls.isEmpty)
    }

    // MARK: - Who else uses it

    @Test func aLiveTabOfAnotherTaskIsAUser() throws {
        let context = try makeContext()
        let task = TaskStore.createTask(in: context, siblings: [])
        task.recordOwnedWorktree(owned("feature"))
        let user = TaskStore.createTask(in: context, title: "Other Task", siblings: [task])
        user.tabs[0].workspace = .directory("/repo/.worktrees/feature/src")
        let archived = TaskStore.createTask(in: context, title: "Archived", siblings: [task, user])
        archived.tabs[0].workspace = .directory("/repo/.worktrees/other")
        archived.isArchived = true

        let users = WorktreeRemovalPrompt.users(of: task, among: [task, user, archived])

        #expect(users == [.init(folder: "/repo/.worktrees/feature/src", taskID: user.id, taskTitle: "Other Task")])
    }

    @Test func deletingHandsAWorktreeInUseToItsUser() throws {
        let context = try makeContext()
        let user = TaskStore.createTask(in: context, siblings: [])
        user.recordOwnedWorktree(owned("other"))
        let kept = WorktreeRemovalPrompt.InUse(worktree: owned("feature"), taskID: user.id, taskTitle: "Other Task")

        WorktreeRemovalPrompt.handOff([kept, kept], among: [user])

        #expect(user.ownedWorktrees == [owned("other"), owned("feature")])
    }

    @Test func theTasksOwnTabsDoNotCountAsUsers() throws {
        let context = try makeContext()
        let task = TaskStore.createTask(in: context, siblings: [])
        task.recordOwnedWorktree(owned("feature"))
        task.tabs[0].workspace = .directory("/repo/.worktrees/feature")

        #expect(WorktreeRemovalPrompt.users(of: task, among: [task]).isEmpty)
    }

    // MARK: - Dialog copy

    private func removal(
        _ worktrees: [WorktreeRemovalTarget],
        verb: WorktreeRemovalVerb = .delete,
        inUse: [WorktreeRemovalPrompt.InUse] = [],
        gone: [String] = [],
        dirty: [String: String] = [:]
    ) -> WorktreeRemovalPrompt.PendingRemoval {
        let task = WorkTask(title: "Some Task", orderIndex: 0)
        return .init(
            task: task, verb: verb,
            plan: .init(removable: worktrees, inUse: inUse, gone: gone),
            dirtySummaries: dirty
        )
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

    @Test func nothingRemovableLeavesOnlyTheTaskButton() {
        let delete = removal([], inUse: [.init(worktree: owned("feature"), taskID: UUID(), taskTitle: "Other Task")])
        #expect(!delete.offersRemoval)
        #expect(!delete.offersBranchRemoval)
        #expect(delete.taskOnlyButtonTitle == "Delete")
        #expect(delete.message == "Kept, because another task is using it:\n• /repo/.worktrees/feature, used by “Other Task”")
    }

    @Test func noBranchToRemoveHidesTheBranchButton() {
        let delete = removal([WorktreeRemovalTarget(repository: "/repo", path: feature.path, branch: nil)])
        #expect(delete.offersRemoval)
        #expect(!delete.offersBranchRemoval)
        #expect(delete.message == "This task uses the worktree at /repo/.worktrees/feature.")
    }

    @Test func theMessageNamesTheWorktreeAndBranch() {
        #expect(removal([feature]).message == "This task uses the worktree at /repo/.worktrees/feature on branch feature.")
    }

    @Test func aGoneWorktreeIsNamed() {
        let message = removal([feature], gone: ["/repo/.worktrees/deleted"]).message
        #expect(message.hasSuffix("No longer a worktree:\n• /repo/.worktrees/deleted"))
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

nonisolated private final class MainThreadCalls: Sendable {
    private let recorded = Mutex<[String]>([])

    var calls: [String] { recorded.withLock { $0 } }

    func note(_ call: String) {
        if Thread.isMainThread { recorded.withLock { $0.append(call) } }
    }
}
