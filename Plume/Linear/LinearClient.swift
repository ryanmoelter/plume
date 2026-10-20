import Foundation

nonisolated protocol LinearClient: Sendable {
    func fetchViewer() async throws -> LinearAccount
    func fetchCatalog() async throws -> LinearCatalog
    /// Keyed by uppercased identifier.
    func fetchIssues(_ identifiers: [String]) async throws -> [String: LinearIssueLookup]
}

/// One workspace's answer for one identifier in a batch.
nonisolated enum LinearIssueLookup: Sendable, Equatable {
    case found(LinearIssue)
    /// The workspace answered and has no such issue.
    case notFound
    /// The workspace reported an error for this issue alone.
    case failed(String)
}

nonisolated enum LinearQuery {
    static let chunkSize = 50

    static let viewerQuery = "query { viewer { name displayName } organization { id name urlKey } }"

    static let catalogQuery = """
        query { organization { id } teams(first: 100) { nodes { id key name \
        states(first: 100) { nodes { id name type color } } } } }
        """

    private static let issueFields = """
        identifier title url state { name type color } \
        assignee { displayName name } team { key }
        """

    static func chunks(of identifiers: [String]) -> [[String]] {
        stride(from: 0, to: identifiers.count, by: chunkSize).map {
            Array(identifiers[$0..<min($0 + chunkSize, identifiers.count)])
        }
    }

    static func buildIssues(identifiers: [String]) -> (query: String, aliasToIdentifier: [String: String]) {
        var fields: [String] = []
        var aliasToIdentifier: [String: String] = [:]
        for (index, identifier) in identifiers.enumerated() {
            let alias = "i\(index)"
            aliasToIdentifier[alias] = identifier
            fields.append("\(alias): issue(id: \(jsonString(identifier))) { \(issueFields) }")
        }
        return ("query { " + fields.joined(separator: " ") + " }", aliasToIdentifier)
    }

    static func requestBody(query: String) throws -> Data {
        try JSONEncoder().encode(["query": query])
    }

    /// A GraphQL string literal, via the encoder so every escape is correct.
    static func jsonString(_ value: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8)
        else { return "\"\"" }
        return string
    }

    // MARK: Decoding

    private struct GraphQLError: Decodable {
        struct Extensions: Decodable { let code: String? }
        let message: String?
        let path: [PathElement]?
        let extensions: Extensions?
    }

    private enum PathElement: Decodable {
        case key(String)
        case index(Int)

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self) {
                self = .key(string)
            } else {
                self = .index(try container.decode(Int.self))
            }
        }
    }

    private struct Envelope<Payload: Decodable>: Decodable {
        let data: Payload?
        let errors: [GraphQLError]?
    }

    private struct ErrorsOnly: Decodable {
        let errors: [GraphQLError]?
    }

    private struct ViewerPayload: Decodable {
        struct Viewer: Decodable { let name: String?; let displayName: String? }
        struct Organization: Decodable { let id: String; let name: String; let urlKey: String }
        let viewer: Viewer
        let organization: Organization
    }

    private struct CatalogPayload: Decodable {
        struct Organization: Decodable { let id: String }
        struct StateNodes: Decodable { let nodes: [LinearWorkflowState] }
        struct Team: Decodable {
            let id: String
            let key: String
            let name: String
            let states: StateNodes
        }
        struct Teams: Decodable { let nodes: [Team] }
        let organization: Organization
        let teams: Teams
    }

    private struct IssueNode: Decodable {
        struct State: Decodable { let name: String; let type: LinearStateType; let color: String }
        struct Assignee: Decodable { let displayName: String?; let name: String? }
        struct Team: Decodable { let key: String }
        let identifier: String
        let title: String
        let url: String
        let state: State
        let assignee: Assignee?
        let team: Team
    }

    private struct DynamicKey: CodingKey {
        let stringValue: String
        init?(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { nil }
    }

    /// Issue nodes by alias. A null or absent alias decodes to nil.
    private struct IssuesPayload: Decodable {
        let nodes: [String: IssueNode?]

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)
            var nodes: [String: IssueNode?] = [:]
            for key in container.allKeys {
                nodes[key.stringValue] = try container.decodeIfPresent(IssueNode.self, forKey: key)
            }
            self.nodes = nodes
        }
    }

    private static func decodeEnvelope<Payload: Decodable>(
        _ type: Payload.Type,
        from data: Data
    ) throws -> Envelope<Payload> {
        do {
            return try JSONDecoder().decode(Envelope<Payload>.self, from: data)
        } catch {
            throw LinearError.failed("Linear sent a response Plume could not read.")
        }
    }

    /// Whether `data` is a GraphQL response carrying errors. Linear sends
    /// those with HTTP 400, not 200.
    static func hasErrors(_ data: Data) -> Bool {
        guard let body = try? JSONDecoder().decode(ErrorsOnly.self, from: data) else { return false }
        return !(body.errors ?? []).isEmpty
    }

    /// Linear names a missing issue with `INVALID_INPUT` and an "Entity not
    /// found" message, so the message is checked as well as the code.
    private static func isNotFound(_ error: GraphQLError) -> Bool {
        error.extensions?.code == "ENTITY_NOT_FOUND"
            || (error.message?.localizedCaseInsensitiveContains("not found") ?? false)
    }

    private static func alias(of error: GraphQLError) -> String? {
        guard case .key(let alias)? = error.path?.first else { return nil }
        return alias
    }

    /// Throws for any error that is not scoped to one of `allowedAliases`.
    private static func check(
        _ errors: [GraphQLError]?,
        allowedAliases: Set<String> = [],
        now: Date
    ) throws {
        for error in errors ?? [] {
            let code = error.extensions?.code
            switch code {
            case "AUTHENTICATION_ERROR": throw LinearError.unauthorized
            case "RATELIMITED": throw LinearError.rateLimited(until: now.addingTimeInterval(60))
            default: break
            }
            if let alias = alias(of: error), allowedAliases.contains(alias) { continue }
            throw LinearError.failed(error.message ?? "Linear returned an error.")
        }
    }

    static func decodeViewer(_ data: Data, now: Date = Date()) throws -> LinearAccount {
        let envelope = try decodeEnvelope(ViewerPayload.self, from: data)
        try check(envelope.errors, now: now)
        guard let payload = envelope.data else { throw LinearError.failed("Linear returned no data.") }
        let name = payload.viewer.displayName ?? payload.viewer.name ?? ""
        return LinearAccount(
            orgID: payload.organization.id,
            orgName: payload.organization.name,
            urlKey: payload.organization.urlKey,
            viewerName: name
        )
    }

    static func decodeCatalog(_ data: Data, now: Date = Date()) throws -> LinearCatalog {
        let envelope = try decodeEnvelope(CatalogPayload.self, from: data)
        try check(envelope.errors, now: now)
        guard let payload = envelope.data else { throw LinearError.failed("Linear returned no data.") }
        let teams = payload.teams.nodes.map {
            LinearTeam(id: $0.id, key: $0.key.uppercased(), name: $0.name, states: $0.states.nodes)
        }
        return LinearCatalog(orgID: payload.organization.id, teams: teams, fetchedAt: now)
    }

    /// Keyed by the requested identifier, not the one Linear returns, so a
    /// renamed team's old identifier still lands on its own key.
    static func decodeIssues(
        _ data: Data,
        aliasToIdentifier: [String: String],
        now: Date = Date()
    ) throws -> [String: LinearIssueLookup] {
        let envelope = try decodeEnvelope(IssuesPayload.self, from: data)
        try check(envelope.errors, allowedAliases: Set(aliasToIdentifier.keys), now: now)
        let nodes = envelope.data?.nodes ?? [:]
        let errorsByAlias = Dictionary(grouping: envelope.errors ?? []) { alias(of: $0) ?? "" }
        var result: [String: LinearIssueLookup] = [:]
        for (alias, identifier) in aliasToIdentifier {
            let key = identifier.uppercased()
            if let node = nodes[alias] ?? nil {
                result[key] = .found(LinearIssue(
                    identifier: node.identifier,
                    title: node.title,
                    url: node.url,
                    stateName: node.state.name,
                    stateType: node.state.type,
                    stateColor: node.state.color,
                    assigneeName: node.assignee?.displayName ?? node.assignee?.name,
                    teamKey: node.team.key
                ))
            } else if let failure = errorsByAlias[alias]?.first(where: { !isNotFound($0) }) {
                result[key] = .failed(failure.message ?? "Linear returned an error.")
            } else {
                result[key] = .notFound
            }
        }
        return result
    }
}

/// Talks to Linear's GraphQL API. The key is read per request from
/// `apiKey` and never stored. `onRateLimit` fires after each response whose
/// headers carry a complete rate-limit triple.
nonisolated struct LinearGraphQLClient: LinearClient {
    static let endpoint = URL(string: "https://api.linear.app/graphql")!

    let apiKey: @Sendable () -> String?
    let session: URLSession
    let onRateLimit: @Sendable (LinearRateLimit) -> Void

    init(
        apiKey: @escaping @Sendable () -> String?,
        session: URLSession = .shared,
        onRateLimit: @escaping @Sendable (LinearRateLimit) -> Void = { _ in }
    ) {
        self.apiKey = apiKey
        self.session = session
        self.onRateLimit = onRateLimit
    }

    func fetchViewer() async throws -> LinearAccount {
        try await send(LinearQuery.viewerQuery) { try LinearQuery.decodeViewer($0) }
    }

    func fetchCatalog() async throws -> LinearCatalog {
        try await send(LinearQuery.catalogQuery) { try LinearQuery.decodeCatalog($0) }
    }

    func fetchIssues(_ identifiers: [String]) async throws -> [String: LinearIssueLookup] {
        var unique: [String] = []
        var seen = Set<String>()
        for identifier in identifiers.map({ $0.uppercased() }) where seen.insert(identifier).inserted {
            unique.append(identifier)
        }
        var result: [String: LinearIssueLookup] = [:]
        for chunk in LinearQuery.chunks(of: unique) {
            let (query, aliases) = LinearQuery.buildIssues(identifiers: chunk)
            let lookups = try await send(query) { try LinearQuery.decodeIssues($0, aliasToIdentifier: aliases) }
            result.merge(lookups) { $1 }
        }
        return result
    }

    /// A non-2xx response is decoded too when it carries GraphQL errors, so
    /// their codes and messages win over the bare status.
    private func send<Result>(_ query: String, decode: (Data) throws -> Result) async throws -> Result {
        guard let key = apiKey(), !key.isEmpty else { throw LinearError.unauthorized }
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try LinearQuery.requestBody(query: query)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw error
        } catch {
            throw LinearError.failed(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw LinearError.failed("Linear sent no HTTP response.")
        }
        if let rateLimit = Self.rateLimit(from: http) { onRateLimit(rateLimit) }
        do {
            if (200..<300).contains(http.statusCode) { return try decode(data) }
            guard LinearQuery.hasErrors(data) else { throw Self.statusError(http, message: nil) }
            do {
                return try decode(data)
            } catch LinearError.failed(let message) {
                throw Self.statusError(http, message: message)
            }
        } catch LinearError.rateLimited(let until) {
            throw LinearError.rateLimited(until: Self.resetDate(from: http) ?? until)
        }
    }

    private static func statusError(_ response: HTTPURLResponse, message: String?) -> LinearError {
        switch response.statusCode {
        case 401, 403: .unauthorized
        case 429: .rateLimited(until: resetDate(from: response) ?? Date().addingTimeInterval(60))
        default: .failed(message ?? "Linear returned HTTP \(response.statusCode).")
        }
    }

    static func resetDate(from response: HTTPURLResponse) -> Date? {
        guard let value = response.value(forHTTPHeaderField: "X-RateLimit-Requests-Reset"),
              let milliseconds = Double(value)
        else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }

    static func rateLimit(from response: HTTPURLResponse) -> LinearRateLimit? {
        guard let limit = response.value(forHTTPHeaderField: "X-RateLimit-Requests-Limit").flatMap({ Int($0) }),
              let remaining = response.value(forHTTPHeaderField: "X-RateLimit-Requests-Remaining").flatMap({ Int($0) }),
              let resetAt = resetDate(from: response)
        else { return nil }
        return LinearRateLimit(limit: limit, remaining: remaining, resetAt: resetAt)
    }
}
