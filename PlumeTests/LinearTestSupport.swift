import Foundation
@testable import Plume

/// One fake Linear workspace. Records every request so routing and batching
/// are assertable, and can hold issue fetches open to test the in-flight rule.
actor FakeLinearWorkspace {
    let account: LinearAccount
    var catalog: LinearCatalog
    var issues: [String: LinearIssue] = [:]
    /// Errors Linear scopes to one identifier's alias.
    var issueFailures: [String: String] = [:]
    var issueError: Error?
    var catalogError: Error?
    var viewerError: Error?
    /// Reported through `onRateLimit` after each issue fetch.
    var rateLimit: LinearRateLimit?
    private(set) var issueCalls: [[String]] = []
    private(set) var catalogCalls = 0
    private var holdsIssues = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(orgID: String, teamKeys: [String]) {
        account = LinearAccount(orgID: orgID, orgName: "Org \(orgID)", urlKey: orgID.lowercased(), viewerName: "Ryan")
        catalog = LinearCatalog(
            orgID: orgID,
            teams: teamKeys.map { LinearTestFixtures.team(key: $0) },
            fetchedAt: Date()
        )
    }

    func set(issues: [String: LinearIssue]) { self.issues = issues }
    func set(issueFailures: [String: String]) { self.issueFailures = issueFailures }
    func set(issueError: Error?) { self.issueError = issueError }
    func set(catalogError: Error?) { self.catalogError = catalogError }
    func set(viewerError: Error?) { self.viewerError = viewerError }
    func set(rateLimit: LinearRateLimit?) { self.rateLimit = rateLimit }

    func holdIssueFetches() { holdsIssues = true }

    func releaseIssueFetches() {
        holdsIssues = false
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }

    func viewer() throws -> LinearAccount {
        if let viewerError { throw viewerError }
        return account
    }

    func fetchCatalog() throws -> LinearCatalog {
        catalogCalls += 1
        if let catalogError { throw catalogError }
        return catalog
    }

    func fetchIssues(_ identifiers: [String]) async throws -> [String: LinearIssueLookup] {
        issueCalls.append(identifiers.sorted())
        if holdsIssues { await withCheckedContinuation { waiters.append($0) } }
        if let issueError { throw issueError }
        var result: [String: LinearIssueLookup] = [:]
        for identifier in identifiers {
            if let issue = issues[identifier] {
                result[identifier] = .found(issue)
            } else if let failure = issueFailures[identifier] {
                result[identifier] = .failed(failure)
            } else {
                result[identifier] = .notFound
            }
        }
        return result
    }
}

nonisolated struct FakeLinearClient: LinearClient {
    let workspace: FakeLinearWorkspace
    let onRateLimit: @Sendable (LinearRateLimit) -> Void

    func fetchViewer() async throws -> LinearAccount { try await workspace.viewer() }
    func fetchCatalog() async throws -> LinearCatalog { try await workspace.fetchCatalog() }

    func fetchIssues(_ identifiers: [String]) async throws -> [String: LinearIssueLookup] {
        let result: [String: LinearIssueLookup]
        do {
            result = try await workspace.fetchIssues(identifiers)
        } catch {
            if let limit = await workspace.rateLimit { onRateLimit(limit) }
            throw error
        }
        if let limit = await workspace.rateLimit { onRateLimit(limit) }
        return result
    }
}

nonisolated enum LinearTestFixtures {
    static let startedState = LinearWorkflowState(id: "s-started", name: "In Progress", type: .started, color: "#f2c94c")
    static let todoState = LinearWorkflowState(id: "s-todo", name: "Todo", type: .unstarted, color: "#e2e2e2")

    static func team(key: String) -> LinearTeam {
        LinearTeam(id: "team-\(key)", key: key, name: key, states: [todoState, startedState])
    }

    static func issue(_ identifier: String, title: String = "An issue") -> LinearIssue {
        LinearIssue(
            identifier: identifier,
            title: title,
            url: "https://linear.app/x/issue/\(identifier)",
            stateName: "Todo",
            stateType: .unstarted,
            stateColor: "#e2e2e2",
            assigneeName: nil,
            teamKey: LinearIdentifier.teamKey(of: identifier)
        )
    }

    /// A factory that routes each API key to its fake workspace.
    static func factory(_ workspaces: [String: FakeLinearWorkspace]) -> LinearAccounts.ClientFactory {
        { apiKey, onRateLimit in
            let key = apiKey() ?? ""
            guard let workspace = workspaces[key] else { fatalError("No fake workspace for key \(key)") }
            return FakeLinearClient(workspace: workspace, onRateLimit: onRateLimit)
        }
    }

    static func scratchDefaults() -> UserDefaults {
        UserDefaults(suiteName: "LinearTests-\(UUID().uuidString)")!
    }
}
