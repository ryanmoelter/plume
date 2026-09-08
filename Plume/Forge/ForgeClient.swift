import Foundation

/// What a branch's pull request column knows right now.
///
/// An enum rather than an optional because "the fetch failed" and "there is
/// no pull request" must not render the same. Collapsing them tells the user
/// their PR does not exist whenever they are offline.
nonisolated enum PullRequestFetchState: Sendable, Equatable {
    /// The fetch succeeded and this branch has a pull request.
    case pullRequest(PullRequest)
    /// The fetch succeeded and this branch has none.
    case noPR
    /// The branch has never been pushed, so no forge could know it.
    case localOnly
    case loading
    case timedOut
    case failed(String)
    /// The origin is neither GitHub nor GitLab, or its client isn't built yet.
    case forgeUnsupported
}

nonisolated protocol ForgeClient: Sendable {
    /// Pull requests for `branches`, keyed by branch. A branch with no pull
    /// request maps to nil.
    ///
    /// Throws rather than reporting per-branch failure: one unreachable forge
    /// invalidates the whole answer, and that is what lets a caller tell
    /// "offline" from "no PR".
    func fetchPullRequests(
        forBranches branches: [String],
        in repository: String
    ) async throws -> [String: PullRequest?]
}

nonisolated struct ForgeError: LocalizedError, Equatable {
    enum Kind: Sendable, Equatable {
        case failed
        /// The subprocess outlived its deadline and was killed. Distinct so a
        /// caller can render `.timedOut` rather than a bare failure.
        case timedOut
    }

    let message: String
    let kind: Kind

    init(message: String, kind: Kind = .failed) {
        self.message = message
        self.kind = kind
    }

    var errorDescription: String? { message }
}

extension PullRequestFetchState {
    /// The state a thrown fetch error should render as.
    static func failing(_ error: any Error) -> PullRequestFetchState {
        if let forge = error as? ForgeError, forge.kind == .timedOut { return .timedOut }
        return .failed(error.localizedDescription)
    }
}
