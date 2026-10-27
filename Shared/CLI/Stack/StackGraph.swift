import Foundation

/// Pure functions over the branch map. There is no stored stack object: a
/// stack is the tree reachable from a root, a tracked branch whose parent
/// isn't tracked, and `subtree(_:of:)` is both its members and their order.
nonisolated enum StackGraph {
    static func root(_ branches: StackBranches, of branch: String) -> String {
        var branch = branch
        var seen: Set<String> = [branch]
        while let parent = branches[branch]?.parent, branches[parent] != nil, seen.insert(parent).inserted {
            branch = parent
        }
        return branch
    }

    /// The tree containing `branch`, as its own branch map.
    static func stack(_ branches: StackBranches, of branch: String) -> StackBranches {
        var members: StackBranches = [:]
        for name in subtree(branches, of: root(branches, of: branch)) {
            members[name] = branches[name]
        }
        return members
    }

    /// Sorted.
    static func children(_ branches: StackBranches, of branch: String) -> [String] {
        branches.filter { $0.value.parent == branch }.map(\.key).sorted(by: StackJSON.codePointPrecedes)
    }

    /// Sorted.
    static func roots(_ branches: StackBranches) -> [String] {
        branches.filter { branches[$0.value.parent] == nil }.map(\.key).sorted(by: StackJSON.codePointPrecedes)
    }

    /// Breadth first from each root.
    static func topologicalOrder(_ branches: StackBranches) -> [String] {
        breadthFirst(branches, from: roots(branches))
    }

    /// 1 for a root.
    static func depths(_ branches: StackBranches) -> [String: Int] {
        var depths: [String: Int] = [:]
        for branch in topologicalOrder(branches) {
            depths[branch] = (branches[branch].flatMap { depths[$0.parent] } ?? 0) + 1
        }
        return depths
    }

    /// `branch` and everything stacked on it, breadth first.
    static func subtree(_ branches: StackBranches, of branch: String) -> [String] {
        breadthFirst(branches, from: [branch])
    }

    /// The chain from `branch`'s root down to `branch`, parents first:
    /// unlike the root's subtree, no siblings and no descendants.
    static func path(_ branches: StackBranches, to branch: String) -> [String] {
        var chain = [branch]
        var current = branch
        while let parent = branches[current]?.parent, branches[parent] != nil, !chain.contains(parent) {
            chain.append(parent)
            current = parent
        }
        return chain.reversed()
    }

    /// A root, whose effective parent is the trunk.
    static func parentIsTrunk(_ branches: StackBranches, _ branch: String) -> Bool {
        guard let parent = branches[branch]?.parent else { return true }
        return branches[parent] == nil
    }

    /// Branches whose GitHub stack membership contradicts the local chain:
    /// in a different stack than the parent, or ordered below it. A chain
    /// only partly registered is normal, not drift.
    static func githubStackDrift(_ branches: StackBranches, _ prs: PullRequestMap) -> [String: String] {
        var drift: [String: String] = [:]
        for (branch, entry) in branches {
            guard branches[entry.parent] != nil,
                  let own = prs[branch]?.githubStack,
                  let parent = prs[entry.parent]?.githubStack
            else { continue }
            if own.number != parent.number {
                drift[branch] = "in stack #\(own.number), parent in #\(parent.number)"
            } else if own.position <= parent.position {
                drift[branch] = "ordered below its parent in stack #\(own.number)"
            }
        }
        return drift
    }

    /// How to reconcile a GitHub stack with the local chain. Both lists are
    /// PR numbers, bottom first; `existing` is empty with no stack yet.
    static func planStackUpdate(existing: [Int], desired: [Int]) -> StackUpdatePlan {
        if existing.isEmpty { return desired.count >= 2 ? .create(desired) : .noop }
        if desired == existing { return .noop }
        if desired.count > existing.count, Array(desired.prefix(existing.count)) == existing {
            return .add(Array(desired.dropFirst(existing.count)))
        }
        return .drift("GitHub has \(existing), local chain is \(desired)")
    }

    private static func breadthFirst(_ branches: StackBranches, from start: [String]) -> [String] {
        var order: [String] = []
        var seen = Set<String>()
        var queue = start[...]
        while let branch = queue.popFirst() {
            guard seen.insert(branch).inserted else { continue }
            order.append(branch)
            queue.append(contentsOf: children(branches, of: branch))
        }
        return order
    }
}

nonisolated enum StackUpdatePlan: Equatable, Sendable {
    /// Already right, or too small to be a stack.
    case noop
    /// Register the whole chain.
    case create([Int])
    /// Append these to the top.
    case add([Int])
    /// The shapes disagree; never resolved automatically.
    case drift(String)
}

/// The predicates that need git, against the context's trunk.
nonisolated extension StackContext {
    /// The trunk tip: `origin/<trunk>`, else the local branch.
    func trunkTip() throws -> String {
        for ref in [StackRef.origin(trunk), StackRef.local(trunk)] {
            if let sha = git.resolve(ref) { return sha }
        }
        throw CLIFailure("cannot resolve trunk '\(trunk)' — no origin/\(trunk) or local branch")
    }

    /// The tip of local branch `branch`; fails when there is none.
    func rev(_ branch: String) throws -> String {
        guard let sha = git.resolve(StackRef.local(branch)) else { throw CLIFailure("unknown ref: \(branch)") }
        return sha
    }

    func parentTip(_ branches: StackBranches, _ branch: String) throws -> String {
        guard let parent = branches[branch]?.parent else { return try trunkTip() }
        if branches[parent] != nil { return try rev(parent) }
        if parent == trunk || !git.branchExists(parent) { return try trunkTip() }
        return try rev(parent)
    }

    /// A tracked parent moved or was rewritten, so `branch` no longer sits on
    /// it. Never true for a root: behind the trunk is `behindTrunk`.
    func needsRestack(_ branches: StackBranches, _ branch: String) throws -> Bool {
        if StackGraph.parentIsTrunk(branches, branch) { return false }
        return !git.isAncestor(try parentTip(branches, branch), try rev(branch))
    }

    /// A root behind the trunk tip. Informational, and never cascades.
    func behindTrunk(_ branches: StackBranches, _ branch: String) throws -> Bool {
        guard StackGraph.parentIsTrunk(branches, branch) else { return false }
        return !git.isAncestor(try trunkTip(), try rev(branch))
    }

    /// `needsRestack`, plus every branch above one that will move.
    func cascadedNeedsRestack(_ branches: StackBranches) throws -> [String: Bool] {
        var result: [String: Bool] = [:]
        for branch in StackGraph.topologicalOrder(branches) {
            let parentMoves = branches[branch].flatMap { result[$0.parent] } ?? false
            result[branch] = try needsRestack(branches, branch) || parentMoves
        }
        return result
    }

    /// The commits `branch` adds on its parent.
    func commitsOverParent(_ branches: StackBranches, _ branch: String) throws -> Int {
        try git.revListCount("\(try parentTip(branches, branch))..\(StackRef.local(branch))")
    }

    /// Trunk commits between `base` and the trunk tip.
    func trunkDistance(_ base: String) throws -> Int {
        try git.revListCount("\(base)..\(try trunkTip())")
    }

    /// The commit to replay `branch` from: its fork point off `parentTip`.
    ///
    /// The stored base stops being the fork point when it is unreachable
    /// from the branch (squashed or rewritten), leaving only the merge-base,
    /// or when the branch merged its parent in instead of rebasing, which
    /// moves the fork point up while the stored base stays behind. A
    /// squash-merged parent is neither: its old tip is reachable from the
    /// child and not contained in the squashed trunk, so the stored base
    /// stands, and that is what keeps the parent's commits out of the replay.
    func replayFloor(_ branches: StackBranches, _ branch: String, parentTip: String) throws -> String {
        let tip = try rev(branch)
        guard let base = branches[branch]?.base else { throw CLIFailure("'\(branch)' is not in a stack") }
        if !git.isAncestor(base, tip) {
            guard let mergeBase = git.mergeBase(parentTip, tip) else {
                throw CLIFailure("'\(branch)' shares no history with its parent")
            }
            warn("stored base for '\(branch)' is stale — using merge-base \(mergeBase.prefix(12))")
            return mergeBase
        }
        if !git.isAncestor(base, parentTip) { return base }
        // Only ever raise the floor, never below the stored base.
        if let mergeBase = git.mergeBase(parentTip, tip), mergeBase != base, git.isAncestor(base, mergeBase) {
            return mergeBase
        }
        return base
    }
}
