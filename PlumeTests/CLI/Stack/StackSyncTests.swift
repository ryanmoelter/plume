import Foundation
import Testing
@testable import Plume

/// `stack sync` against real repositories with only the forge faked: a
/// parent PR is squash-merged, the forge retargets the child, and sync
/// absorbs the parent and replays the child. Sync must replay exactly the
/// child's own commits onto the squashed trunk, including any added after
/// the merge.
///
/// trunk ← b1 ← b2, with b1 squash-merged.
final class StackSyncFixture {
    let repo: StackScratchRepo
    let trunk0: String
    let b1Tip: String
    let b2Tip: String
    let squash: String
    var state: StackBranches

    init() throws {
        repo = try StackScratchRepo()
        trunk0 = try repo.rev("HEAD")
        try repo.git("switch", "-qc", "b1")
        try repo.commit("b1-one")
        b1Tip = try repo.commit("b1-two")
        try repo.git("switch", "-qc", "b2")
        try repo.commit("b2-one")
        b2Tip = try repo.commit("b2-two")
        try repo.git("switch", "-q", "main")
        try repo.git("merge", "-q", "--squash", "b1")
        try repo.git("commit", "-q", "-m", "squashed b1")
        squash = try repo.rev("HEAD")
        try repo.git("push", "-q", "origin", "main")
        state = ["b1": entry("main", trunk0), "b2": entry("b1", b1Tip)]
    }

    let console = BufferConsole()

    @discardableResult
    func sync(_ forge: RecordingStackForge, _ arguments: [String] = []) throws -> StackBranches {
        try repo.git("switch", "-q", "b2")
        try repo.writeState(state)
        try Stack.sync(repo.context(forge: forge, console: console), arguments)
        return try repo.loadState()
    }
}

struct StackSquashMergeSyncTests {
    let f: StackSyncFixture

    init() throws {
        f = try StackSyncFixture()
    }

    var repo: StackScratchRepo { f.repo }

    /// Fresh-clone recovery: a local branch with an open PR based on the
    /// trunk joins the stack.
    @Test func tracksAnUntrackedBranchWithAnOpenPR() throws {
        try repo.git("switch", "-qc", "loose", "main")
        let looseTip = try repo.commit("loose-one")
        let forge = RecordingStackForge([
            "b1": stackPR(1, headRefOid: f.b1Tip),
            "loose": stackPR(9, headRefOid: looseTip),
        ])
        let branches = try f.sync(forge)
        #expect(branches["loose"]?.parent == "main")
        #expect(f.console.stdout.contains("tracking 'loose' (PR #9, base main)"))
    }

    @Test func doesNotTrackABranchWhosePRIsClosed() throws {
        try repo.git("switch", "-qc", "loose", "main")
        let looseTip = try repo.commit("loose-one")
        let branches = try f.sync(RecordingStackForge(["loose": stackPR(9, state: .closed, headRefOid: looseTip)]))
        #expect(branches["loose"] == nil)
    }

    /// A commit lands on b2 after the merge; the replay range is bounded
    /// below by the stored base and open above, so it rides along.
    @Test func absorbsTheParentAndKeepsEveryChildCommit() throws {
        try repo.git("switch", "-q", "b2")
        try repo.commit("b2-three")
        let forge = RecordingStackForge([
            // GitHub reports b1's pre-squash tip.
            "b1": stackPR(1, state: .merged, headRefOid: f.b1Tip),
            "b2": stackPR(2, headRefOid: f.b2Tip),
        ])
        let branches = try f.sync(forge)

        #expect(branches["b1"] == nil)
        #expect(branches["b2"]?.parent == "main")
        #expect(!(try repo.localBranches()).contains("b1"))
        let subjects = try repo.subjects("b2")
        #expect(Array(subjects.prefix(3)) == ["b2-three", "b2-two", "b2-one"])
        #expect(subjects.contains("squashed b1"))
        for subject in ["b2-one", "b2-two", "b2-three"] {
            #expect(subjects.filter { $0 == subject }.count == 1, "\(subject): \(subjects)")
        }
        #expect(!subjects.contains("b1-one"))
        #expect(!subjects.contains("b1-two"))
        #expect(try repo.isAncestor(f.squash, "b2"))
        #expect(branches["b2"]?.base == f.squash)
        #expect(f.console.stdout.contains("removing 'b1' (PR #1 merged) — children move onto 'main'"))
    }

    /// If b1 has commits the merge didn't include, absorbing would drop
    /// them, so sync skips the stack instead of deleting the branch.
    @Test func skipsAStackWhoseLocalCommitsPostdateTheMerge() throws {
        try repo.git("switch", "-q", "b1")
        try repo.commit("b1-unmerged")
        let forge = RecordingStackForge([
            "b1": stackPR(1, state: .merged, headRefOid: f.b1Tip),
            "b2": stackPR(2, base: "b1", headRefOid: f.b2Tip),
        ])
        let failure = stackFailure { try f.sync(forge) }
        #expect(failure == CLIFailure(nil, code: 1))
        #expect(try repo.loadState()["b1"] != nil)
        #expect(try repo.localBranches().contains("b1"))
        #expect(f.console.stderr.contains("stack: 'b1' has local commits beyond merged PR #1 — reconcile manually; skipping its stack"))
    }

    /// After absorption b2's parent is main, and GitHub already set its base
    /// to main, so retargeting issues no edit.
    @Test func noRedundantRetargetWhenGitHubAlreadyDidIt() throws {
        let forge = RecordingStackForge([
            "b1": stackPR(1, state: .merged, headRefOid: f.b1Tip),
            "b2": stackPR(2, headRefOid: f.b2Tip),
        ])
        let branches = try f.sync(forge)
        try Stack.retargetPR(repo.context(forge: forge), forge, branch: "b2", pr: forge.prs["b2"]!, parent: branches["b2"]!.parent, dryRun: false)
        #expect(forge.edits.isEmpty)
    }

    @Test func retargetsWhenTheBaseIsStillTheAbsorbedBranch() throws {
        let forge = RecordingStackForge([
            "b1": stackPR(1, state: .merged, headRefOid: f.b1Tip),
            "b2": stackPR(2, base: "b1", headRefOid: f.b2Tip),
        ])
        let branches = try f.sync(forge)
        let console = BufferConsole()
        try Stack.retargetPR(repo.context(forge: forge, console: console), forge, branch: "b2", pr: forge.prs["b2"]!, parent: branches["b2"]!.parent, dryRun: false)
        #expect(forge.edits.map(\.number) == [2])
        #expect(forge.edits.map(\.base) == ["main"])
        #expect(console.stdout == "  retargeted PR #2 (b2) base → main\n")
    }

    /// Lands an unrelated commit on origin's trunk.
    func advanceTrunk() throws -> String {
        try repo.git("switch", "-q", "main")
        let sha = try repo.commit("trunk-moved")
        try repo.git("push", "-q", "origin", "main")
        return sha
    }

    /// Behind a fast-moving trunk isn't a restack.
    @Test func leavesTheRootBehindAMovedTrunkByDefault() throws {
        let moved = try advanceTrunk()
        let forge = RecordingStackForge([
            "b1": stackPR(1, headRefOid: f.b1Tip),
            "b2": stackPR(2, base: "b1", headRefOid: f.b2Tip),
        ])
        let branches = try f.sync(forge)
        #expect(try repo.rev("b1") == f.b1Tip)
        #expect(!(try repo.isAncestor(moved, "b1")))
        #expect(branches["b1"]?.base == f.trunk0)
    }

    @Test func theTrunkFlagRebasesTheRootOntoTheMovedTrunk() throws {
        let moved = try advanceTrunk()
        let forge = RecordingStackForge([
            "b1": stackPR(1, headRefOid: f.b1Tip),
            "b2": stackPR(2, base: "b1", headRefOid: f.b2Tip),
        ])
        let branches = try f.sync(forge, ["--trunk"])
        #expect(try repo.isAncestor(moved, "b1"))
        #expect(try repo.isAncestor(moved, "b2"))
        #expect(branches["b1"]?.base == moved)
        #expect(Array(try repo.subjects("b2").prefix(2)) == ["b2-two", "b2-one"])
        #expect(branches["b2"]?.base == (try repo.rev("b1")))
    }

    /// When the landed version differs from what was reviewed, patch-ids no
    /// longer match, and only the stored base keeps the parent's stale
    /// commits out.
    @Test func theReplayExcludesReworkedParentCommits() throws {
        try repo.git("switch", "-q", "main")
        try repo.write("b1-one", "reworked by the maintainer")
        try repo.git("commit", "-qam", "rework b1-one")
        let reworked = try repo.rev("HEAD")
        try repo.git("push", "-q", "-f", "origin", "main")
        let forge = RecordingStackForge([
            "b1": stackPR(1, state: .merged, headRefOid: f.b1Tip),
            "b2": stackPR(2, headRefOid: f.b2Tip),
        ])
        let branches = try f.sync(forge)
        let subjects = try repo.subjects("b2")
        #expect(!subjects.contains("b1-one"))
        for subject in ["b2-one", "b2-two"] {
            #expect(subjects.filter { $0 == subject }.count == 1)
        }
        #expect(try repo.isAncestor(reworked, "b2"))
        #expect(try repo.read("b1-one") == "reworked by the maintainer")
        #expect(branches["b2"]?.base == (try repo.rev("origin/main")))
    }

    @Test func noForgeFails() throws {
        try repo.writeState(f.state)
        let failure = stackFailure { try Stack.sync(repo.context(), []) }
        #expect(failure?.message == "no GitHub or GitLab remote detected — set the forge for this repository in Plume's Settings ▸ Projects")
    }
}

/// trunk ← b1 ← b2 ← b3, all pushed, b1 squash-merged. A forge that
/// restacks server-side has already replayed the rest onto the squash and
/// force-pushed it, while the local branches still sit on b1's old tip.
/// Sync adopts those remote heads rather than rebasing and pushing again.
struct StackAdoptRemoteRestackTests {
    let f: StackSyncFixture
    let b3Tip: String
    let forge: RecordingStackForge

    init() throws {
        f = try StackSyncFixture()
        let repo = f.repo
        try repo.git("switch", "-qc", "b3", "b2")
        b3Tip = try repo.commit("b3-one")
        try repo.git("switch", "-q", "main")
        for (branch, sha) in [("b1", f.b1Tip), ("b2", f.b2Tip), ("b3", b3Tip)] {
            try repo.git("push", "-q", "origin", "\(sha):refs/heads/\(branch)")
        }
        try repo.git("fetch", "-q", "origin")
        f.state["b3"] = entry("b2", f.b2Tip)
        forge = RecordingStackForge([
            "b1": stackPR(1, state: .merged, headRefOid: f.b1Tip),
            "b2": stackPR(2, headRefOid: f.b2Tip),
            "b3": stackPR(3, base: "b2", headRefOid: b3Tip),
        ])
    }

    var repo: StackScratchRepo { f.repo }
    var out: String { f.console.stdout }

    /// Replays `branch` onto `onto` and force-pushes it as the forge does,
    /// leaving the local branch alone. Returns the new head.
    @discardableResult
    func remoteRebase(_ branch: String, onto: String, oldBase: String, then: (() throws -> Void)? = nil) throws -> String {
        try repo.git("switch", "-qc", "tmp", branch)
        try repo.git("-c", "rebase.updateRefs=false", "rebase", "-q", "--onto", onto, oldBase)
        try then?()
        let sha = try repo.rev("HEAD")
        try repo.git("push", "-q", "-f", "origin", "tmp:\(branch)")
        try repo.git("switch", "-q", "main")
        try repo.git("branch", "-D", "tmp")
        return sha
    }

    func restackRemotely() throws -> (String, String) {
        let r2 = try remoteRebase("b2", onto: f.squash, oldBase: f.b1Tip)
        let r3 = try remoteRebase("b3", onto: r2, oldBase: f.b2Tip)
        return (r2, r3)
    }

    func remote(_ branch: String) throws -> String {
        try repo.git("rev-parse", "refs/heads/\(branch)", in: repo.origin)
    }

    @Test func adoptsAMatchingRemoteAndSkipsItsPush() throws {
        let (r2, _) = try restackRemotely()
        let branches = try f.sync(forge, ["--push"])
        #expect(try repo.rev("b2") == r2)
        #expect(try remote("b2") == r2)
        #expect(branches["b2"]?.base == f.squash)
        #expect(out.contains("b2: adopted origin/b2 (already restacked on the remote)"))
        #expect(out.contains("b2: up to date on origin — not pushing"))
        #expect(!out.contains("pushed b2"))
    }

    @Test func adoptsARemoteWithExtraCommits() throws {
        let r2 = try remoteRebase("b2", onto: f.squash, oldBase: f.b1Tip) {
            try repo.commit("bot-translations")
        }
        try f.sync(forge, ["--push"])
        #expect(try repo.rev("b2") == r2)
        #expect(try repo.subjects("b2").first == "bot-translations")
        #expect(!out.contains("pushed b2"))
    }

    @Test func replaysUnpushedLocalCommitsOntoTheAdoptedHead() throws {
        let (r2, _) = try restackRemotely()
        try repo.git("switch", "-q", "b2")
        try repo.commit("b2-unpushed")
        try f.sync(forge, ["--push"])
        #expect(try repo.rev("b2^") == r2)
        let subjects = try repo.subjects("b2")
        #expect(subjects.first == "b2-unpushed")
        for subject in ["b2-one", "b2-two", "b2-unpushed"] {
            #expect(subjects.filter { $0 == subject }.count == 1)
        }
        #expect(out.contains("replayed 1 local commit(s)"))
        #expect(try remote("b2") == (try repo.rev("b2")))
        #expect(out.contains("pushed b2"))
    }

    @Test func rebasesWhenTheRemoteWasNotRestacked() throws {
        try f.sync(forge)
        #expect(out.contains("b2: rebased onto main"))
        #expect(try repo.isAncestor(f.squash, "b2"))
        #expect(try remote("b2") == f.b2Tip)
    }

    @Test func rebasesWhenTheRemoteRestackDiffers() throws {
        let r2 = try remoteRebase("b2", onto: f.squash, oldBase: f.b1Tip) {
            try repo.write("b2-two", "different")
            try repo.git("commit", "-qam", "b2-two", "--amend")
        }
        try f.sync(forge)
        #expect(out.contains("b2: rebased onto main"))
        #expect(try repo.rev("b2") != r2)
        #expect(try repo.isAncestor(f.squash, "b2"))
    }

    @Test func allAdoptsTheWholeRemainingChain() throws {
        let (r2, r3) = try restackRemotely()
        let branches = try f.sync(forge, ["--all", "--push"])
        #expect(try repo.rev("b2") == r2)
        #expect(try repo.rev("b3") == r3)
        #expect(branches["b3"]?.base == r2)
        #expect(!out.contains("pushed"))
    }

    @Test func theDefaultScopeNamesTheChildrenLeftBehind() throws {
        _ = try restackRemotely()
        try f.sync(forge)
        #expect(try repo.rev("b3") == b3Tip)
        #expect(f.console.stderr.contains("branches above 'b2' may need their own restack: b3"))
    }

    func addWorktree(_ branch: String) throws -> String {
        let path = "\(repo.directory)/wt-\(branch)"
        try repo.git("worktree", "add", "-q", path, branch)
        return path
    }

    @Test func adoptsABranchCheckedOutInAnotherWorktree() throws {
        let (_, r3) = try restackRemotely()
        let worktree = try addWorktree("b3")
        try f.sync(forge, ["--all"])
        #expect(try repo.rev("b3") == r3)
        #expect(try repo.git("rev-parse", "HEAD", in: worktree) == r3)
    }

    @Test func rebasesABranchCheckedOutInAnotherWorktree() throws {
        let worktree = try addWorktree("b3")
        try f.sync(forge, ["--all"])
        #expect(try repo.isAncestor(repo.rev("b2"), "b3"))
        #expect(try repo.git("rev-parse", "HEAD", in: worktree) == (try repo.rev("b3")))
        #expect(Array(try repo.subjects("HEAD", in: worktree).prefix(3)) == ["b3-one", "b2-two", "b2-one"])
    }

    @Test func aDirtyWorktreeStopsWithItsPath() throws {
        _ = try restackRemotely()
        let worktree = try addWorktree("b3")
        try repo.write("b3-one", "wip", in: worktree)
        let failure = stackFailure { try f.sync(forge, ["--all"]) }
        #expect(failure?.message == "'b3' is checked out in \(worktree) with uncommitted changes — commit or stash there, then re-run")
        #expect(try repo.rev("b3") == b3Tip)
    }

    @Test func aDryRunReportsEachDecision() throws {
        _ = try restackRemotely()
        try f.sync(forge, ["--all", "--push", "--dry-run"])
        #expect(out.contains("b2: would adopt origin/b2 (already restacked on the remote)"))
        #expect(out.contains("b3: would adopt origin/b3 (already restacked on the remote)"))
        #expect(out.contains("b2: up to date on origin — not pushing"))
        #expect(!out.contains("would push"))
        #expect(try repo.rev("b2") == f.b2Tip)
        #expect(try repo.rev("b3") == b3Tip)
    }

    @Test func aDryRunRebaseCascadesToChildren() throws {
        try f.sync(forge, ["--all", "--dry-run"])
        #expect(out.contains("b2: would rebase onto main"))
        #expect(out.contains("b3: would rebase onto b2"))
    }

    /// `stack restack` from b2 once b1 is gone, with origin unreachable.
    func restackAfterAbsorb() throws -> String {
        try repo.git("switch", "-q", "b2")
        try repo.git("branch", "-D", "b1")
        try repo.git("remote", "set-url", "origin", "/nonexistent")
        try repo.writeState(["b2": entry("main", f.b1Tip)])
        let console = BufferConsole()
        try Stack.restack(repo.context(console: console), [])
        return console.stdout
    }

    @Test func restackAdoptsFromFetchedRefsWithoutNetwork() throws {
        let (r2, _) = try restackRemotely()
        try repo.git("fetch", "-q", "origin")
        let out = try restackAfterAbsorb()
        #expect(out.contains("b2: adopted origin/b2"))
        #expect(try repo.rev("b2") == r2)
    }

    @Test func restackRebasesWithoutARemoteBranch() throws {
        try repo.git("update-ref", "-d", "refs/remotes/origin/b2")
        let out = try restackAfterAbsorb()
        #expect(out.contains("b2: rebased onto main"))
        #expect(try repo.isAncestor(f.squash, "b2"))
    }
}
