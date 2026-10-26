import Foundation

/// One worktree git has registered. `branch` is nil for a detached HEAD.
nonisolated struct WorktreeEntry: Equatable, Sendable {
    var path: String
    var branch: String?
}

/// A worktree with a branch checked out, for callers that act on the branch.
nonisolated struct WorktreeRecord: Equatable, Sendable {
    var branch: String
    var path: String
}

/// Parses `git worktree list --porcelain`: blank-line-separated records of
/// `worktree <path>`, `HEAD <sha>`, then `branch refs/heads/<name>` or
/// `detached`.
nonisolated enum WorktreePorcelain {
    /// Every worktree, main first, detached ones included. A record is
    /// flushed when the next `worktree` line starts rather than on its
    /// `branch` line, so a detached worktree, which has none, still yields an
    /// entry and never absorbs the next record's branch.
    static func entries(from text: String) -> [WorktreeEntry] {
        // TODO(PLUME-316 group B)
        []
    }

    /// The entries with a branch, dropping detached HEADs.
    static func records(from entries: [WorktreeEntry]) -> [WorktreeRecord] {
        // TODO(PLUME-316 group B)
        []
    }
}

/// Every git call `wt` makes. `ProcessWorktreeGit` shells out; tests
/// substitute an in-memory fake.
///
/// Methods that would exit in the Python tool on a git failure throw a
/// `CLIFailure` carrying git's exit code. Git's own error output has already
/// reached the terminal, so those failures carry no message.
nonisolated protocol WorktreeGit: AnyObject {
    /// The `git -C` anchor for repository-wide calls, set once the layout is
    /// known: the main worktree, or the `.bare` directory.
    var repoDir: String? { get set }

    // Bootstrap, from the working directory.
    func toplevel() -> String?
    func commonDir(root: String) -> String?

    // Repository-wide.
    func configGet(_ key: String) -> String?
    @discardableResult func configSet(_ key: String, _ value: String) -> Bool
    func originURL() -> String?
    /// `origin/HEAD`'s short name, such as `origin/main`.
    func originHead() -> String?
    func branchExists(_ branch: String) -> Bool
    func refExists(_ ref: String) -> Bool
    func isAncestor(_ ref: String, of other: String) -> Bool
    func localBranches() -> [String]
    func worktreeEntries() -> [WorktreeEntry]
    func fetchBase(_ baseBranch: String, quiet: Bool) throws
    /// With `fatal` off, a failure returns false instead of throwing.
    @discardableResult func worktreeAdd(path: String, branch: String, new: Bool, baseRef: String?, fatal: Bool) throws -> Bool
    func worktreeRemove(path: String, force: Bool) throws
    func branchDelete(_ branch: String, force: Bool) throws
    func branchDeleteOK(_ branch: String, force: Bool) -> Bool
    func worktreeMove(from: String, to: String) throws
    func testUntrackedCache() -> Bool

    // Per worktree.
    func branchOf(_ path: String) throws -> String
    func isClean(_ path: String) throws -> Bool
    func statusV2Lines(_ path: String) -> [String]
    func shortHead(_ path: String) -> String?
    /// Commits ahead of `baseRef`, as a string; empty when unanswerable.
    func aheadCount(_ path: String, baseRef: String) -> String
    func checkoutOK(_ path: String, ref: String, detach: Bool, silent: Bool) -> Bool
    func checkoutFatal(_ path: String, ref: String, detach: Bool, quietStdout: Bool) throws
    func stashPush(_ path: String, message: String) throws
    func stashPopOK(_ path: String, silent: Bool) -> Bool
    func branchMove(_ path: String, from: String, to: String) throws
    /// `git commit -a` with `extraArguments`; its exit status.
    func commitAll(_ path: String, extraArguments: [String]) -> Int32
    func enableUntrackedCache(_ path: String)
}

nonisolated extension WorktreeGit {
    /// `worktreeEntries()` without detached HEADs.
    func worktreeRecords() -> [WorktreeRecord] {
        WorktreePorcelain.records(from: worktreeEntries())
    }
}

/// `WorktreeGit` over the `git` binary. Bootstrap calls run in
/// `workingDirectory`, or the process's own when nil.
nonisolated final class ProcessWorktreeGit: WorktreeGit {
    var repoDir: String?
    let workingDirectory: String?

    init(workingDirectory: String? = nil) {
        self.workingDirectory = workingDirectory
    }

    func toplevel() -> String? {
        // TODO(PLUME-316 group B)
        nil
    }

    func commonDir(root: String) -> String? {
        // TODO(PLUME-316 group B)
        nil
    }

    func configGet(_ key: String) -> String? {
        // TODO(PLUME-316 group B)
        nil
    }

    func configSet(_ key: String, _ value: String) -> Bool {
        // TODO(PLUME-316 group D)
        false
    }

    func originURL() -> String? {
        // TODO(PLUME-316 group B)
        nil
    }

    func originHead() -> String? {
        // TODO(PLUME-316 group B)
        nil
    }

    func branchExists(_ branch: String) -> Bool {
        // TODO(PLUME-316 group B)
        false
    }

    func refExists(_ ref: String) -> Bool {
        // TODO(PLUME-316 group B)
        false
    }

    func isAncestor(_ ref: String, of other: String) -> Bool {
        // TODO(PLUME-316 group D)
        false
    }

    func localBranches() -> [String] {
        // TODO(PLUME-316 group B)
        []
    }

    func worktreeEntries() -> [WorktreeEntry] {
        // TODO(PLUME-316 group B)
        []
    }

    func fetchBase(_ baseBranch: String, quiet: Bool) throws {
        // TODO(PLUME-316 group D)
    }

    func worktreeAdd(path: String, branch: String, new: Bool, baseRef: String?, fatal: Bool) throws -> Bool {
        // TODO(PLUME-316 group D)
        false
    }

    func worktreeRemove(path: String, force: Bool) throws {
        // TODO(PLUME-316 group D)
    }

    func branchDelete(_ branch: String, force: Bool) throws {
        // TODO(PLUME-316 group D)
    }

    func branchDeleteOK(_ branch: String, force: Bool) -> Bool {
        // TODO(PLUME-316 group D)
        false
    }

    func worktreeMove(from: String, to: String) throws {
        // TODO(PLUME-316 group D)
    }

    func testUntrackedCache() -> Bool {
        // TODO(PLUME-316 group D)
        false
    }

    func branchOf(_ path: String) throws -> String {
        // TODO(PLUME-316 group B)
        ""
    }

    func isClean(_ path: String) throws -> Bool {
        // TODO(PLUME-316 group B)
        false
    }

    func statusV2Lines(_ path: String) -> [String] {
        // TODO(PLUME-316 group B)
        []
    }

    func shortHead(_ path: String) -> String? {
        // TODO(PLUME-316 group B)
        nil
    }

    func aheadCount(_ path: String, baseRef: String) -> String {
        // TODO(PLUME-316 group B)
        ""
    }

    func checkoutOK(_ path: String, ref: String, detach: Bool, silent: Bool) -> Bool {
        // TODO(PLUME-316 group D)
        false
    }

    func checkoutFatal(_ path: String, ref: String, detach: Bool, quietStdout: Bool) throws {
        // TODO(PLUME-316 group D)
    }

    func stashPush(_ path: String, message: String) throws {
        // TODO(PLUME-316 group D)
    }

    func stashPopOK(_ path: String, silent: Bool) -> Bool {
        // TODO(PLUME-316 group D)
        false
    }

    func branchMove(_ path: String, from: String, to: String) throws {
        // TODO(PLUME-316 group D)
    }

    func commitAll(_ path: String, extraArguments: [String]) -> Int32 {
        // TODO(PLUME-316 group D)
        1
    }

    func enableUntrackedCache(_ path: String) {
        // TODO(PLUME-316 group D)
    }
}
