import Foundation

/// The pull requests a mention can name, from the GitHub repository a tab
/// directory belongs to.
///
/// Each repository's open pull requests are cached for `cacheLifetime`,
/// along with the viewer's own, any lookups by number and title searches.
/// Only answers are cached, a number the repository has no pull request for
/// among them. A failed `gh` call (no `gh`, not logged in, no network, a
/// timeout) caches nothing and holds off that repository's requests for
/// `failureBackoff`, so the next lookup after it tries again. A cancelled
/// call is not a failure.
actor PullRequestMentionSource {
    static let shared = PullRequestMentionSource()

    static let cacheLifetime: TimeInterval = 120
    static let failureBackoff: TimeInterval = 10
    static let minimumSearchLength = 3

    /// The pull request number a term names, for ASCII digits only: `Int(_:)`
    /// alone would also take `+5` and `-5`.
    nonisolated static func number(in term: String) -> Int? {
        guard !term.isEmpty, term.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(term)
    }

    typealias Entry = MentionCandidate.PullRequestEntry
    typealias Runner = @Sendable (_ arguments: [String], _ directory: String) async throws -> Data
    typealias Resolver = @Sendable (String) async -> (repository: String, facts: RepositoryFacts)?

    private struct Repository {
        let fetchedAt: Date
        let nameWithOwner: String?
        let pulls: [Entry]
        var related: [Entry]?
        /// A nil value is a definitive answer: the repository has no such
        /// pull request.
        var byNumber: [Int: Entry?] = [:]
        var searches: [String: [Entry]] = [:]
    }

    private struct Resolution {
        let root: String?
        let resolvedAt: Date
    }

    private var repositories: [String: Repository] = [:]
    private var listLoads: [String: Task<Repository?, Never>] = [:]
    private var resolutions: [String: Resolution] = [:]
    private var retryAfter: [String: Date] = [:]

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
        try await GHCommand.run(arguments: arguments, in: directory, timeout: .seconds(10))
    }

    /// Empty for a query that leaves pull requests out, a directory outside
    /// a GitHub repository, or while `gh` is failing. An empty term lists
    /// only the viewer's own open pull requests. Without `includingLookups`
    /// only the open list and lookups already cached answer.
    func matches(
        for query: MentionQuery,
        in directory: String?,
        includingLookups: Bool = true,
        limit: Int = PullRequestMentionMatcher.defaultLimit
    ) async -> [RankedMention] {
        guard query.sources.contains(.pullRequests), let directory,
              let root = await repositoryRoot(for: directory),
              let repository = await openPullRequests(in: root)
        else { return [] }
        var pulls = repository.pulls

        var term = query.text.trimmingCharacters(in: .whitespaces)
        if term.hasPrefix("#") { term.removeFirst() }
        let known = Set(pulls.map(\.number))

        if term.isEmpty {
            guard let related = await relatedPullRequests(in: root, repository: repository, includingLookups: includingLookups)
            else { return [] }
            pulls = related
        } else if let number = Self.number(in: term), !known.contains(number) {
            var found = repository.byNumber[number]
            if found == nil, includingLookups {
                found = await lookUp(number, in: root, listedAt: repository.fetchedAt)
            }
            if let pull = found ?? nil { pulls.append(pull) }
        } else if Self.number(in: term) == nil, term.count >= Self.minimumSearchLength, let nameWithOwner = repository.nameWithOwner {
            let key = term.lowercased()
            var found = repository.searches[key]
            if found == nil, includingLookups, canRequest(root) {
                guard !Task.isCancelled else { return [] }
                let request = GitHubMentionQuery.titleSearch(term, nameWithOwner: nameWithOwner)
                found = await fetch(request, in: root) { try GitHubMentionQuery.decodeSearch($0) }.value
                guard !Task.isCancelled else { return [] }
                if let found { update(root, listedAt: repository.fetchedAt) { $0.searches[key] = found } }
            }
            let listed = Set(pulls.map(\.number))
            pulls += (found ?? []).filter { !listed.contains($0.number) }
        }

        guard !Task.isCancelled else { return [] }
        return PullRequestMentionMatcher.matches(term, in: pulls, limit: limit)
    }

    /// The pull request `number` names in the repository `directory` belongs
    /// to, from the cache where it can be.
    func pullRequest(number: Int, in directory: String) async -> Entry? {
        guard let root = await repositoryRoot(for: directory),
              let repository = await openPullRequests(in: root)
        else { return nil }
        if let listed = repository.pulls.first(where: { $0.number == number }) { return listed }
        if let found = repository.byNumber[number] { return found }
        return await lookUp(number, in: root, listedAt: repository.fetchedAt) ?? nil
    }

    /// Nil when no answer came, `.some(nil)` when the repository has no such
    /// pull request.
    private func lookUp(_ number: Int, in root: String, listedAt fetchedAt: Date) async -> Entry?? {
        guard canRequest(root), !Task.isCancelled else { return nil }
        let answer = await fetch(GitHubMentionQuery.pullRequest(number: number), in: root) {
            try GitHubMentionQuery.decodePullRequest($0)
        }
        let pull: Entry?
        switch answer {
        case .answered(let found): pull = found
        case .missing: pull = nil
        case .unanswered: return nil
        }
        update(root, listedAt: fetchedAt) { $0.byNumber[number] = .some(pull) }
        return .some(pull)
    }

    private func relatedPullRequests(in root: String, repository: Repository, includingLookups: Bool) async -> [Entry]? {
        if let related = repository.related { return related }
        guard includingLookups, canRequest(root), let nameWithOwner = repository.nameWithOwner else { return nil }
        let related = await fetch(GitHubMentionQuery.relatedPullRequests(nameWithOwner: nameWithOwner), in: root) {
            try GitHubMentionQuery.decodeRelatedPullRequests($0)
        }.value
        if let related { update(root, listedAt: repository.fetchedAt) { $0.related = related } }
        return related
    }

    private enum Answer<Value> {
        case answered(Value)
        /// GitHub has no pull request with the number asked for.
        case missing
        case unanswered

        var value: Value? {
            if case .answered(let value) = self { value } else { nil }
        }
    }

    /// Unanswered when the call was cancelled, or when `gh` failed or its
    /// answer didn't decode, which also starts the repository's backoff.
    private func fetch<Value>(
        _ request: GitHubMentionQuery.Request,
        in root: String,
        decode: (Data) throws -> Value
    ) async -> Answer<Value> {
        do {
            let data = try await run(request.arguments, root)
            // Not `try?`, which would flatten a decoded nil into a failure.
            do { return .answered(try decode(data)) } catch {}
        } catch is CancellationError {
            return .unanswered
        } catch {
            let message = (error as? ForgeError)?.message ?? ""
            if !PullRequestLinkSource.missingNumbers(in: message).isEmpty { return .missing }
        }
        guard !Task.isCancelled else { return .unanswered }
        retryAfter[root] = now().addingTimeInterval(Self.failureBackoff)
        return .unanswered
    }

    private func canRequest(_ root: String) -> Bool {
        guard let until = retryAfter[root] else { return true }
        return now() >= until
    }

    /// Records a lookup on the repository's current entry, unless its list has
    /// been replaced since the lookup began.
    private func update(_ root: String, listedAt fetchedAt: Date, _ change: (inout Repository) -> Void) {
        guard repositories[root]?.fetchedAt == fetchedAt else { return }
        change(&repositories[root]!)
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

    /// A stale list is still served when a refresh fails or waits out the
    /// backoff.
    private func openPullRequests(in root: String) async -> Repository? {
        let cached = repositories[root]
        if let cached, now().timeIntervalSince(cached.fetchedAt) < Self.cacheLifetime { return cached }
        guard canRequest(root) else { return cached }
        if let load = listLoads[root] { return await load.value }
        let run = run
        let now = now
        let load = Task<Repository?, Never> {
            let fetchedAt = now()
            guard let data = try? await run(GitHubMentionQuery.openPullRequests.arguments, root),
                  let list = try? GitHubMentionQuery.decodeOpenPullRequests(data)
            else { return nil }
            return Repository(fetchedAt: fetchedAt, nameWithOwner: list.nameWithOwner, pulls: list.pulls)
        }
        listLoads[root] = load
        let repository = await load.value
        listLoads[root] = nil
        guard let repository else {
            retryAfter[root] = now().addingTimeInterval(Self.failureBackoff)
            return cached
        }
        repositories[root] = repository
        return repository
    }
}
