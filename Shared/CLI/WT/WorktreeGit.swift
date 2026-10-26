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
        var entries: [WorktreeEntry] = []
        var current: WorktreeEntry?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") {
                if let current { entries.append(current) }
                current = WorktreeEntry(path: String(line.dropFirst("worktree ".count)), branch: nil)
            } else if line.hasPrefix("branch refs/heads/") {
                current?.branch = String(line.dropFirst("branch refs/heads/".count))
            }
        }
        if let current { entries.append(current) }
        return entries
    }

    /// The entries with a branch, dropping detached HEADs.
    static func records(from entries: [WorktreeEntry]) -> [WorktreeRecord] {
        entries.compactMap { entry in entry.branch.map { WorktreeRecord(branch: $0, path: entry.path) } }
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

    // MARK: Runners

    private func capture(_ arguments: [String]) -> CLIProcessResult? {
        try? CLIProcess.run(arguments, check: false, workingDirectory: workingDirectory)
    }

    /// Stdout without its trailing newlines, or nil on a non-zero exit.
    private func outputOrNil(_ arguments: [String]) -> String? {
        guard let result = capture(arguments), result.status == 0 else { return nil }
        var output = Substring(result.stdout)
        while output.last == "\n" { output = output.dropLast() }
        return String(output)
    }

    /// Output suppressed, success only.
    private func silentOK(_ arguments: [String]) -> Bool {
        capture(arguments)?.status == 0
    }

    private func lines(_ output: String?) -> [String] {
        guard let output, !output.isEmpty else { return [] }
        return output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// Anchored to `repoDir` once the layout is known, else the working
    /// directory.
    private func repoGit(_ arguments: String...) -> [String] {
        repoDir.map { ["git", "-C", $0] + arguments } ?? ["git"] + arguments
    }

    private func worktreeGit(_ path: String, _ arguments: String...) -> [String] {
        ["git", "-C", path] + arguments
    }

    /// Stdout trimmed, or a silent failure carrying git's exit code.
    private func outputOrExit(_ arguments: [String]) throws -> String {
        guard let result = capture(arguments) else { throw CLIFailure(nil) }
        guard result.status == 0 else { throw CLIFailure(nil, code: result.status) }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Bootstrap

    func toplevel() -> String? {
        outputOrNil(["git", "rev-parse", "--show-toplevel"])
    }

    func commonDir(root: String) -> String? {
        outputOrNil(worktreeGit(root, "rev-parse", "--git-common-dir"))
    }

    // MARK: Repository-wide

    func configGet(_ key: String) -> String? {
        outputOrNil(repoGit("config", "--get", key))
    }

    func configSet(_ key: String, _ value: String) -> Bool {
        // TODO(PLUME-316 group D)
        false
    }

    func originURL() -> String? {
        outputOrNil(repoGit("remote", "get-url", "origin"))
    }

    func originHead() -> String? {
        outputOrNil(repoGit("symbolic-ref", "--short", "refs/remotes/origin/HEAD"))
    }

    func branchExists(_ branch: String) -> Bool {
        silentOK(repoGit("show-ref", "--verify", "refs/heads/\(branch)"))
    }

    func refExists(_ ref: String) -> Bool {
        silentOK(repoGit("rev-parse", "--verify", "--quiet", ref))
    }

    func isAncestor(_ ref: String, of other: String) -> Bool {
        // TODO(PLUME-316 group D)
        false
    }

    func localBranches() -> [String] {
        lines(outputOrNil(repoGit("for-each-ref", "--format=%(refname:short)", "refs/heads")))
    }

    func worktreeEntries() -> [WorktreeEntry] {
        WorktreePorcelain.entries(from: outputOrNil(repoGit("worktree", "list", "--porcelain")) ?? "")
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

    // MARK: Per worktree

    func branchOf(_ path: String) throws -> String {
        try outputOrExit(worktreeGit(path, "rev-parse", "--abbrev-ref", "HEAD"))
    }

    func isClean(_ path: String) throws -> Bool {
        try outputOrExit(worktreeGit(path, "status", "--porcelain")).isEmpty
    }

    func statusV2Lines(_ path: String) -> [String] {
        lines(outputOrNil(worktreeGit(path, "status", "-b", "--porcelain=v2")))
    }

    func shortHead(_ path: String) -> String? {
        outputOrNil(worktreeGit(path, "rev-parse", "--short", "HEAD"))
    }

    func aheadCount(_ path: String, baseRef: String) -> String {
        outputOrNil(worktreeGit(path, "rev-list", "--count", "\(baseRef)..HEAD")) ?? ""
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
