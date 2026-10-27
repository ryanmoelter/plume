import Foundation
import Testing
@testable import Plume

/// `wt prune`'s selection rules. Worktrees and bare branches both qualify
/// when their PR is merged or closed, or when the branch is already merged
/// into the base; both skip protected, current and trunk entries. A branch
/// with commits its merged or closed PR lacks stays listed with a note, and
/// is kept. Ported from `test_wt_prune.py`.
struct WTPruneTests {
    private static func pr(_ number: Int, _ state: PullRequestState) -> PullRequest {
        PullRequest(number: number, state: state, isDraft: false, headRefOid: "head-\(number)")
    }

    private static let records = [
        WorktreeRecord(branch: "main", path: "/repo"),
        WorktreeRecord(branch: "ryanm/merged", path: "/repo/.wt/merged"),
        WorktreeRecord(branch: "ryanm/closed", path: "/repo/.wt/closed"),
        WorktreeRecord(branch: "ryanm/open", path: "/repo/.wt/open"),
        WorktreeRecord(branch: "ryanm/nopr", path: "/repo/.wt/nopr"),
    ]

    private static let prs: PullRequestMap = [
        "ryanm/merged": pr(1, .merged),
        "ryanm/closed": pr(2, .closed),
        "ryanm/open": pr(3, .open),
    ]

    private static func never(_ branch: String) -> Bool { false }
    private static func withinEveryPR(_ branch: String, _ headOid: String) -> Bool { true }

    // MARK: local merge

    @Test func anAncestorIsMerged() {
        #expect(WT.isMergedLocally(FakeWorktreeGit(merged: ["ryanm/done"]), branch: "ryanm/done", baseRef: "origin/main"))
    }

    @Test func aNonAncestorIsNotMerged() {
        #expect(!WT.isMergedLocally(FakeWorktreeGit(), branch: "ryanm/wip", baseRef: "origin/main"))
    }

    // MARK: worktrees

    private func candidates(
        records: [WorktreeRecord] = records,
        prs: PullRequestMap = prs,
        protected: [String] = ["repo"],
        cwd: String? = nil,
        locallyMerged: (String) -> Bool = never,
        withinPRHead: (String, String) -> Bool = withinEveryPR
    ) -> [PruneCandidate] {
        WT.pruneCandidates(
            records: records, prs: prs, protected: protected, cwdName: cwd, baseBranch: "main",
            locallyMerged: locallyMerged, withinPRHead: withinPRHead
        )
    }

    @Test func onlyMergedAndClosedAreSelected() {
        #expect(candidates().map(\.name) == ["merged", "closed"])
    }

    @Test func aCandidateCarriesNameBranchPathPRAndReason() {
        #expect(candidates().first == PruneCandidate(
            name: "merged", branch: "ryanm/merged", path: "/repo/.wt/merged", pr: Self.prs["ryanm/merged"], reason: "merged"
        ))
    }

    @Test func openAndMissingPRsAreSkipped() {
        let names = candidates().map(\.name)
        #expect(!names.contains("open"))
        #expect(!names.contains("nopr"))
    }

    @Test func protectedNamesAreSkipped() {
        #expect(candidates(protected: ["repo", "merged"]).map(\.name) == ["closed"])
    }

    @Test func theWorkingDirectorysWorktreeIsSkipped() {
        #expect(candidates(cwd: "closed").map(\.name) == ["merged"])
    }

    @Test func theBaseBranchIsSkippedEvenWhenMerged() {
        var prs = Self.prs
        prs["main"] = Self.pr(9, .merged)
        let names = candidates(records: Self.records + [WorktreeRecord(branch: "main", path: "/repo/.wt/main-copy")], prs: prs).map(\.name)
        #expect(!names.contains("main-copy"))
    }

    @Test func nothingQualifyingIsEmpty() {
        let open = [WorktreeRecord(branch: "ryanm/open", path: "/repo/.wt/open")]
        #expect(candidates(records: open, prs: ["ryanm/open": Self.pr(3, .open)]).isEmpty)
    }

    @Test func aLocallyMergedBranchWithoutAPRQualifies() {
        #expect(candidates(locallyMerged: { $0 == "ryanm/nopr" }).map(\.name).contains("nopr"))
    }

    @Test func theReasonTellsPRStateFromALocalMerge() {
        let reasons = Dictionary(uniqueKeysWithValues: candidates(locallyMerged: { $0 == "ryanm/nopr" }).map { ($0.name, $0.reason) })
        #expect(reasons["merged"] == "merged")
        #expect(reasons["closed"] == "closed")
        #expect(reasons["nopr"] == "merged into main")
    }

    @Test func aBranchWithCommitsItsPRLacksIsKeptWithANote() {
        let kept = candidates(withinPRHead: { branch, _ in branch != "ryanm/merged" && branch != "ryanm/closed" })
        #expect(kept.map(\.name) == ["merged", "closed"])
        #expect(kept.allSatisfy { $0.skipNote == "has commits the PR doesn't" })
    }

    @Test func thePRHeadIsCheckedAgainstTheBranch() {
        var checked: [String: String] = [:]
        _ = candidates(withinPRHead: { branch, headOid in
            checked[branch] = headOid
            return true
        })
        #expect(checked == ["ryanm/merged": "head-1", "ryanm/closed": "head-2"])
    }

    @Test func aPRWithoutAHeadIsKept() {
        let prs: PullRequestMap = ["ryanm/merged": PullRequest(number: 1, state: .merged, isDraft: false)]
        #expect(candidates(prs: prs).map(\.skipNote) == ["has commits the PR doesn't"])
    }

    @Test func aLocalMergeOutweighsCommitsThePRLacks() {
        let kept = candidates(locallyMerged: { $0 == "ryanm/merged" }, withinPRHead: { _, _ in false })
        #expect(kept.first { $0.name == "merged" }?.skipNote == nil)
        #expect(kept.first { $0.name == "merged" }?.reason == "merged into main")
    }

    @Test func aBranchAtThePRHeadIsWithinIt() {
        let git = FakeWorktreeGit()
        git.shas = ["refs/heads/ryanm/x": "abc"]
        #expect(WT.isWithinPRHead(git, branch: "ryanm/x", headOid: "abc"))
        #expect(!WT.isWithinPRHead(git, branch: "ryanm/x", headOid: "def"))
    }

    @Test func aBranchBehindThePRHeadIsWithinIt() {
        let git = FakeWorktreeGit(merged: ["refs/heads/ryanm/x"])
        #expect(WT.isWithinPRHead(git, branch: "ryanm/x", headOid: "def"))
    }

    // MARK: bare branches

    private static let branches = ["main", "ryanm/merged", "ryanm/closed", "ryanm/open", "ryanm/nopr", "ryanm/in-worktree"]

    private func bareCandidates(
        prs: PullRequestMap = prs,
        current: String? = nil,
        locallyMerged: (String) -> Bool = never,
        withinPRHead: (String, String) -> Bool = withinEveryPR
    ) -> [BareBranchCandidate] {
        WT.bareBranchCandidates(
            branches: Self.branches, worktreeBranches: ["ryanm/in-worktree"], prs: prs, currentBranch: current,
            trunkBranches: ["main"], baseBranch: "main", locallyMerged: locallyMerged, withinPRHead: withinPRHead
        )
    }

    private func bare(
        prs: PullRequestMap = prs,
        current: String? = nil,
        locallyMerged: (String) -> Bool = never
    ) -> [String] {
        bareCandidates(prs: prs, current: current, locallyMerged: locallyMerged).map(\.branch)
    }

    @Test func bareMergedAndClosedAreSelected() {
        #expect(bare() == ["ryanm/merged", "ryanm/closed"])
    }

    @Test func aBranchCheckedOutInAWorktreeIsSkipped() {
        var prs = Self.prs
        prs["ryanm/in-worktree"] = Self.pr(7, .merged)
        #expect(!bare(prs: prs).contains("ryanm/in-worktree"))
    }

    @Test func theCurrentBranchIsSkipped() {
        #expect(bare(current: "ryanm/merged") == ["ryanm/closed"])
    }

    @Test func trunkBranchesAreSkipped() {
        var prs = Self.prs
        prs["main"] = Self.pr(9, .merged)
        #expect(!bare(prs: prs).contains("main"))
    }

    @Test func aLocallyMergedBareBranchWithoutAPRQualifies() {
        #expect(bare(locallyMerged: { $0 == "ryanm/nopr" }).contains("ryanm/nopr"))
    }

    @Test func anOpenPRNotMergedLocallyIsSkipped() {
        #expect(!bare().contains("ryanm/open"))
    }

    @Test func aBareBranchWithCommitsItsPRLacksIsKeptWithANote() {
        let kept = bareCandidates(withinPRHead: { branch, _ in branch != "ryanm/closed" })
        #expect(kept.first { $0.branch == "ryanm/closed" }?.skipNote == "has commits the PR doesn't")
        #expect(kept.first { $0.branch == "ryanm/merged" }?.skipNote == nil)
    }

    // MARK: the command

    private func pruneContext(prs: PullRequestMap) -> FakeWTContext {
        let ctx = FakeWTContext(baseBranch: "main")
        ctx.protected = ["repo"]
        ctx.trunkBranches = ["main"]
        ctx.fakeGit.entries = [
            WorktreeEntry(path: "/repo", branch: "main"),
            WorktreeEntry(path: "/repo/.wt/gone", branch: "ryanm/gone"),
            WorktreeEntry(path: "/repo/.wt/ahead", branch: "ryanm/ahead"),
            WorktreeEntry(path: "/repo/.wt/done", branch: "ryanm/done"),
        ]
        ctx.fakeGit.branches = ["main", "ryanm/gone", "ryanm/ahead", "ryanm/done", "ryanm/bare"]
        ctx.fetchSession = PRFetchSession(completion: ScriptedFetchCompletion(true, result: prs), numberPrefix: "#", forgeIcon: "")
        return ctx
    }

    private static let commandPRs: PullRequestMap = [
        "ryanm/gone": pr(1, .merged),
        "ryanm/ahead": pr(2, .merged),
        "ryanm/done": pr(3, .merged),
        "ryanm/bare": pr(4, .closed),
    ]

    /// `head-N` is the head `pr(N, _)` gives each PR.
    private func atPRHead(_ ctx: FakeWTContext, _ branches: [String: Int]) {
        for (branch, number) in branches { ctx.fakeGit.shas["refs/heads/\(branch)"] = "head-\(number)" }
    }

    @Test func pruneKeepsABranchWithCommitsItsPRLacks() throws {
        let ctx = pruneContext(prs: Self.commandPRs)
        atPRHead(ctx, ["ryanm/gone": 1, "ryanm/done": 3, "ryanm/bare": 4])
        try WT.prune(ctx, ["-y"])
        #expect(!ctx.fakeGit.removed.contains("/repo/.wt/ahead"))
        #expect(ctx.fakeGit.branches.contains("ryanm/ahead"))
        #expect(ctx.buffer.stdout.contains("skip ahead"))
        #expect(ctx.buffer.stdout.contains("has commits the PR doesn't"))
        #expect(ctx.fakeGit.removed.contains("/repo/.wt/done"))
    }

    @Test func pruneSkipsAWorktreeWhoseStatusFailsAndCarriesOn() throws {
        let ctx = pruneContext(prs: Self.commandPRs)
        atPRHead(ctx, ["ryanm/gone": 1, "ryanm/ahead": 2, "ryanm/done": 3, "ryanm/bare": 4])
        ctx.fakeGit.unreadablePaths = ["/repo/.wt/gone"]
        try WT.prune(ctx, ["-y"])
        #expect(ctx.fakeGit.removed == ["/repo/.wt/ahead", "/repo/.wt/done"])
        #expect(ctx.fakeGit.branches.contains("ryanm/gone"))
        #expect(!ctx.fakeGit.branches.contains("ryanm/bare"))
        #expect(ctx.buffer.stderr.contains("skip gone: could not read its status"))
    }

    @Test func pruneKeepsABareBranchWithCommitsItsPRLacks() throws {
        let ctx = pruneContext(prs: Self.commandPRs)
        atPRHead(ctx, ["ryanm/gone": 1, "ryanm/ahead": 2, "ryanm/done": 3])
        try WT.prune(ctx, ["-y"])
        #expect(ctx.fakeGit.branches.contains("ryanm/bare"))
        #expect(ctx.buffer.stdout.contains("skip branch ryanm/bare"))
    }

    // MARK: flags

    @Test func pruneRejectsAnUnknownFlag() {
        #expect(cliFailure { try WT.prune(FakeWTContext(), ["--nope"]) }?.message == "unknown flag: --nope")
    }
}
