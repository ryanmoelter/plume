import Foundation

/// The GraphQL queries behind `#` mentions, and their decoders.
nonisolated enum GitHubMentionQuery {
    static let listSize = 50
    static let searchSize = 10

    private static let fields = "number title url state isDraft updatedAt"
    /// What a linked pull request's row draws beyond a mention's fields.
    private static let statusFields = "reviewDecision "
        + "reviewRequests(first: 1) { totalCount } latestReviews(first: 1) { totalCount } "
        + "commits(last: 1) { nodes { commit { statusCheckRollup { contexts(first: 100) "
        + "{ nodes { __typename ... on StatusContext { context state createdAt targetUrl } "
        + "... on CheckRun { name conclusion status startedAt detailsUrl } } } } } } }"

    /// A query and its variables. What the user typed travels only as a
    /// variable, sent with `-f`, which gh passes through as a plain string.
    struct Request: Equatable, Sendable {
        enum Variables: Equatable, Sendable {
            /// `$owner` and `$name`, filled from gh's `{owner}` and `{repo}`
            /// placeholders, which it resolves from its working directory.
            case repository
            /// `$owner` and `$name`, given rather than resolved by gh.
            case named(owner: String, name: String)
            case search(String)
            /// `$search0`, `$search1`, … in order.
            case searches([String])
        }

        let query: String
        let variables: Variables

        var arguments: [String] {
            var arguments = ["api", "graphql", "-f", "query=" + query]
            switch variables {
            case .repository: arguments += ["-F", "owner={owner}", "-F", "name={repo}"]
            case .named(let owner, let name): arguments += ["-f", "owner=" + owner, "-f", "name=" + name]
            case .search(let search): arguments += ["-f", "search=" + search]
            case .searches(let searches):
                for (index, search) in searches.enumerated() { arguments += ["-f", "search\(index)=" + search] }
            }
            return arguments
        }
    }

    static let openPullRequests = Request(
        query: "query($owner: String!, $name: String!) { "
            + "repository(owner: $owner, name: $name) { nameWithOwner "
            + "pullRequests(first: \(listSize), states: OPEN, orderBy: {field: UPDATED_AT, direction: DESC}) "
            + "{ nodes { \(fields) } } } }",
        variables: .repository
    )

    static func pullRequest(number: Int) -> Request {
        Request(
            query: "query($owner: String!, $name: String!) { "
                + "repository(owner: $owner, name: $name) { pullRequest(number: \(number)) { \(fields) } } }",
            variables: .repository
        )
    }

    static func pullRequest(number: Int, owner: String, name: String) -> Request {
        Request(
            query: pullRequest(number: number).query,
            variables: .named(owner: owner, name: name)
        )
    }

    /// Several pull requests of one repository in a single request, aliased
    /// `p<number>`.
    static func pullRequests(numbers: [Int], owner: String, name: String) -> Request {
        let aliased = numbers.map { "p\($0): pullRequest(number: \($0)) { \(fields) \(statusFields) }" }
        return Request(
            query: "query($owner: String!, $name: String!) { "
                + "repository(owner: $owner, name: $name) { \(aliased.joined(separator: " ")) } }",
            variables: .named(owner: owner, name: name)
        )
    }

    static func titleSearch(_ term: String, nameWithOwner: String) -> Request {
        Request(
            query: "query($search: String!) { search(query: $search, type: ISSUE, first: \(searchSize)) "
                + "{ nodes { ... on PullRequest { \(fields) } } } }",
            variables: .search("repo:\(nameWithOwner) is:pr in:title \(term)")
        )
    }

    /// The viewer's own open pull requests: authored, assigned, or with a
    /// review requested of them directly rather than through a team. Search
    /// can't OR qualifiers, so each is its own aliased search in one request.
    static func relatedPullRequests(nameWithOwner: String) -> Request {
        let qualifiers = ["author:@me", "assignee:@me", "user-review-requested:@me"]
        let declarations = qualifiers.indices.map { "$search\($0): String!" }.joined(separator: ", ")
        let searches = qualifiers.indices.map { index in
            "related\(index): search(query: $search\(index), type: ISSUE, first: \(searchSize)) "
                + "{ nodes { ... on PullRequest { \(fields) } } }"
        }
        return Request(
            query: "query(\(declarations)) { \(searches.joined(separator: " ")) }",
            variables: .searches(qualifiers.map { "repo:\(nameWithOwner) is:pr is:open \($0)" })
        )
    }

    // MARK: Decoding

    /// A search's non-PR results decode as empty objects, so every field is
    /// optional.
    private struct Node: Decodable {
        let number: Int?
        let title: String?
        let url: String?
        let state: String?
        let isDraft: Bool?
        let updatedAt: Date?
        let reviewDecision: String?
        let reviewRequests: GitHubPRNode.Count?
        let latestReviews: GitHubPRNode.Count?
        let commits: GitHubPRNode.Commits?

        var entry: MentionCandidate.PullRequestEntry? {
            guard let number, let url, let state = PullRequestState(rawValue: state ?? "") else { return nil }
            let contexts = CheckContext.latestRuns(
                (commits?.nodes?.first?.commit?.statusCheckRollup?.contexts?.nodes ?? []).map(\.checkContext)
            )
            return .init(
                number: number,
                title: title ?? "",
                url: url,
                state: state,
                isDraft: isDraft ?? false,
                updatedAt: updatedAt,
                reviewDecision: ReviewDecision(rawValue: reviewDecision),
                hasReviewers: (reviewRequests?.totalCount ?? 0) + (latestReviews?.totalCount ?? 0) > 0,
                checkContexts: contexts
            )
        }
    }

    private struct Nodes: Decodable { let nodes: [Node?]? }

    private struct ListPayload: Decodable {
        struct Repository: Decodable {
            let nameWithOwner: String?
            let pullRequests: Nodes?
        }
        let repository: Repository?
    }

    private struct NumberPayload: Decodable {
        struct Repository: Decodable { let pullRequest: Node? }
        let repository: Repository?
    }

    private struct AliasedPayload: Decodable {
        let repository: [String: Node?]?
    }

    private struct SearchPayload: Decodable {
        let search: Nodes?
    }

    private struct Envelope<Payload: Decodable>: Decodable {
        let data: Payload?
    }

    private static func decode<Payload: Decodable>(_ type: Payload.Type, from data: Data) throws -> Payload? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Envelope<Payload>.self, from: data).data
    }

    static func decodeOpenPullRequests(
        _ data: Data
    ) throws -> (nameWithOwner: String?, pulls: [MentionCandidate.PullRequestEntry]) {
        let repository = try decode(ListPayload.self, from: data)?.repository
        let pulls = (repository?.pullRequests?.nodes ?? []).compactMap { $0?.entry }
        return (repository?.nameWithOwner, pulls)
    }

    static func decodePullRequest(_ data: Data) throws -> MentionCandidate.PullRequestEntry? {
        try decode(NumberPayload.self, from: data)?.repository?.pullRequest?.entry
    }

    /// The entry for each requested number GitHub found. A number left out has
    /// no such pull request, or its repository isn't visible.
    static func decodePullRequests(_ data: Data, numbers: [Int]) throws -> [Int: MentionCandidate.PullRequestEntry] {
        guard let repository = try decode(AliasedPayload.self, from: data)?.repository else { return [:] }
        var entries: [Int: MentionCandidate.PullRequestEntry] = [:]
        for number in numbers {
            if let node = repository["p\(number)"] ?? nil, let entry = node.entry { entries[number] = entry }
        }
        return entries
    }

    /// Every aliased search's pull requests, each once, most recently updated
    /// first.
    static func decodeRelatedPullRequests(_ data: Data) throws -> [MentionCandidate.PullRequestEntry] {
        let searches = try decode([String: Nodes?].self, from: data) ?? [:]
        var seen = Set<Int>()
        let pulls = searches.keys.sorted()
            .flatMap { (searches[$0] ?? nil)?.nodes ?? [] }
            .compactMap { $0?.entry }
            .filter { seen.insert($0.number).inserted }
        return pulls.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
    }

    static func decodeSearch(_ data: Data) throws -> [MentionCandidate.PullRequestEntry] {
        (try decode(SearchPayload.self, from: data)?.search?.nodes ?? []).compactMap { $0?.entry }
    }
}
