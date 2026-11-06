import Foundation

/// Which two states of a repository a review compares.
nonisolated enum DiffRange: Hashable, Sendable {
    /// Everything on disk — committed, staged, unstaged and untracked — against
    /// the merge base of `HEAD` with `baseRef`.
    case workingTree(baseRef: String)
    case commits(base: String, head: String)
    /// One commit against its first parent.
    case commit(String)
}

/// A `DiffRange` resolved against one repository, ready to hand to `git diff`.
nonisolated struct ResolvedDiffRange: Hashable, Sendable {
    let repositoryRoot: String
    /// Revisions passed to `git diff` before `--`: one for a working-tree
    /// diff, two otherwise.
    let revisions: [String]
    let includesUntracked: Bool
    /// The commit the old side reads from, for display.
    let baseCommit: String
}
