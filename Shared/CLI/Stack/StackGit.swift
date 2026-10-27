import Foundation

/// The git operations `stack` runs. Graph questions are their own methods so
/// tests can answer them from memory; everything else goes through `run`.
nonisolated protocol StackGit: AnyObject {
    /// The working directory every command runs in; nil is the process's.
    var workingDirectory: String? { get }
    /// `rev-parse --verify --quiet`: the sha, or nil when `ref` names nothing.
    func resolve(_ ref: String) -> String?
    func currentBranch() -> String?
    func localBranches() -> [String]
    func branchExists(_ branch: String) -> Bool
    func isAncestor(_ ancestor: String, _ descendant: String) -> Bool
    func mergeBase(_ lhs: String, _ rhs: String) -> String?
    /// Commits in a range such as `base..tip`.
    func revListCount(_ range: String) throws -> Int
    /// Commits on `branch` not on `origin/<branch>` and the reverse, or nil
    /// with no such remote branch. Reads the last fetch only.
    func originAheadBehind(_ branch: String) -> (ahead: Int, behind: Int)?
    /// Branch name to the worktree it is checked out in.
    func worktreeMap() -> [String: String]
    func originURL() -> String?
    /// `git <arguments>`. With `capture` off the child shares this process's
    /// stdout and stderr.
    func run(_ arguments: [String], capture: Bool, input: String?) throws -> CLIProcessResult
}

nonisolated extension StackGit {
    @discardableResult
    func run(_ arguments: [String], capture: Bool = true) throws -> CLIProcessResult {
        try run(arguments, capture: capture, input: nil)
    }

    /// Trimmed stdout, failing on a non-zero exit.
    @discardableResult
    func git(_ arguments: String...) throws -> String {
        throw CLIFailure("not implemented")
    }

    func succeeds(_ arguments: String...) -> Bool {
        false
    }
}

nonisolated final class ProcessStackGit: StackGit {
    let workingDirectory: String?

    init(workingDirectory: String? = nil) {
        self.workingDirectory = workingDirectory
    }

    func resolve(_ ref: String) -> String? { nil }
    func currentBranch() -> String? { nil }
    func localBranches() -> [String] { [] }
    func branchExists(_ branch: String) -> Bool { false }
    func isAncestor(_ ancestor: String, _ descendant: String) -> Bool { false }
    func mergeBase(_ lhs: String, _ rhs: String) -> String? { nil }
    func revListCount(_ range: String) throws -> Int { throw CLIFailure("not implemented") }
    func originAheadBehind(_ branch: String) -> (ahead: Int, behind: Int)? { nil }
    func worktreeMap() -> [String: String] { [:] }
    func originURL() -> String? { nil }
    /// `origin/HEAD` as `origin/<branch>`, or nil.
    func originHead() -> String? { nil }

    func run(_ arguments: [String], capture: Bool, input: String?) throws -> CLIProcessResult {
        throw CLIFailure("not implemented")
    }
}
