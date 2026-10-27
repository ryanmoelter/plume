import Foundation
import Testing
@testable import Plume

/// Restack against real repositories, so git's own rebase arithmetic runs.
/// They pin the replay range: a branch that merged its parent or the trunk
/// in, rather than rebasing, replays only its own commits, never the range
/// it merged.
struct StackMergedInTrunkTests {
    let repo: StackScratchRepo
    /// Where `feat` forked, and so the base stored for it.
    let fork: String
    let state: StackBranches

    init() throws {
        repo = try StackScratchRepo()
        for index in 1...3 { try repo.commit("trunk-\(index)") }
        fork = try repo.rev("HEAD")
        try repo.git("switch", "-qc", "feat")
        try repo.commit("feat-one")
        try repo.git("switch", "-q", "main")
        for index in 4...6 { try repo.commit("trunk-\(index)") }
        // The merge moves the fork point while the stored base stays put.
        try repo.git("switch", "-q", "feat")
        try repo.git("merge", "-q", "--no-edit", "main")
        try repo.commit("feat-two")
        try repo.git("switch", "-q", "main")
        for index in 7...8 { try repo.commit("trunk-\(index)") }
        try repo.pushTrunk()
        try repo.git("switch", "-q", "feat")
        state = ["feat": entry("main", fork)]
    }

    @Test func replaysOnlyTheBranchsOwnCommits() throws {
        try repo.writeState(state)
        try Stack.restack(repo.context(), ["--trunk"])

        let subjects = try repo.subjects("feat")
        #expect(Array(subjects.prefix(2)) == ["feat-two", "feat-one"])
        for subject in ["feat-one", "feat-two"] + (1...8).map({ "trunk-\($0)" }) {
            #expect(subjects.filter { $0 == subject }.count == 1, "\(subject): \(subjects)")
        }
        let trunkTip = try repo.rev("origin/main")
        #expect(try repo.isAncestor(trunkTip, "feat"))
        #expect(try repo.loadState()["feat"]?.base == trunkTip)
        #expect(try repo.git("rev-list", "--count", "--merges", "\(trunkTip)..feat") == "0")
    }

    @Test func theFloorRisesToTheForkPoint() throws {
        let ctx = repo.context()
        let floor = try ctx.replayFloor(state, "feat", parentTip: ctx.trunkTip())
        #expect(floor != fork)
        #expect(floor == (try repo.git("merge-base", "origin/main", "feat")))
        #expect(try repo.git("rev-list", "--count", "--no-merges", "\(floor)..feat") == "2")
    }
}

/// Patch-id detection usually drops merged-in commits on its own, so a stale
/// floor often lands anyway, having replayed work it didn't need to. It
/// stops being harmless once one of those commits conflicts: the user lands
/// in a conflict on someone else's commit.
struct StackConflictAttributionTests {
    let repo: StackScratchRepo
    let fork: String

    init() throws {
        repo = try StackScratchRepo()
        try repo.write("shared", "base")
        try repo.git("add", "shared")
        try repo.git("commit", "-q", "-m", "trunk-one")
        fork = try repo.rev("HEAD")
        try repo.git("switch", "-qc", "feat")
        try repo.commit("feat-one")
        try repo.git("switch", "-q", "main")
        try repo.write("shared", "trunk version")
        try repo.git("commit", "-qam", "trunk-two")
        // feat merges trunk in and resolves `shared` its own way.
        try repo.git("switch", "-q", "feat")
        try repo.gitAllowingFailure("merge", "-q", "--no-edit", "main")
        try repo.write("shared", "feat version")
        try repo.git("add", "shared")
        try repo.git("commit", "-q", "-m", "feat-two")
        try repo.git("switch", "-q", "main")
        try repo.write("shared", "trunk version two")
        try repo.git("commit", "-qam", "trunk-three")
        try repo.pushTrunk()
        try repo.git("switch", "-q", "feat")
    }

    func conflictingSubject(floor: String) throws -> String {
        try repo.gitAllowingFailure("rebase", "--onto", "main", floor, "feat")
        defer { _ = try? repo.gitAllowingFailure("rebase", "--abort") }
        return try repo.git("log", "-1", "--format=%s", "REBASE_HEAD")
    }

    @Test func theConflictLandsOnTheUsersOwnCommit() throws {
        let ctx = repo.context()
        let floor = try ctx.replayFloor(["feat": entry("main", fork)], "feat", parentTip: ctx.trunkTip())
        #expect(try conflictingSubject(floor: floor) == "feat-two")
    }

    /// What the stored base alone would do.
    @Test func theStaleFloorConflictsOnATrunkCommit() throws {
        #expect(try conflictingSubject(floor: fork) == "trunk-two")
    }

    @Test func aConflictStopsWithExitThreeAndAttribution() throws {
        let console = BufferConsole()
        try repo.writeState(["feat": entry("main", fork)])
        defer { _ = try? repo.gitAllowingFailure("rebase", "--abort") }
        let failure = stackFailure { try Stack.restack(repo.context(console: console), ["--trunk"]) }
        #expect(failure == CLIFailure(nil, code: Stack.conflictExitCode))
        #expect(console.stderr == """
            stack: rebase of 'feat' onto 'main' stopped on conflicts.
              resolve them, then `git rebase --continue` (or `git rebase --abort`),
              then re-run `stack restack` — it resumes where it stopped.

            """)
    }
}

/// The same shape one level up: a child merges its tracked parent in, then
/// the parent grows.
struct StackMergedInParentTests {
    let repo: StackScratchRepo
    let state: StackBranches

    init() throws {
        repo = try StackScratchRepo()
        try repo.commit("trunk-one")
        let trunk0 = try repo.rev("HEAD")
        try repo.pushTrunk()
        try repo.git("switch", "-qc", "parent")
        try repo.commit("parent-one")
        try repo.git("switch", "-qc", "child")
        try repo.commit("child-one")
        let childBase = try repo.rev("HEAD~1")
        try repo.git("switch", "-q", "parent")
        try repo.commit("parent-two")
        try repo.git("switch", "-q", "child")
        try repo.git("merge", "-q", "--no-edit", "parent")
        try repo.commit("child-two")
        try repo.git("switch", "-q", "parent")
        try repo.commit("parent-three")
        try repo.git("switch", "-q", "child")
        state = ["parent": entry("main", trunk0), "child": entry("parent", childBase)]
    }

    @Test func replaysOnlyTheChildsOwnCommits() throws {
        try repo.writeState(state)
        let console = BufferConsole()
        try Stack.restack(repo.context(console: console), [])

        let subjects = try repo.subjects("child")
        #expect(Array(subjects.prefix(2)) == ["child-two", "child-one"])
        for subject in ["child-one", "child-two", "parent-one", "parent-two", "parent-three"] {
            #expect(subjects.filter { $0 == subject }.count == 1, "\(subject): \(subjects)")
        }
        let parentTip = try repo.rev("parent")
        #expect(try repo.isAncestor(parentTip, "child"))
        #expect(try repo.loadState()["child"]?.base == parentTip)
        #expect(console.stdout == "  parent: already stacked\n  child: rebased onto parent\n")
        #expect(try repo.git("symbolic-ref", "--short", "HEAD") == "child")
    }

    @Test func aDryRunChangesNothing() throws {
        try repo.writeState(state)
        let before = try repo.rev("child")
        let console = BufferConsole()
        try Stack.restack(repo.context(console: console), ["--dry-run"])
        #expect(console.stdout == "  parent: already stacked\n  child: would rebase onto parent\n")
        #expect(try repo.rev("child") == before)
        #expect(try repo.loadState() == state)
    }

    @Test func aDirtyTreeRefuses() throws {
        try repo.writeState(state)
        try repo.write("child-one", "edited")
        #expect(stackFailure { try Stack.restack(repo.context(), []) }?.message == "working tree not clean — commit or stash first")
    }

    @Test func interactiveCombinesWithNothing() throws {
        try repo.writeState(state)
        #expect(stackFailure { try Stack.restack(repo.context(), ["-i", "--all"]) }?.message
            == "-i rebases only the current branch — incompatible with --all/--trunk/--dry-run")
    }

    @Test func aScopedRestackNamesTheBranchesLeftAbove() throws {
        try repo.writeState(state)
        try repo.git("switch", "-q", "parent")
        let console = BufferConsole()
        try Stack.restack(repo.context(console: console), [])
        #expect(console.stderr == "stack: branches above 'parent' may need their own restack: child (run from there or use --all)\n")
    }
}

/// The stored base must survive a squash-merged parent: it is all that keeps
/// the parent's commits out of the child's replay.
struct StackSquashMergeFloorTests {
    let repo: StackScratchRepo
    let parentTip: String
    let state: StackBranches

    init() throws {
        repo = try StackScratchRepo()
        try repo.git("switch", "-qc", "b1")
        try repo.commit("b1-one")
        parentTip = try repo.commit("b1-two")
        try repo.git("switch", "-qc", "b2")
        try repo.commit("b2-one")
        // b1 lands as a squash, then a maintainer reworks it so the patch-ids
        // no longer match.
        try repo.git("switch", "-q", "main")
        try repo.git("merge", "-q", "--squash", "b1")
        try repo.git("commit", "-q", "-m", "squashed b1")
        try repo.write("b1-one", "reworked by the maintainer")
        try repo.git("commit", "-qam", "rework b1-one")
        try repo.pushTrunk()
        try repo.git("switch", "-q", "b2")
        // After absorption: b2 reparented onto main, its base still b1's old
        // tip.
        state = ["b2": entry("main", parentTip)]
    }

    @Test func keepsTheStoredBase() throws {
        let ctx = repo.context()
        #expect(try ctx.replayFloor(state, "b2", parentTip: ctx.trunkTip()) == parentTip)
    }

    @Test func restackDoesNotReplayTheParentsCommits() throws {
        try repo.writeState(state)
        try Stack.restack(repo.context(), ["--trunk"])
        let subjects = try repo.subjects("b2")
        #expect(subjects.filter { $0 == "b2-one" }.count == 1)
        #expect(!subjects.contains("b1-one"))
        #expect(!subjects.contains("b1-two"))
        #expect(try repo.read("b1-one") == "reworked by the maintainer")
    }
}

struct StackReplayFloorTests {
    let repo: StackScratchRepo

    init() throws {
        repo = try StackScratchRepo()
    }

    @Test func anOrdinaryForkPointIsUnchanged() throws {
        try repo.commit("trunk-one")
        let base = try repo.rev("HEAD")
        try repo.git("switch", "-qc", "feat")
        try repo.commit("feat-one")
        try repo.git("switch", "-q", "main")
        try repo.commit("trunk-two")
        try repo.git("switch", "-q", "feat")
        let ctx = repo.context()
        #expect(try ctx.replayFloor(["feat": entry("main", base)], "feat", parentTip: repo.rev("main")) == base)
    }

    @Test func anUnreachableBaseFallsBackToTheMergeBase() throws {
        try repo.commit("trunk-one")
        try repo.git("switch", "-qc", "feat")
        try repo.commit("feat-one")
        try repo.git("switch", "-q", "main")
        let orphan = try repo.commit("trunk-two")
        try repo.git("switch", "-q", "feat")
        let console = BufferConsole()
        let ctx = repo.context(console: console)
        let parentTip = try repo.rev("main")
        let mergeBase = try repo.git("merge-base", "main", "feat")
        #expect(try ctx.replayFloor(["feat": entry("main", orphan)], "feat", parentTip: parentTip) == mergeBase)
        #expect(console.stderr == "stack: stored base for 'feat' is stale — using merge-base \(mergeBase.prefix(12))\n")
    }
}
