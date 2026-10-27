import Foundation

/// Submit and sync: the commands that talk to the forge.
nonisolated extension Stack {
    /// Pushes and creates or retargets one PR per branch, bottom first.
    static func submit(_ ctx: StackContext, _ arguments: [String]) throws {
        let known: Set<String> = ["--ready", "--dry-run", "--all"]
        if let leftover = arguments.first(where: { !known.contains($0) }) {
            throw CLIFailure("unknown argument: \(leftover)")
        }
        let ready = arguments.contains("--ready")
        let dryRun = arguments.contains("--dry-run")
        let all = arguments.contains("--all")
        let forge = try ctx.requireForge()
        let allBranches = try ctx.loadAndFlush()
        let current = try requireCurrentTracked(ctx, allBranches)
        let order = all
            ? StackGraph.subtree(allBranches, of: StackGraph.root(allBranches, of: current))
            : StackGraph.path(allBranches, to: current)
        let branches = allBranches.filter { order.contains($0.key) }
        if try ctx.cascadedNeedsRestack(branches).values.contains(true) {
            ctx.warn("stack needs a restack — consider `stack restack` first (submitting anyway)")
        }
        // A push never changes which PRs exist, so the query overlaps the pushes.
        let fetch = startFetch(forge, order)
        var failed = order.filter { !pushBranch(ctx, $0, dryRun: dryRun) }
        let prs = collectPRs(fetch)
        let ref = { (pr: PullRequest) in "\(forge.noun) \(forge.numberPrefix)\(pr.number)" }
        for branch in order {
            guard let parent = branches[branch]?.parent else { continue }
            let pr = prs[branch]
            if let pr, pr.state == .open {
                try retargetPR(ctx, forge, branch: branch, pr: pr, parent: parent, dryRun: dryRun)
                continue
            }
            if let pr, pr.state == .merged {
                ctx.warn("'\(branch)' \(ref(pr)) is already merged — run `stack sync`")
                continue
            }
            // No PR, or an old closed one: create a fresh one.
            let subjects = try ctx.git.git("log", "--reverse", "--format=%s", "\(try ctx.parentTip(branches, branch))..\(branch)")
                .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                .filter { !$0.isEmpty }
            guard let title = subjects.first else {
                ctx.warn("'\(branch)' has no commits on '\(parent)' — skipping \(forge.noun) creation")
                continue
            }
            let kind = ready ? forge.noun : "draft \(forge.noun)"
            if dryRun {
                ctx.console.print("  would create \(kind) for \(branch) (base \(parent)): \(title)")
                continue
            }
            let result = try forge.create(head: branch, base: parent, title: title, body: "", draft: !ready)
            if result.status != 0 {
                ctx.warn("failed to create \(forge.noun) for '\(branch)': \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
                failed.append(branch)
            } else {
                ctx.console.print("  created \(kind) for \(branch): \(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
        if let stacks = forge.nativeStacks, stacks.isEnabled() {
            // GitHub's stacks are linear and ours are trees; --all can hand
            // over a forking subtree.
            if order.contains(where: { StackGraph.children(branches, of: $0).count > 1 }) {
                ctx.console.print("  note: local stack forks — leaving the GitHub stack alone (submit from a single branch to register its chain)")
            } else {
                // PRs created above aren't in the map fetched before them.
                syncGitHubStack(ctx, stacks, order: order, prs: forge.pullRequestsOrEmpty(forBranches: order), dryRun: dryRun)
            }
        }
        if !all { try warnDescendantsNeedRestack(ctx, allBranches, current) }
        if !failed.isEmpty { throw CLIFailure(nil, code: 1) }
    }

    /// Fetches, tracks branches with open PRs, absorbs squash-merged PRs,
    /// restacks, and optionally pushes and retargets.
    static func sync(_ ctx: StackContext, _ arguments: [String]) throws {
        let known: Set<String> = ["--push", "--dry-run", "--all", "--trunk"]
        if let leftover = arguments.first(where: { !known.contains($0) }) {
            throw CLIFailure("unknown argument: \(leftover)")
        }
        let push = arguments.contains("--push")
        let dryRun = arguments.contains("--dry-run")
        let all = arguments.contains("--all")
        let includeTrunk = arguments.contains("--trunk")
        let forge = try ctx.requireForge()
        let noun = forge.noun
        let prefix = forge.numberPrefix
        if !dryRun { try restackPreflight(ctx) }
        let original = ctx.git.currentBranch()
        // Read only to scope the query, which overlaps the fetches below; the
        // load under the lock filters out anything tracked meanwhile.
        let knownBranches = try ctx.loadAndFlush()
        let candidates = ctx.git.localBranches().filter { $0 != ctx.trunk && knownBranches[$0] == nil }
        let untrackedFetch = startFetch(forge, candidates)
        if try ctx.git.run(["fetch", "--prune", "origin"], capture: false).status != 0 {
            throw CLIFailure("fetch failed")
        }
        // Advances the local trunk; fails harmlessly when it is checked out.
        _ = try? ctx.git.run(["fetch", "origin", "\(ctx.trunk):\(ctx.trunk)"])
        var hadErrors = false
        try ctx.state.withLock {
            var branches = try ctx.loadAndFlushLocked()

            // Fresh-clone recovery: track local branches with open PRs.
            let untrackedPRs = collectPRs(untrackedFetch)
            var changed = true
            while changed {
                changed = false
                for branch in candidates where branches[branch] == nil {
                    guard let pr = untrackedPRs[branch], pr.state == .open, let base = pr.baseRefName else { continue }
                    if base == ctx.trunk || branches[base] != nil {
                        ctx.console.print((dryRun ? "would track" : "tracking") + " '\(branch)' (\(noun) \(prefix)\(pr.number), base \(base))")
                        try trackWithParent(ctx, &branches, branch, base, announce: false)
                        changed = true
                    }
                }
            }

            // Absorb squash-merged PRs.
            let trackedPRs = forge.pullRequestsOrEmpty(forBranches: branches.keys.sorted(by: StackJSON.codePointPrecedes))
            var skipped = Set<String>()
            for root in StackGraph.roots(branches) {
                for branch in StackGraph.subtree(branches, of: root) {
                    guard let pr = trackedPRs[branch], pr.state == .merged else { continue }
                    if try ctx.rev(branch) != pr.headRefOid {
                        ctx.warn("'\(branch)' has local commits beyond merged \(noun) \(prefix)\(pr.number) — reconcile manually; skipping its stack")
                        skipped.formUnion(StackGraph.subtree(branches, of: StackGraph.root(branches, of: branch)))
                        hadErrors = true
                        break
                    }
                    guard let parent = branches[branch]?.parent else { continue }
                    ctx.console.print((dryRun ? "would remove" : "removing") + " '\(branch)' (\(noun) \(prefix)\(pr.number) merged) — children move onto '\(parent)'")
                    // The children's bases still name the merged branch's old
                    // tip, so the next restack replays only their own commits.
                    for (name, entry) in branches where entry.parent == branch {
                        branches[name]?.parent = parent
                    }
                    if !dryRun {
                        if ctx.git.currentBranch() == branch {
                            let target = branches[parent] != nil || ctx.git.branchExists(parent) ? parent : ctx.trunk
                            try ctx.git.switchTo(target, quiet: true)
                        }
                        let deletion = try ctx.git.run(["branch", "-D", branch])
                        if deletion.status != 0 {
                            let detail = ctx.git.worktreeMap()[branch].map { " — checked out in \($0)" }
                                ?? ": \(deletion.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
                            ctx.warn("could not delete '\(branch)'\(detail)")
                        }
                    }
                    branches[branch] = nil
                }
            }

            // Rebasing and force-pushing can clobber a child checked out in
            // another worktree, so by default they stay on the current
            // branch's chain. The anchor is wherever absorption left the
            // checkout.
            let scoped: [String]
            var anchor: String?
            if all {
                scoped = StackGraph.roots(branches).flatMap { StackGraph.subtree(branches, of: $0) }
            } else {
                anchor = ctx.git.currentBranch()
                scoped = anchor.flatMap { branches[$0] != nil ? StackGraph.path(branches, to: $0) : nil } ?? []
                if scoped.isEmpty {
                    ctx.warn("current branch is not in a stack — nothing scoped to restack (use --all to sync every stack)")
                }
            }
            let scopedSet = Set(scoped)

            var adopted = Set<String>()
            for root in StackGraph.roots(branches) {
                let subtree = StackGraph.subtree(branches, of: root)
                if !skipped.isDisjoint(with: subtree) { continue }
                let members = subtree.filter(scopedSet.contains)
                for result in try restackStack(ctx, &branches, members, dryRun: dryRun, includeTrunk: includeTrunk, adopted: &adopted) {
                    ctx.console.print("  \(result.branch): \(result.action)")
                }
            }
            if !dryRun { try ctx.saveState(branches) }
            if !all, let anchor, branches[anchor] != nil {
                try warnDescendantsNeedRestack(ctx, branches, anchor)
            }
            guard push else { return }
            let pushable = StackGraph.roots(branches)
                .flatMap { StackGraph.subtree(branches, of: $0) }
                .filter { scopedSet.contains($0) && !skipped.contains($0) }
            // Re-read: the maps above predate absorption, and GitHub retargets
            // a stacked child itself the moment its parent merges, so the old
            // map would aim a base back at a deleted branch.
            let freshPRs = pushable.isEmpty ? [:] : forge.pullRequestsOrEmpty(forBranches: pushable)
            for branch in pushable {
                let tip = try ctx.rev(branch)
                if adopted.contains(branch) || originTip(ctx, branch) == tip {
                    ctx.console.print("  \(branch): up to date on origin — not pushing")
                } else if !pushBranch(ctx, branch, dryRun: dryRun) {
                    hadErrors = true
                    continue
                }
                if let pr = freshPRs[branch], pr.state == .open, let parent = branches[branch]?.parent {
                    try retargetPR(ctx, forge, branch: branch, pr: pr, parent: parent, dryRun: dryRun)
                }
            }
        }
        if !dryRun, let original, ctx.git.branchExists(original), ctx.git.currentBranch() != original {
            try ctx.git.switchTo(original, quiet: true)
        }
        if hadErrors { throw CLIFailure(nil, code: 1) }
    }

    /// `--force-with-lease`, so a push never clobbers commits only the
    /// remote has. Returns whether it succeeded.
    static func pushBranch(_ ctx: StackContext, _ branch: String, dryRun: Bool) -> Bool {
        if dryRun {
            ctx.console.print("  would push \(branch)")
            return true
        }
        let result: CLIProcessResult
        do {
            result = try ctx.git.run(["push", "--force-with-lease", "origin", branch])
        } catch {
            ctx.warn("push failed for '\(branch)': \(error)")
            return false
        }
        if result.status != 0 {
            ctx.warn("push failed for '\(branch)': \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            return false
        }
        ctx.console.print("  pushed \(branch)")
        return true
    }

    static func retargetPR(_ ctx: StackContext, _ forge: any StackForge, branch: String, pr: PullRequest, parent: String, dryRun: Bool) throws {
        let ref = "\(forge.noun) \(forge.numberPrefix)\(pr.number)"
        if pr.baseRefName == parent { return }
        if dryRun {
            ctx.console.print("  would retarget \(ref) (\(branch)) base → \(parent)")
            return
        }
        let result = try forge.editBase(number: pr.number, base: parent)
        if result.status != 0 {
            ctx.warn("failed to retarget \(ref): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        } else {
            ctx.console.print("  retargeted \(ref) (\(branch)) base → \(parent)")
        }
    }

    /// Registers or extends the GitHub native stack for a submitted linear
    /// chain. Best-effort: the PRs are already right, so a failure only
    /// warns.
    static func syncGitHubStack(_ ctx: StackContext, _ stacks: any GitHubNativeStacks, order: [String], prs: PullRequestMap, dryRun: Bool) {
        let numbers = order.compactMap { prs[$0]?.number }
        guard numbers.count >= 2 else { return }
        // The bottom PR is the one already registered when the chain has
        // grown a new tip.
        let existingStack = stacks.stack(containing: numbers[0])
        let existing = existingStack?.pullRequestNumbers ?? []
        let stackLabel = "#\(existingStack?.number.map(String.init) ?? "")"
        if existingStack != nil, existing.isEmpty {
            ctx.warn("GitHub stack \(stackLabel) returned no members — leaving it alone")
            return
        }
        let ok: Bool
        let message: String
        switch StackGraph.planStackUpdate(existing: existing, desired: numbers) {
        case .noop:
            return
        case .drift(let reason):
            ctx.warn("GitHub stack \(stackLabel) doesn't match this chain (\(reason)) — leaving it alone; adjust it in the PR UI")
            return
        case .create(let payload):
            if dryRun {
                ctx.console.print("  would register GitHub stack for \(payload.count) PRs")
                return
            }
            let created = stacks.create(payload)
            ok = created.ok
            message = "registered GitHub stack \(created.number.map { "#\($0)" } ?? "")"
                .trimmingCharacters(in: .whitespaces)
        case .add(let payload):
            if dryRun {
                ctx.console.print("  would add \(payload.count) PR(s) to GitHub stack \(stackLabel)")
                return
            }
            ok = existingStack?.number.map { stacks.add(payload, to: $0) } ?? false
            message = "added \(payload.count) PR(s) to GitHub stack \(stackLabel)"
        }
        if ok {
            ctx.console.print("  \(message)")
        } else {
            ctx.warn("could not update the GitHub stack (PRs are unaffected)")
            stacks.markUnavailable()
        }
    }
}
