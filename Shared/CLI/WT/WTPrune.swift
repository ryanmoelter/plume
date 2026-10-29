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
    /// Why it is listed but kept, such as commits its PR doesn't have.
    var skipNote: String? = nil
}

/// A local branch with no worktree that `wt prune` offers to delete.
nonisolated struct BareBranchCandidate: Equatable, Sendable {
    var branch: String
    var pr: PullRequest?
    var reason: String
    var skipNote: String? = nil
}

nonisolated extension WT {
    /// Whether `baseRef` already contains the branch's commits. Catches only
    /// fast-forward and rebase merges: a squash merge leaves no local trace,
    /// which is why the PR state is consulted first.
    static func isMergedLocally(_ git: any WorktreeGit, branch: String, baseRef: String) -> Bool {
        git.isAncestor(GitRef.local(branch), of: baseRef)
    }

    /// Whether the PR's head commit holds every commit on `branch`: the
    /// branch's head equals `headOid` or is an ancestor of it. A head git
    /// doesn't have locally counts as not containing it.
    static func isWithinPRHead(_ git: any WorktreeGit, branch: String, headOid: String) -> Bool {
        let ref = GitRef.local(branch)
        return git.revParse(ref) == headOid || git.isAncestor(ref, of: headOid)
    }

    /// Why a branch is prunable, or nil when it isn't. A merged or closed PR
    /// names the reason even when the base also contains the branch. Its
    /// branch is still listed but kept, with a note, when it has commits the
    /// PR doesn't, unless the base already contains them.
    private static func mergeVerdict(
        _ pr: PullRequest?,
        branch: String,
        baseBranch: String,
        locallyMerged: (String) -> Bool,
        withinPRHead: (_ branch: String, _ headOid: String) -> Bool
    ) -> (reason: String, skipNote: String?)? {
        if let pr, pr.state == .merged || pr.state == .closed {
            let reason = pr.state.rawValue.lowercased()
            if let headOid = pr.headRefOid, withinPRHead(branch, headOid) { return (reason, nil) }
            if locallyMerged(branch) { return (reason, nil) }
            return (reason, "has commits the PR doesn't")
        }
        if locallyMerged(branch) { return ("merged into \(baseBranch)", nil) }
        return nil
    }

    /// The worktrees whose PR is merged or closed, or whose branch is merged
    /// into the base, skipping protected names, the working directory's
    /// worktree and every trunk branch.
    static func pruneCandidates(
        records: [WorktreeRecord],
        prs: PullRequestMap,
        protected: [String],
        cwdName: String?,
        trunkBranches: Set<String>,
        baseBranch: String,
        locallyMerged: (String) -> Bool,
        withinPRHead: (_ branch: String, _ headOid: String) -> Bool
    ) -> [PruneCandidate] {
        records.compactMap { record in
            let name = (record.path as NSString).lastPathComponent
            if protected.contains(name) || name == cwdName { return nil }
            if record.branch == baseBranch || trunkBranches.contains(record.branch) { return nil }
            let pr = prs[record.branch]
            guard let verdict = mergeVerdict(
                pr, branch: record.branch, baseBranch: baseBranch, locallyMerged: locallyMerged, withinPRHead: withinPRHead
            ) else { return nil }
            return PruneCandidate(
                name: name, branch: record.branch, path: record.path, pr: pr, reason: verdict.reason, skipNote: verdict.skipNote
            )
        }
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
        locallyMerged: (String) -> Bool,
        withinPRHead: (_ branch: String, _ headOid: String) -> Bool
    ) -> [BareBranchCandidate] {
        // Trunk branches rather than the protected list, which names folders.
        var skip = Set(worktreeBranches).union(trunkBranches)
        if let currentBranch { skip.insert(currentBranch) }
        return branches.compactMap { branch in
            if skip.contains(branch) { return nil }
            let pr = prs[branch]
            guard let verdict = mergeVerdict(
                pr, branch: branch, baseBranch: baseBranch, locallyMerged: locallyMerged, withinPRHead: withinPRHead
            ) else { return nil }
            return BareBranchCandidate(branch: branch, pr: pr, reason: verdict.reason, skipNote: verdict.skipNote)
        }
    }
}
