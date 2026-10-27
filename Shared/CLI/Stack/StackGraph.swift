import Foundation

/// Pure functions over the branch map. There is no stored stack object: a
/// stack is the tree reachable from a root, a tracked branch whose parent
/// isn't tracked, and `subtree(_:of:)` is both its members and their order.
nonisolated enum StackGraph {
    static func root(_ branches: StackBranches, of branch: String) -> String { branch }

    /// The tree containing `branch`, as its own branch map.
    static func stack(_ branches: StackBranches, of branch: String) -> StackBranches { [:] }

    /// Sorted.
    static func children(_ branches: StackBranches, of branch: String) -> [String] { [] }

    /// Sorted.
    static func roots(_ branches: StackBranches) -> [String] { [] }

    /// Breadth first from each root.
    static func topologicalOrder(_ branches: StackBranches) -> [String] { [] }

    /// 1 for a root.
    static func depths(_ branches: StackBranches) -> [String: Int] { [:] }

    /// `branch` and everything stacked on it, breadth first.
    static func subtree(_ branches: StackBranches, of branch: String) -> [String] { [] }

    /// The chain from `branch`'s root down to `branch`, parents first:
    /// unlike the root's subtree, no siblings and no descendants.
    static func path(_ branches: StackBranches, to branch: String) -> [String] { [] }

    /// A root, whose effective parent is the trunk.
    static func parentIsTrunk(_ branches: StackBranches, _ branch: String) -> Bool { false }

    /// Branches whose GitHub stack membership contradicts the local chain:
    /// in a different stack than the parent, or ordered below it. A chain
    /// only partly registered is normal, not drift.
    static func githubStackDrift(_ branches: StackBranches, _ prs: PullRequestMap) -> [String: String] { [:] }

    /// How to reconcile a GitHub stack with the local chain. Both lists are
    /// PR numbers, bottom first; `existing` is empty with no stack yet.
    static func planStackUpdate(existing: [Int], desired: [Int]) -> StackUpdatePlan { .noop }
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
    func trunkTip() throws -> String { throw CLIFailure("not implemented") }

    /// Fails naming `ref` when it resolves to nothing.
    func rev(_ ref: String) throws -> String { throw CLIFailure("not implemented") }

    func parentTip(_ branches: StackBranches, _ branch: String) throws -> String { throw CLIFailure("not implemented") }

    /// A tracked parent moved or was rewritten, so `branch` no longer sits on
    /// it. Never true for a root: behind the trunk is `behindTrunk`.
    func needsRestack(_ branches: StackBranches, _ branch: String) throws -> Bool { throw CLIFailure("not implemented") }

    /// A root behind the trunk tip. Informational, and never cascades.
    func behindTrunk(_ branches: StackBranches, _ branch: String) throws -> Bool { throw CLIFailure("not implemented") }

    /// `needsRestack`, plus every branch above one that will move.
    func cascadedNeedsRestack(_ branches: StackBranches) throws -> [String: Bool] { throw CLIFailure("not implemented") }

    /// The commits `branch` adds on its parent.
    func commitsOverParent(_ branches: StackBranches, _ branch: String) throws -> Int { throw CLIFailure("not implemented") }

    /// Trunk commits between `base` and the trunk tip.
    func trunkDistance(_ base: String) throws -> Int { throw CLIFailure("not implemented") }

    /// The commit to replay `branch` from: its fork point off `parentTip`.
    func replayFloor(_ branches: StackBranches, _ branch: String, parentTip: String) throws -> String {
        throw CLIFailure("not implemented")
    }
}
