import Foundation

/// Builds GitLab's merge request query and normalizes its response into
/// `PullRequest`, so callers never branch on the forge.
nonisolated enum GitLabQuery {
    /// One query for every branch. Branch names are inlined as string
    /// literals: glab silently drops list-typed variables passed with `-f`,
    /// which would drop the filter.
    static func build(fullPath: String, branches: [String]) -> String {
        // TODO(PLUME-316 group A)
        ""
    }

    /// Every source branch present in the response, keyed by branch. Among
    /// several merge requests on one branch an opened one wins, then the
    /// highest iid, compared as a number.
    static func normalize(_ data: Data) throws -> PullRequestMap {
        // TODO(PLUME-316 group A)
        [:]
    }

    /// The project's full path (`group/sub/repo`) from an ssh or https
    /// origin URL, for GraphQL's `project(fullPath:)`.
    static func fullPath(originURL: String?) -> String? {
        // TODO(PLUME-316 group A)
        nil
    }
}
