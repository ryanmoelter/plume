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
/// A throwing method's git failure ends the command: it throws a `CLIFailure`
/// carrying git's exit code. Git's own error output has already reached the
/// terminal, so those failures carry no message.
nonisolated protocol WorktreeGit: AnyObject {
    /// The `git -C` anchor for repository-wide calls, set once the layout is
    /// known: the main worktree, or the `.bare` directory.
    var repoDir: String? { get set }

    // Bootstrap, from the working directory.
    var workingDirectoryPath: String { get }
    func toplevel() -> String?
    func commonDir(root: String) -> String?

    // Repository-wide.
    func configGet(_ key: String) -> String?
    func originURL() -> String?
    /// `origin/HEAD`'s short name, such as `origin/main`.
    func originHead() -> String?
    func branchExists(_ branch: String) -> Bool
    func refExists(_ ref: String) -> Bool
    func isAncestor(_ ref: String, of other: String) -> Bool
    /// The full commit SHA `ref` names, or nil when it names none.
    func revParse(_ ref: String) -> String?
    func localBranches() -> [String]
    func worktreeEntries() -> [WorktreeEntry]
    func fetchBase(_ baseBranch: String, quiet: Bool) throws
    /// With `fatal` off, a failure returns false instead of throwing.
    @discardableResult func worktreeAdd(path: String, branch: String, new: Bool, baseRef: String?, fatal: Bool) throws -> Bool
    func worktreeRemove(path: String, force: Bool) throws
    func branchDelete(_ branch: String, force: Bool) throws
    func branchDeleteOK(_ branch: String, force: Bool) -> Bool
    func worktreeMove(from: String, to: String) throws

    // Per worktree.
    func branchOf(_ path: String) throws -> String
    func isClean(_ path: String) throws -> Bool
    func statusV2Lines(_ path: String) -> [String]
    func shortHead(_ path: String) -> String?
    /// Commits ahead of `baseRef`, as a string; empty when unanswerable.
    func aheadCount(_ path: String, baseRef: String) -> String
    func checkoutOK(_ path: String, ref: String, detach: Bool, silent: Bool) -> Bool
    func checkoutFatal(_ path: String, ref: String, detach: Bool, quietStdout: Bool) throws
    /// Stashes every change, untracked files included, and returns the new
    /// entry's commit SHA. The stash list is shared by every worktree, and
    /// other processes push to it too, so callers restore by this SHA rather
    /// than by `stash@{0}`.
    func stashPush(_ path: String, message: String) throws -> String
    /// Applies the stash commit `sha` in `path`, then drops that entry. On
    /// failure, conflicts included, the entry stays in the list.
    func stashRestoreOK(_ path: String, sha: String, silent: Bool) -> Bool
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
        status(arguments, .silent) == 0
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

    enum Output {
        /// Both streams reach the terminal.
        case inherit
        /// Stdout discarded, stderr to the terminal.
        case quiet
        /// Both discarded.
        case silent
    }

    /// The exit status of `arguments`, its output routed by `output`. A git
    /// that can't be launched reads as status 1.
    private func status(_ arguments: [String], _ output: Output) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        if let workingDirectory { process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory) }
        if output != .inherit { process.standardOutput = FileHandle.nullDevice }
        if output == .silent { process.standardError = FileHandle.nullDevice }
        do {
            try process.run()
        } catch {
            return 1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func visibleOK(_ arguments: [String]) -> Bool {
        status(arguments, .inherit) == 0
    }

    /// On failure, exits with git's own code: its error already reached the
    /// terminal.
    private func visibleFatal(_ arguments: [String], quietStdout: Bool = false) throws {
        let code = status(arguments, quietStdout ? .quiet : .inherit)
        if code != 0 { throw CLIFailure(nil, code: code) }
    }

    /// Stdout trimmed, or a silent failure carrying git's exit code.
    private func outputOrExit(_ arguments: [String]) throws -> String {
        guard let result = capture(arguments) else { throw CLIFailure(nil) }
        guard result.status == 0 else { throw CLIFailure(nil, code: result.status) }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Bootstrap

    var workingDirectoryPath: String {
        workingDirectory ?? FileManager.default.currentDirectoryPath
    }

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

    func originURL() -> String? {
        outputOrNil(repoGit("remote", "get-url", "origin"))
    }

    func originHead() -> String? {
        outputOrNil(repoGit("symbolic-ref", "--short", "refs/remotes/origin/HEAD"))
    }

    func branchExists(_ branch: String) -> Bool {
        silentOK(repoGit("show-ref", "--verify", GitRef.local(branch)))
    }

    func refExists(_ ref: String) -> Bool {
        silentOK(repoGit("rev-parse", "--verify", "--quiet", ref))
    }

    func isAncestor(_ ref: String, of other: String) -> Bool {
        silentOK(repoGit("merge-base", "--is-ancestor", ref, other))
    }

    func revParse(_ ref: String) -> String? {
        outputOrNil(repoGit("rev-parse", "--verify", "--quiet", "\(ref)^{commit}"))
    }

    func localBranches() -> [String] {
        lines(outputOrNil(repoGit("for-each-ref", "--format=%(refname:lstrip=2)", "refs/heads")))
    }

    func worktreeEntries() -> [WorktreeEntry] {
        WorktreePorcelain.entries(from: outputOrNil(repoGit("worktree", "list", "--porcelain")) ?? "")
    }

    func fetchBase(_ baseBranch: String, quiet: Bool) throws {
        let arguments = repoGit("fetch", "origin", baseBranch)
        if quiet {
            _ = silentOK(arguments)
        } else {
            try visibleFatal(arguments)
        }
    }

    func worktreeAdd(path: String, branch: String, new: Bool, baseRef: String?, fatal: Bool) throws -> Bool {
        // `--no-track`: the new branch starts at the base without adopting it
        // as upstream, so its first push creates its own remote branch.
        let arguments = new
            ? repoGit("worktree", "add", "--no-track", "-b", branch, path, baseRef ?? "HEAD")
            : repoGit("worktree", "add", path, branch)
        if fatal {
            try visibleFatal(arguments)
            return true
        }
        return visibleOK(arguments)
    }

    func worktreeRemove(path: String, force: Bool) throws {
        try visibleFatal(force ? repoGit("worktree", "remove", "--force", path) : repoGit("worktree", "remove", path))
    }

    func branchDelete(_ branch: String, force: Bool) throws {
        try visibleFatal(repoGit("branch", force ? "-D" : "-d", branch))
    }

    func branchDeleteOK(_ branch: String, force: Bool) -> Bool {
        visibleOK(repoGit("branch", force ? "-D" : "-d", branch))
    }

    func worktreeMove(from: String, to: String) throws {
        try visibleFatal(repoGit("worktree", "move", from, to))
    }

    // MARK: Per worktree

    func branchOf(_ path: String) throws -> String {
        let name = try outputOrExit(worktreeGit(path, "rev-parse", "--symbolic-full-name", "HEAD"))
        return name.hasPrefix("refs/heads/") ? String(name.dropFirst("refs/heads/".count)) : name
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

    private func checkoutArguments(_ path: String, ref: String, detach: Bool) -> [String] {
        ["git", "-C", path, "checkout"] + (detach ? ["--detach"] : []) + [ref]
    }

    func checkoutOK(_ path: String, ref: String, detach: Bool, silent: Bool) -> Bool {
        let arguments = checkoutArguments(path, ref: ref, detach: detach)
        return silent ? silentOK(arguments) : visibleOK(arguments)
    }

    func checkoutFatal(_ path: String, ref: String, detach: Bool, quietStdout: Bool) throws {
        try visibleFatal(checkoutArguments(path, ref: ref, detach: detach), quietStdout: quietStdout)
    }

    func stashPush(_ path: String, message: String) throws -> String {
        // The UUID makes the message unique, so the entry is found by it
        // even if another process pushes in between.
        let unique = "\(message) [\(UUID().uuidString)]"
        try visibleFatal(worktreeGit(path, "stash", "push", "--include-untracked", "-m", unique))
        guard let entry = stashEntries(path).first(where: { $0.subject.hasSuffix(": \(unique)") }) else {
            throw CLIFailure("stashed changes in \(path), but could not find the entry — see `git stash list`")
        }
        return entry.sha
    }

    func stashRestoreOK(_ path: String, sha: String, silent: Bool) -> Bool {
        let apply = worktreeGit(path, "stash", "apply", sha)
        guard silent ? silentOK(apply) : visibleOK(apply) else { return false }
        // Re-found now: entries pushed since this one shift its index.
        if let index = stashEntries(path).firstIndex(where: { $0.sha == sha }) {
            _ = silentOK(worktreeGit(path, "stash", "drop", "stash@{\(index)}"))
        }
        return true
    }

    private func stashEntries(_ path: String) -> [(sha: String, subject: String)] {
        lines(outputOrNil(worktreeGit(path, "stash", "list", "--format=%H %gs"))).compactMap { line in
            guard let space = line.firstIndex(of: " ") else { return nil }
            return (String(line[..<space]), String(line[line.index(after: space)...]))
        }
    }

    func branchMove(_ path: String, from: String, to: String) throws {
        try visibleFatal(worktreeGit(path, "branch", "-m", from, to))
    }

    func commitAll(_ path: String, extraArguments: [String]) -> Int32 {
        status(["git", "-C", path, "commit", "-a"] + extraArguments, .inherit)
    }

    func enableUntrackedCache(_ path: String) {
        // Best effort: a file system without support refuses, harmlessly.
        _ = silentOK(worktreeGit(path, "update-index", "--untracked-cache"))
    }
}
