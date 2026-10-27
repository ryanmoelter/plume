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
        try git(arguments)
    }

    @discardableResult
    func git(_ arguments: [String]) throws -> String {
        let result = try run(arguments)
        guard result.status == 0 else {
            let error = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw CLIFailure("`git \(arguments.joined(separator: " "))` failed" + (error.isEmpty ? "" : ": \(error)"))
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func succeeds(_ arguments: String...) -> Bool {
        (try? run(arguments).status) == 0
    }

    /// `git switch`, exiting with git's status on failure; git has already
    /// said why.
    func switchTo(_ branch: String, quiet: Bool = false) throws {
        let result = try run(["switch"] + (quiet ? ["-q"] : []) + [branch], capture: false)
        if result.status != 0 { throw CLIFailure(nil, code: result.status) }
    }
}

nonisolated final class ProcessStackGit: StackGit {
    let workingDirectory: String?

    init(workingDirectory: String? = nil) {
        self.workingDirectory = workingDirectory
    }

    func run(_ arguments: [String], capture: Bool, input: String?) throws -> CLIProcessResult {
        try CLIProcess.run(["git"] + arguments, check: false, capture: capture, input: input, workingDirectory: workingDirectory)
    }

    private func output(_ arguments: String...) -> String? {
        guard let result = try? run(arguments), result.status == 0 else { return nil }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func resolve(_ ref: String) -> String? {
        output("rev-parse", "--verify", "--quiet", ref).flatMap { $0.isEmpty ? nil : $0 }
    }

    func currentBranch() -> String? {
        output("symbolic-ref", "--short", "-q", "HEAD").flatMap { $0.isEmpty ? nil : $0 }
    }

    func localBranches() -> [String] {
        guard let out = output("for-each-ref", "refs/heads", "--format=%(refname:short)"), !out.isEmpty else { return [] }
        return out.components(separatedBy: "\n")
    }

    func branchExists(_ branch: String) -> Bool {
        succeeds("rev-parse", "--verify", "--quiet", "refs/heads/\(branch)")
    }

    func isAncestor(_ ancestor: String, _ descendant: String) -> Bool {
        succeeds("merge-base", "--is-ancestor", ancestor, descendant)
    }

    func mergeBase(_ lhs: String, _ rhs: String) -> String? {
        output("merge-base", lhs, rhs).flatMap { $0.isEmpty ? nil : $0 }
    }

    func revListCount(_ range: String) throws -> Int {
        let out = try git("rev-list", "--count", range)
        guard let count = Int(out) else { throw CLIFailure("unexpected rev-list output: \(out)") }
        return count
    }

    func originAheadBehind(_ branch: String) -> (ahead: Int, behind: Int)? {
        guard succeeds("rev-parse", "--verify", "--quiet", "refs/remotes/origin/\(branch)"),
              let out = output("rev-list", "--count", "--left-right", "\(branch)...origin/\(branch)")
        else { return nil }
        let parts = out.split(separator: "\t").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1])
    }

    func worktreeMap() -> [String: String] {
        guard let out = output("worktree", "list", "--porcelain") else { return [:] }
        var map: [String: String] = [:]
        var path: String?
        for line in out.components(separatedBy: "\n") {
            if line.hasPrefix("worktree ") {
                path = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("branch refs/heads/"), let path {
                map[String(line.dropFirst("branch refs/heads/".count))] = path
            }
        }
        return map
    }

    func originURL() -> String? {
        output("remote", "get-url", "origin").flatMap { $0.isEmpty ? nil : $0 }
    }

    /// `origin/HEAD` as `origin/<branch>`, or nil.
    func originHead() -> String? {
        output("symbolic-ref", "--short", "refs/remotes/origin/HEAD").flatMap { $0.isEmpty ? nil : $0 }
    }
}
