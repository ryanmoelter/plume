import Foundation
import Testing
@testable import Plume

/// `wt bg` and `wt fg` refuse what they can before stashing anything, and a
/// step that fails after the stash either restores it or names its SHA.
struct WTMoveTests {
    /// The main worktree `/repo` on `branch`, dirty unless `clean`, with a
    /// worktree `other` at `/repo/.plume/worktrees/other` on `otherBranch`.
    private func context(branch: String, clean: Bool = false, otherBranch: String = "ryanm/other") -> FakeWTContext {
        let ctx = FakeWTContext(
            worktrees: [wtRow("repo", branch, ""), wtRow("other", otherBranch, "")],
            baseBranch: "main",
            current: "repo",
            branchByPath: ["/repo": branch, "/repo/.plume/worktrees/other": otherBranch]
        )
        if !clean { ctx.fakeGit.dirtyPaths = ["/repo"] }
        return ctx
    }

    // MARK: background

    @Test func backgroundOnTheBaseRefusesAnExistingBranchBeforeStashing() {
        let ctx = context(branch: "main")
        ctx.fakeGit.branches = ["main", "feat"]
        let failure = cliFailure { try WT.background(ctx, ["feat", "--no-tab"]) }
        #expect(failure?.message == "branch already exists: feat")
        #expect(ctx.fakeGit.stashes.isEmpty)
    }

    @Test func backgroundRefusesADetachedHead() {
        let ctx = context(branch: "HEAD")
        let failure = cliFailure { try WT.background(ctx, ["--no-tab"]) }
        #expect(failure?.message?.contains("repo is detached") == true)
        #expect(ctx.fakeGit.stashes.isEmpty)
        #expect(ctx.fakeGit.added.isEmpty)
    }

    @Test func backgroundRestoresTheStashWhenDetachingFails() {
        let ctx = context(branch: "ryanm/feat")
        ctx.fakeGit.checkoutFails = { path, _, detach in path == "/repo" && detach }
        let failure = cliFailure { try WT.background(ctx, ["--no-tab"]) }
        #expect(failure?.message == "could not detach repo; changes restored in repo")
        #expect(ctx.fakeGit.restoredStashes.map(\.path) == ["/repo"])
        #expect(ctx.fakeGit.added.isEmpty)
    }

    @Test func backgroundNamesTheStashWhenItCannotRestoreIt() {
        let ctx = context(branch: "main")
        ctx.fakeGit.worktreeAddSucceeds = false
        ctx.fakeGit.stashRestoreSucceeds = false
        let failure = cliFailure { try WT.background(ctx, ["feat", "--no-tab"]) }
        #expect(failure?.message?.contains("still stashed as stash-1") == true)
        #expect(failure?.message?.contains("git stash apply stash-1") == true)
    }

    /// The branch has already moved, so its changes follow it even though
    /// the old worktree couldn't get back onto the base.
    @Test func backgroundStillRestoresInTheNewWorktreeWhenTheBaseCheckoutFails() {
        let ctx = context(branch: "ryanm/feat")
        ctx.fakeGit.checkoutFails = { path, ref, _ in path == "/repo" && ref.hasSuffix("main") }
        let failure = cliFailure { try WT.background(ctx, ["--no-tab"]) }
        #expect(failure?.message?.contains("left detached at ryanm/feat's commit") == true)
        #expect(ctx.fakeGit.added.map(\.path) == ["/repo/.plume/worktrees/feat"])
        #expect(ctx.fakeGit.restoredStashes.map(\.path) == ["/repo/.plume/worktrees/feat"])
    }

    // MARK: foreground

    @Test func foregroundRefusesADetachedSource() {
        let ctx = context(branch: "main", clean: true, otherBranch: "HEAD")
        let failure = cliFailure { try WT.foreground(ctx, ["other"]) }
        #expect(failure?.message?.contains("other is detached") == true)
        #expect(ctx.fakeGit.removed.isEmpty)
        #expect(ctx.fakeGit.stashes.isEmpty)
    }

    @Test func foregroundRestoresTheSourcesStashWhenDetachingItFails() {
        let ctx = context(branch: "main", clean: true)
        ctx.fakeGit.dirtyPaths = ["/repo/.plume/worktrees/other"]
        ctx.fakeGit.checkoutFails = { path, _, detach in path == "/repo/.plume/worktrees/other" && detach }
        let failure = cliFailure { try WT.foreground(ctx, ["other"]) }
        #expect(failure?.message == "could not detach other; changes restored there")
        #expect(ctx.fakeGit.restoredStashes.map(\.path) == ["/repo/.plume/worktrees/other"])
        #expect(ctx.fakeGit.removed.isEmpty)
    }

    @Test func foregroundSaysSoWhenTheSourceCannotBeRemoved() {
        let ctx = context(branch: "main", clean: true)
        ctx.fakeGit.unremovablePaths = ["/repo/.plume/worktrees/other"]
        let failure = cliFailure { try WT.foreground(ctx, ["other"]) }
        #expect(failure?.message?.hasPrefix("checked out ryanm/other in repo, but could not remove other") == true)
    }

    // MARK: a tag named like the branch

    /// A bare name would detach at a same-named tag, which git prefers.
    @Test func backgroundDetachesAtTheBranchNotATagOfTheSameName() throws {
        let ctx = context(branch: "ryanm/feat")
        ctx.fakeGit.checkoutFails = { _, ref, detach in detach && ref != GitRef.local("ryanm/feat") }
        try WT.background(ctx, ["--no-tab"])
        #expect(ctx.fakeGit.added.map(\.path) == ["/repo/.plume/worktrees/feat"])
    }

    @Test func foregroundDetachesAtTheBranchNotATagOfTheSameName() throws {
        let ctx = context(branch: "main", clean: true)
        ctx.fakeGit.checkoutFails = { _, ref, detach in detach && ref != GitRef.local("ryanm/other") }
        try WT.foreground(ctx, ["other"])
        #expect(ctx.fakeGit.removed == ["/repo/.plume/worktrees/other"])
    }
}
