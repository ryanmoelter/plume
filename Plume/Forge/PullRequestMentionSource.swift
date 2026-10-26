import Foundation

/// The pull requests a mention can name, from the GitHub repository a tab
/// directory belongs to.
///
/// Each repository's open pull requests are cached for `cacheLifetime`,
/// along with any lookups by number and title searches. A failure (no `gh`,
/// not logged in, no network) is cached the same way, so it costs one
/// subprocess per lifetime and shows as no results.
actor PullRequestMentionSource {
    static let shared = PullRequestMentionSource()

    static let cacheLifetime: TimeInterval = 120
    static let minimumSearchLength = 3

    typealias Runner = @Sendable (_ arguments: [String], _ directory: String) async throws -> Data
    typealias Resolver = @Sendable (String) async -> (repository: String, facts: RepositoryFacts)?

    private struct Repository {
        let fetchedAt: Date
        let nameWithOwner: String?
        /// Nil when the list could not be fetched.
        let pulls: [MentionCandidate.PullRequestEntry]?
        var byNumber: [Int: MentionCandidate.PullRequestEntry?] = [:]
        var searches: [String: [MentionCandidate.PullRequestEntry]] = [:]
    }

    private struct Resolution {
        let root: String?
        let resolvedAt: Date
    }

    private var repositories: [String: Repository] = [:]
    private var listLoads: [String: Task<Repository, Never>] = [:]
    private var resolutions: [String: Resolution] = [:]

    private let run: Runner
    private let resolve: Resolver
    private let now: @Sendable () -> Date

    init(
        run: @escaping Runner = PullRequestMentionSource.runGH,
        resolve: @escaping Resolver = PullRequestStore.resolveWithGit,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.run = run
        self.resolve = resolve
        self.now = now
    }

    static let runGH: Runner = { arguments, directory in
        try await Task.detached(priority: .userInitiated) {
            try GHCommand.run(arguments: arguments, in: directory, timeout: .seconds(10))
        }.value
    }

    /// Empty for a files-only query, a directory outside a GitHub
    /// repository, or while `gh` is failing.
    func matches(
        for query: MentionQuery,
        in directory: String?,
        limit: Int = PullRequestMentionMatcher.defaultLimit
    ) async -> [RankedMention] {
        guard query.scope != .files, let directory, let root = await repositoryRoot(for: directory) else { return [] }
        guard var repository = await openPullRequests(in: root), var pulls = repository.pulls else { return [] }

        var term = query.text.trimmingCharacters(in: .whitespaces)
        if term.hasPrefix("#") { term.removeFirst() }
        let known = Set(pulls.map(\.number))

        if let number = Int(term), term.allSatisfy(\.isASCII), !known.contains(number) {
            if repository.byNumber[number] == nil {
                guard !Task.isCancelled else { return [] }
                let pull = await fetch(GitHubMentionQuery.pullRequest(number: number), in: root) {
                    try GitHubMentionQuery.decodePullRequest($0)
                }
                repository.byNumber[number] = .some(pull ?? nil)
            }
            if let pull = repository.byNumber[number] ?? nil { pulls.append(pull) }
        } else if Int(term) == nil, term.count >= Self.minimumSearchLength, let nameWithOwner = repository.nameWithOwner {
            let key = term.lowercased()
            if repository.searches[key] == nil {
                guard !Task.isCancelled else { return [] }
                let query = GitHubMentionQuery.titleSearch(term, nameWithOwner: nameWithOwner)
                let found = await fetch(query, in: root) { try GitHubMentionQuery.decodeSearch($0) }
                repository.searches[key] = found ?? []
            }
            let listed = Set(pulls.map(\.number))
            pulls += (repository.searches[key] ?? []).filter { !listed.contains($0.number) }
        }
        store(repository, for: root)

        guard !Task.isCancelled else { return [] }
        return PullRequestMentionMatcher.matches(term, in: pulls, limit: limit)
    }

    private func fetch<Result>(
        _ query: String,
        in root: String,
        decode: (Data) throws -> Result
    ) async -> Result? {
        guard let data = try? await run(GitHubMentionQuery.arguments(for: query), root) else { return nil }
        return try? decode(data)
    }

    /// Keeps lookups made since the list was read, unless the list has been
    /// replaced meanwhile.
    private func store(_ repository: Repository, for root: String) {
        guard repositories[root]?.fetchedAt == repository.fetchedAt else { return }
        repositories[root] = repository
    }

    private func repositoryRoot(for directory: String) async -> String? {
        if let resolution = resolutions[directory],
           now().timeIntervalSince(resolution.resolvedAt) < Self.cacheLifetime {
            return resolution.root
        }
        var root: String?
        if let resolved = await resolve(directory),
           ForgeKind.sniffing(originURL: resolved.facts.originURL) == .github {
            root = resolved.repository
        }
        resolutions[directory] = Resolution(root: root, resolvedAt: now())
        return root
    }

    private func openPullRequests(in root: String) async -> Repository? {
        if let repository = repositories[root],
           now().timeIntervalSince(repository.fetchedAt) < Self.cacheLifetime {
            return repository
        }
        if let load = listLoads[root] { return await load.value }
        let run = run
        let now = now
        let load = Task {
            let fetchedAt = now()
            guard let data = try? await run(GitHubMentionQuery.arguments(for: GitHubMentionQuery.openPullRequests), root),
                  let list = try? GitHubMentionQuery.decodeOpenPullRequests(data)
            else { return Repository(fetchedAt: fetchedAt, nameWithOwner: nil, pulls: nil) }
            return Repository(fetchedAt: fetchedAt, nameWithOwner: list.nameWithOwner, pulls: list.pulls)
        }
        listLoads[root] = load
        let repository = await load.value
        listLoads[root] = nil
        repositories[root] = repository
        return repository
    }
}
