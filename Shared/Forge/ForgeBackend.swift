import Foundation

/// A forge's CLI (`gh` or `glab`), behind one interface so callers hold a
/// backend and never branch on the forge. Both are soft dependencies: an
/// uninstalled CLI or a failed request yields nil, never an error.
nonisolated protocol ForgeBackend: Sendable {
    var kind: ForgeKind { get }
    /// `#` on GitHub, `!` on GitLab.
    var numberPrefix: String { get }
    /// `PR` on GitHub, `MR` on GitLab.
    var noun: String { get }
    var isInstalled: Bool { get }
    /// Pull requests for `branches`, or nil when the request failed or the
    /// CLI is missing, so a caller can tell "no PR" from "unreachable".
    func pullRequests(forBranches branches: [String]) -> PullRequestMap?
}

/// `gh api graphql`, chunked by `GitHubQuery.chunkSize`. `gh` resolves its
/// `{owner}`/`{repo}` placeholders from `workingDirectory`.
nonisolated struct GitHubBackend: ForgeBackend {
    var workingDirectory: String?

    var kind: ForgeKind { .github }
    var numberPrefix: String {
        // TODO(PLUME-316 group A)
        ""
    }
    var noun: String {
        // TODO(PLUME-316 group A)
        ""
    }
    var isInstalled: Bool {
        // TODO(PLUME-316 group A)
        false
    }

    func pullRequests(forBranches branches: [String]) -> PullRequestMap? {
        // TODO(PLUME-316 group A)
        nil
    }
}

/// `glab api graphql`, one request for every branch.
nonisolated struct GitLabBackend: ForgeBackend {
    var fullPath: String
    var workingDirectory: String?

    var kind: ForgeKind { .gitlab }
    var numberPrefix: String {
        // TODO(PLUME-316 group A)
        ""
    }
    var noun: String {
        // TODO(PLUME-316 group A)
        ""
    }
    var isInstalled: Bool {
        // TODO(PLUME-316 group A)
        false
    }

    func pullRequests(forBranches branches: [String]) -> PullRequestMap? {
        // TODO(PLUME-316 group A)
        nil
    }
}

nonisolated enum ForgeBackends {
    /// The backend for `kind`, or nil for `.none` and for a GitLab origin
    /// whose project path can't be read.
    static func backend(for kind: ForgeKind, originURL: String?, workingDirectory: String?) -> (any ForgeBackend)? {
        // TODO(PLUME-316 group A)
        nil
    }
}
