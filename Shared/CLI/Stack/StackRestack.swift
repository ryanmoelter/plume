import Foundation

/// Restack: replaying each branch onto its parent, parents first.
nonisolated extension Stack {
    static func restack(_ ctx: StackContext, _ arguments: [String]) throws {
        let known: Set<String> = ["--dry-run", "--trunk", "--all", "-i", "--interactive"]
        if let leftover = arguments.first(where: { !known.contains($0) }) {
            throw CLIFailure("unknown argument: \(leftover)")
        }
        let dryRun = arguments.contains("--dry-run")
        let includeTrunk = arguments.contains("--trunk")
        let all = arguments.contains("--all")
        let interactive = arguments.contains("-i") || arguments.contains("--interactive")
        if interactive, all || includeTrunk || dryRun {
            throw CLIFailure("-i rebases only the current branch — incompatible with --all/--trunk/--dry-run")
        }
        if !dryRun { try restackPreflight(ctx) }
        var branches: StackBranches = [:]
        var current = ""
        var results: [(branch: String, action: String)] = []
        let starting = ctx.git.currentBranch()
        do {
            try ctx.state.withLock {
                branches = try ctx.loadAndFlushLocked()
                current = try requireCurrentTracked(ctx, branches)
                if interactive {
                    try interactiveRestack(ctx, &branches, current)
                    return
                }
                let members = all
                    ? StackGraph.subtree(branches, of: StackGraph.root(branches, of: current))
                    : StackGraph.path(branches, to: current)
                var adopted = Set<String>()
                results = try restackStack(ctx, &branches, members, dryRun: dryRun, includeTrunk: includeTrunk, adopted: &adopted)
                if !dryRun { try ctx.saveState(branches) }
            }
        } catch {
            returnToStartingBranch(ctx, starting, after: error, dryRun: dryRun)
            throw error
        }
        if interactive {
            try warnDescendantsNeedRestack(ctx, branches, current)
            return
        }
        if !dryRun, ctx.git.currentBranch() != current { try ctx.git.switchTo(current, quiet: true) }
        for result in results { ctx.console.print("  \(result.branch): \(result.action)") }
        if !all { try warnDescendantsNeedRestack(ctx, branches, current) }
    }

    static func requireCurrentTracked(_ ctx: StackContext, _ branches: StackBranches) throws -> String {
        guard let current = ctx.git.currentBranch() else { throw CLIFailure("detached HEAD — check out a branch first") }
        if branches[current] == nil {
            if current == ctx.trunk {
                throw CLIFailure("on trunk '\(current)' — `stack co <branch>` or `stack create <name>` to start a stack")
            }
            throw CLIFailure("'\(current)' is not in a stack — run `stack track` first (`stack list --all` shows stacks)")
        }
        return current
    }

    static func rebaseInProgress(_ ctx: StackContext) throws -> Bool {
        try ["rebase-merge", "rebase-apply"].contains { name in
            FileManager.default.fileExists(atPath: try ctx.git.git("rev-parse", "--path-format=absolute", "--git-path", name))
        }
    }

    /// A conflict leaves the rebase in place for the user to resolve; any
    /// other error puts the checkout back where the command started.
    static func returnToStartingBranch(_ ctx: StackContext, _ starting: String?, after error: Error, dryRun: Bool) {
        if let failure = error as? CLIFailure, failure.code == conflictExitCode { return }
        if !dryRun, let starting, ctx.git.currentBranch() != starting {
            try? ctx.git.switchTo(starting, quiet: true)
        }
    }

    static func restackPreflight(_ ctx: StackContext) throws {
        if ctx.git.currentBranch() == nil { throw CLIFailure("detached HEAD — check out a branch first") }
        if try rebaseInProgress(ctx) {
            throw CLIFailure("a rebase is in progress — `git rebase --continue` or `git rebase --abort` first")
        }
        if !(try ctx.git.git("status", "--porcelain", "--untracked-files=no")).isEmpty {
            throw CLIFailure("working tree not clean — commit or stash first")
        }
    }

    /// `origin/<branch>` as of the last fetch, or nil. Local only.
    static func originTip(_ ctx: StackContext, _ branch: String) -> String? {
        ctx.git.resolve(GitRef.origin(branch))
    }

    /// Every sha `origin/<branch>` has pointed at here; push and fetch both
    /// log it.
    static func formerOriginTips(_ ctx: StackContext, _ branch: String) -> Set<String> {
        guard let result = try? ctx.git.run(["reflog", "show", "--format=%H", GitRef.origin(branch)]),
              result.status == 0
        else { return [] }
        return Set(result.stdout.split(whereSeparator: \.isWhitespace).map(String.init))
    }

    /// When `origin/<branch>` already holds `branch` replayed onto
    /// `parentTip`, as a forge that restacks server-side leaves it, the
    /// remote head to rebase onto and the floor to replay from, so only the
    /// local commits the remote lacks move. Nil when the remote holds no
    /// equivalent restack.
    ///
    /// Equivalence is by tree: the branch's own commits are replayed onto
    /// `parentTip` with `merge-tree`, touching no ref or worktree, and the
    /// last step whose tree matches a commit on the remote's first-parent
    /// line marks how much of the branch the remote has. Remote commits past
    /// that point (a bot's) mean local is behind, not diverged, so they stay.
    /// Local commits past it replay only when that point was the pushed head.
    static func remoteRestack(_ ctx: StackContext, _ branch: String, parentTip: String, floor: String) throws -> (onto: String, floor: String)? {
        guard let remoteTip = originTip(ctx, branch),
              remoteTip != (try ctx.rev(branch)),
              ctx.git.isAncestor(parentTip, remoteTip)
        else { return nil }
        let remoteTrees = Set(try ctx.git.git("log", "--first-parent", "--format=%T", "\(parentTip)..\(remoteTip)")
            .split(whereSeparator: \.isWhitespace).map(String.init))
        var replayed = parentTip
        var keep: String?
        let commits = try ctx.git.git("rev-list", "--reverse", "--no-merges", "\(floor)..\(GitRef.local(branch))")
            .split(whereSeparator: \.isWhitespace).map(String.init)
        for commit in commits {
            let merge = try ctx.git.run(["merge-tree", "--write-tree", "--merge-base=\(commit)^", replayed, commit])
            // A conflict here stops the real rebase too.
            guard merge.status == 0, let tree = merge.stdout.split(whereSeparator: \.isWhitespace).first.map(String.init) else { break }
            if remoteTrees.contains(tree) { keep = commit }
            let created = try ctx.git.run(["commit-tree", "--no-gpg-sign", tree, "-p", replayed, "-m", "stack dry replay"])
            guard created.status == 0 else { break }
            replayed = created.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let keep else { return nil }
        // Unmatched local commits may be unpushed or rewritten by the remote;
        // only a record of `keep` as the pushed head says which.
        if keep != (try ctx.rev(branch)), !formerOriginTips(ctx, branch).contains(keep) { return nil }
        return (remoteTip, keep)
    }

    /// `git rebase --onto onto floor branch`, run inside `worktree` when the
    /// branch is checked out there, since it can't be checked out here too.
    static func rebaseBranch(_ ctx: StackContext, _ branch: String, onto: String, floor: String, worktree: String?) throws -> Int32 {
        var arguments = worktree.map { ["-C", $0] } ?? []
        arguments += ["-c", "rebase.updateRefs=false", "rebase", "--onto", onto, floor]
        if worktree == nil { arguments.append(branch) }
        return try ctx.git.run(arguments, capture: false).status
    }

    /// Rebases each of `members`, parents first, onto its parent, saving the
    /// state as it goes. Stops with the conflict exit code on a conflict.
    ///
    /// A root moves onto the latest trunk only with `includeTrunk`, or when
    /// its base has fallen off the trunk and can't be replayed onto it. A
    /// branch whose remote head already holds its replay is adopted, so a
    /// push afterward is a no-op; branches left exactly at `origin/<branch>`
    /// join `adopted`.
    static func restackStack(
        _ ctx: StackContext,
        _ branches: inout StackBranches,
        _ members: [String],
        dryRun: Bool,
        includeTrunk: Bool = false,
        adopted: inout Set<String>
    ) throws -> [(branch: String, action: String)] {
        let worktrees = ctx.git.worktreeMap()
        let currentWorktree = try ctx.git.git("rev-parse", "--show-toplevel")
        // In a dry run a rebased branch's new tip is unknown, and an adopted
        // one's is its remote head.
        var moved = Set<String>()
        var predicted: [String: String] = [:]
        var results: [(branch: String, action: String)] = []
        for branch in members {
            guard let entry = branches[branch] else { continue }
            let parent = entry.parent
            let parentTip = try predicted[parent] ?? ctx.parentTip(branches, branch)
            var note = ""
            if StackGraph.parentIsTrunk(branches, branch) {
                let mustMove = !ctx.git.isAncestor(entry.base, try ctx.trunkTip())
                if !(includeTrunk || mustMove) {
                    // Healing the base to the trunk tip here would claim the
                    // root is up to date when it isn't.
                    results.append((branch, "already stacked"))
                    continue
                }
                if mustMove, !includeTrunk { note = " (base no longer on \(ctx.trunk))" }
            }
            if ctx.git.isAncestor(parentTip, try ctx.rev(branch)), !(dryRun && moved.contains(parent)) {
                if entry.base != parentTip {
                    // Heals the bookkeeping after, say, a manual rebase with
                    // rebase.updateRefs on.
                    branches[branch]?.base = parentTip
                    if !dryRun { try ctx.saveState(branches) }
                }
                results.append((branch, "already stacked"))
                continue
            }
            if dryRun, moved.contains(parent) {
                results.append((branch, "would rebase onto \(parent)\(note)"))
                moved.insert(branch)
                continue
            }
            let floor = try ctx.replayFloor(branches, branch, parentTip: parentTip)
            let adopt = try remoteRestack(ctx, branch, parentTip: parentTip, floor: floor)
            if dryRun {
                if let adopt {
                    if adopt.floor == (try ctx.rev(branch)) {
                        results.append((branch, "would adopt origin/\(branch) (already restacked on the remote)"))
                        predicted[branch] = adopt.onto
                        adopted.insert(branch)
                    } else {
                        let count = try ctx.git.revListCount("\(adopt.floor)..\(GitRef.local(branch))")
                        results.append((branch, "would adopt origin/\(branch) (already restacked on the remote) and replay \(count) local commit(s)"))
                        moved.insert(branch)
                    }
                } else {
                    results.append((branch, "would rebase onto \(parent)\(note)"))
                    moved.insert(branch)
                }
                continue
            }
            var worktree = worktrees[branch]
            if worktree == currentWorktree { worktree = nil }
            if let worktree, !(try ctx.git.git("-C", worktree, "status", "--porcelain", "--untracked-files=no")).isEmpty {
                throw CLIFailure("'\(branch)' is checked out in \(worktree) with uncommitted changes — commit or stash there, then re-run")
            }
            let (onto, start) = adopt ?? (parentTip, floor)
            if try rebaseBranch(ctx, branch, onto: onto, floor: start, worktree: worktree) != 0 {
                let location = worktree.map { " in \($0)" } ?? ""
                ctx.warn("""
                    rebase of '\(branch)' onto '\(parent)' stopped on conflicts.
                      resolve them\(location), then `git rebase --continue` (or `git rebase --abort`),
                      then re-run `stack restack` — it resumes where it stopped.
                    """)
                throw CLIFailure(nil, code: conflictExitCode)
            }
            branches[branch]?.base = parentTip
            try ctx.saveState(branches)
            if adopt != nil {
                let count = try ctx.git.revListCount("\(onto)..\(GitRef.local(branch))")
                if count == 0 { adopted.insert(branch) }
                let replayed = count > 0 ? ", replayed \(count) local commit(s)" : ""
                results.append((branch, "adopted origin/\(branch) (already restacked on the remote)\(replayed)"))
            } else {
                results.append((branch, "rebased onto \(parent)\(note)"))
            }
        }
        return results
    }

    /// `git rebase -i` over the current branch's own commits, then heals its
    /// base so the branches above restack cleanly onto the new tip. An edit
    /// or break stop exits 0 with the rebase still open and a conflict exits
    /// non-zero, so whether a rebase is still in progress decides.
    private static func interactiveRestack(_ ctx: StackContext, _ branches: inout StackBranches, _ current: String) throws {
        let parentTip = try ctx.parentTip(branches, current)
        let parent = branches[current]?.parent ?? ctx.trunk
        if try ctx.git.revListCount("\(parentTip)..\(GitRef.local(current))") == 0 {
            throw CLIFailure("'\(current)' has no commits on '\(parent)' — nothing to rebase")
        }
        // Stored bases move the branches above; git must not drag them along.
        try ctx.git.run(["-c", "rebase.updateRefs=false", "rebase", "-i", parentTip], capture: false)
        if try rebaseInProgress(ctx) {
            ctx.warn("""
                interactive rebase of '\(current)' is still in progress (a conflict, or an edit/break stop).
                  finish it with `git rebase --continue` (or `git rebase --abort`), then
                  `stack restack` to heal the base and flag branches above it.
                """)
            throw CLIFailure(nil, code: conflictExitCode)
        }
        branches[current]?.base = parentTip
        try ctx.saveState(branches)
        ctx.console.print("  \(current): interactively rebased onto \(parent)")
    }

    /// Names the branches above `current` that a scoped command skipped and
    /// that need, or will need, their own restack.
    static func warnDescendantsNeedRestack(_ ctx: StackContext, _ branches: StackBranches, _ current: String) throws {
        let needsRestack = try ctx.cascadedNeedsRestack(branches)
        let stale = StackGraph.subtree(branches, of: current).filter { $0 != current && needsRestack[$0] == true }
        if !stale.isEmpty {
            ctx.warn("branches above '\(current)' may need their own restack: \(stale.joined(separator: ", ")) (run from there or use --all)")
        }
    }
}
