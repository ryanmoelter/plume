import Foundation

/// Fetches pull requests through the `gh` CLI.
///
/// An actor for the reason `GitService` is one: the subprocess blocks its
/// thread, and the project defaults isolation to `MainActor`, so reaching it
/// has to mean `await`.
actor GitHubForgeClient: ForgeClient {
    static let shared = GitHubForgeClient()

    private let timeout: Duration

    init(timeout: Duration = .seconds(20)) {
        self.timeout = timeout
    }

    func fetchPullRequests(
        forBranches branches: [String],
        in repository: String
    ) async throws -> [String: PullRequest?] {
        if branches.isEmpty { return [:] }
        var out: [String: PullRequest?] = [:]
        for chunk in GitHubQuery.chunks(of: branches) {
            let (query, aliasToBranch) = GitHubQuery.build(branches: chunk)
            let data = try runGH(query: query, in: repository)
            out.merge(try GitHubQuery.decode(data, aliasToBranch: aliasToBranch)) { _, new in new }
        }
        return out
    }

    /// `{owner}` and `{repo}` are gh's own placeholders — it resolves them
    /// from its working directory, so they are passed literally.
    private func runGH(query: String, in repository: String) throws -> Data {
        try GHCommand.run(
            arguments: [
                "api", "graphql",
                "-f", "query=" + query,
                "-F", "owner={owner}",
                "-F", "name={repo}",
            ],
            in: repository,
            timeout: timeout
        )
    }
}
