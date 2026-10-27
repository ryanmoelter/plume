import Foundation

/// The forge `submit` and `sync` talk to, through `gh` or `glab`. Both stay
/// soft dependencies: only the commands that need the forge require one.
nonisolated protocol StackForge: AnyObject {
    var kind: ForgeKind { get }
    /// `#` on GitHub, `!` on GitLab.
    var numberPrefix: String { get }
    /// `PR` on GitHub, `MR` on GitLab.
    var noun: String { get }
    /// `gh` or `glab`.
    var cliName: String { get }
    var isInstalled: Bool { get }
    /// Fails unless the CLI is installed and signed in.
    func requireReady() throws
    /// Pull requests by branch, or nil when the request failed.
    func pullRequests(forBranches branches: [String]) -> PullRequestMap?
    func editBase(number: Int, base: String) throws -> CLIProcessResult
    func create(head: String, base: String, title: String, body: String, draft: Bool) throws -> CLIProcessResult
    /// GitHub's native stacked PRs; nil on GitLab.
    var nativeStacks: (any GitHubNativeStacks)? { get }
}

nonisolated extension StackForge {
    /// Pull requests by branch, empty when the request failed.
    func pullRequestsOrEmpty(forBranches branches: [String]) -> PullRequestMap {
        pullRequests(forBranches: branches) ?? [:]
    }
}

/// A GitHub native stack: its number and its pull requests, bottom first.
nonisolated struct GitHubNativeStack: Equatable, Sendable {
    var number: Int?
    var pullRequestNumbers: [Int]
}

/// GitHub's stack API. Cosmetic to `stack`: branches and PR bases are right
/// without it, so every failure degrades to a missing stack navigator.
nonisolated protocol GitHubNativeStacks: AnyObject {
    /// Whether the repository has the feature, probed once and cached.
    func isEnabled() -> Bool
    /// Caches the feature as off after a call unexpectedly fails.
    func markUnavailable()
    /// The stack holding `pullRequest`, merged members included.
    func stack(containing pullRequest: Int) -> GitHubNativeStack?
    /// Registers a stack; the number is read from the response when it has one.
    func create(_ pullRequests: [Int]) -> (ok: Bool, number: Int?)
    func add(_ pullRequests: [Int], to stack: Int) -> Bool
}

/// `gh`, in `workingDirectory`, which resolves its `{owner}`/`{repo}`.
nonisolated final class GitHubStackForge: StackForge {
    let workingDirectory: String?
    /// Holds the cached feature probe.
    let stateDirectory: String

    init(workingDirectory: String?, stateDirectory: String) {
        self.workingDirectory = workingDirectory
        self.stateDirectory = stateDirectory
    }

    var kind: ForgeKind { .github }
    var numberPrefix: String { "#" }
    var noun: String { "PR" }
    var cliName: String { "gh" }
    var isInstalled: Bool { false }
    func requireReady() throws { throw CLIFailure("not implemented") }
    func pullRequests(forBranches branches: [String]) -> PullRequestMap? { nil }
    func editBase(number: Int, base: String) throws -> CLIProcessResult { throw CLIFailure("not implemented") }
    func create(head: String, base: String, title: String, body: String, draft: Bool) throws -> CLIProcessResult {
        throw CLIFailure("not implemented")
    }
    var nativeStacks: (any GitHubNativeStacks)? { nil }
}

/// `glab`, for the project at `fullPath`.
nonisolated final class GitLabStackForge: StackForge {
    let fullPath: String
    let workingDirectory: String?

    init(fullPath: String, workingDirectory: String?) {
        self.fullPath = fullPath
        self.workingDirectory = workingDirectory
    }

    var kind: ForgeKind { .gitlab }
    var numberPrefix: String { "!" }
    var noun: String { "MR" }
    var cliName: String { "glab" }
    var isInstalled: Bool { false }
    func requireReady() throws { throw CLIFailure("not implemented") }
    func pullRequests(forBranches branches: [String]) -> PullRequestMap? { nil }
    func editBase(number: Int, base: String) throws -> CLIProcessResult { throw CLIFailure("not implemented") }
    func create(head: String, base: String, title: String, body: String, draft: Bool) throws -> CLIProcessResult {
        throw CLIFailure("not implemented")
    }
    var nativeStacks: (any GitHubNativeStacks)? { nil }
}
