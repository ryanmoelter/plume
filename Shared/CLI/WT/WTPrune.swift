import Foundation

/// A worktree `wt prune` offers to delete, with its branch.
nonisolated struct PruneCandidate: Equatable, Sendable {
    /// The folder's basename, used to describe and protect it. Deletion goes
    /// by `path`, so a shared name can't remove the wrong worktree.
    var name: String
    var branch: String
    var path: String
    var pr: PullRequest?
    /// `merged`, `closed`, or `merged into <base>`.
    var reason: String
}

/// A local branch with no worktree that `wt prune` offers to delete.
nonisolated struct BareBranchCandidate: Equatable, Sendable {
    var branch: String
    var pr: PullRequest?
    var reason: String
}

nonisolated extension WT {
    /// Whether `baseRef` already contains the branch's commits. Catches only
    /// fast-forward and rebase merges: a squash merge leaves no local trace,
    /// which is why the PR state is consulted first.
    static func isMergedLocally(_ git: any WorktreeGit, branch: String, baseRef: String) -> Bool {
        // TODO(PLUME-316 group D)
        false
    }

    /// The worktrees whose PR is merged or closed, or whose branch is merged
    /// into the base, skipping protected names, the working directory's
    /// worktree and the base branch.
    static func pruneCandidates(
        records: [WorktreeRecord],
        prs: PullRequestMap,
        protected: [String],
        cwdName: String?,
        baseBranch: String,
        locallyMerged: (String) -> Bool
    ) -> [PruneCandidate] {
        // TODO(PLUME-316 group D)
        []
    }

    /// Local branches with no worktree that are safe to delete, skipping
    /// worktree branches, trunk branches and the current branch.
    static func bareBranchCandidates(
        branches: [String],
        worktreeBranches: [String],
        prs: PullRequestMap,
        currentBranch: String?,
        trunkBranches: Set<String>,
        baseBranch: String,
        locallyMerged: (String) -> Bool
    ) -> [BareBranchCandidate] {
        // TODO(PLUME-316 group D)
        []
    }
}
