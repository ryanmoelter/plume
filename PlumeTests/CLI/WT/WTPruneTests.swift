import Foundation
import Testing
@testable import Plume

/// `wt prune`'s selection rules. Worktrees and bare branches both qualify
/// when their PR is merged or closed, or when the branch is already merged
/// into the base; both skip protected, current and trunk entries. Ported
/// from `test_wt_prune.py`.
struct WTPruneTests {
    private static func pr(_ number: Int, _ state: PullRequestState) -> PullRequest {
        PullRequest(number: number, state: state, isDraft: false)
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
        locallyMerged: (String) -> Bool = never
    ) -> [PruneCandidate] {
        WT.pruneCandidates(records: records, prs: prs, protected: protected, cwdName: cwd, baseBranch: "main", locallyMerged: locallyMerged)
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

    // MARK: bare branches

    private static let branches = ["main", "ryanm/merged", "ryanm/closed", "ryanm/open", "ryanm/nopr", "ryanm/in-worktree"]

    private func bare(
        prs: PullRequestMap = prs,
        current: String? = nil,
        locallyMerged: (String) -> Bool = never
    ) -> [String] {
        WT.bareBranchCandidates(
            branches: Self.branches, worktreeBranches: ["ryanm/in-worktree"], prs: prs, currentBranch: current,
            trunkBranches: ["main"], baseBranch: "main", locallyMerged: locallyMerged
        ).map(\.branch)
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

    // MARK: flags

    @Test func pruneRejectsAnUnknownFlag() {
        #expect(cliFailure { try WT.prune(FakeWTContext(), ["--nope"]) }?.message == "unknown flag: --nope")
    }
}
