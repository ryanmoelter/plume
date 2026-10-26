import Foundation

/// The GraphQL queries behind `#` mentions, and their decoders.
nonisolated enum GitHubMentionQuery {
    static let listSize = 50
    static let searchSize = 10

    private static let fields = "number title url state isDraft updatedAt"

    /// A query and its variables. What the user typed travels only as a
    /// variable, sent with `-f`, which gh passes through as a plain string.
    struct Request: Equatable, Sendable {
        enum Variables: Equatable, Sendable {
            /// `$owner` and `$name`, filled from gh's `{owner}` and `{repo}`
            /// placeholders, which it resolves from its working directory.
            case repository
            case search(String)
        }

        let query: String
        let variables: Variables

        var arguments: [String] {
            var arguments = ["api", "graphql", "-f", "query=" + query]
            switch variables {
            case .repository: arguments += ["-F", "owner={owner}", "-F", "name={repo}"]
            case .search(let search): arguments += ["-f", "search=" + search]
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

    static func titleSearch(_ term: String, nameWithOwner: String) -> Request {
        Request(
            query: "query($search: String!) { search(query: $search, type: ISSUE, first: \(searchSize)) "
                + "{ nodes { ... on PullRequest { \(fields) } } } }",
            variables: .search("repo:\(nameWithOwner) is:pr in:title \(term)")
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

        var entry: MentionCandidate.PullRequestEntry? {
            guard let number, let url, let state = PullRequestState(rawValue: state ?? "") else { return nil }
            return .init(
                number: number,
                title: title ?? "",
                url: url,
                state: state,
                isDraft: isDraft ?? false,
                updatedAt: updatedAt
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

    static func decodeSearch(_ data: Data) throws -> [MentionCandidate.PullRequestEntry] {
        (try decode(SearchPayload.self, from: data)?.search?.nodes ?? []).compactMap { $0?.entry }
    }
}
