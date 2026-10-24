import Foundation
@testable import Plume

/// One fake Linear workspace. Records every request so routing and batching
/// are assertable, and can hold issue fetches open to test the in-flight rule.
/// Each issue gets a fresh `updatedAt` whenever `set(issues:)` changes it, so
/// delta syncs see exactly what changed.
actor FakeLinearWorkspace {
    let account: LinearAccount
    var catalog: LinearCatalog
    private(set) var snapshots: [String: LinearIssueSnapshot] = [:]
    var deltaPageSize = 100
    /// Errors Linear scopes to one identifier's alias.
    var issueFailures: [String: String] = [:]
    var issueError: Error?
    var catalogError: Error?
    var viewerError: Error?
    /// Reported through `onRateLimit` after each issue fetch.
    var rateLimit: LinearRateLimit?
    private(set) var issueCalls: [[String]] = []
    private(set) var deltaCalls: [Date] = []
    private var lastUpdatedAt = Date()
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

    /// Issues left out are deleted outright, which no delta reports.
    func set(issues: [String: LinearIssue]) {
        var next: [String: LinearIssueSnapshot] = [:]
        for (identifier, issue) in issues {
            if let held = snapshots[identifier], held.issue == issue, !held.isTrashed {
                next[identifier] = held
            } else {
                next[identifier] = LinearTestFixtures.snapshot(issue, updatedAt: tick())
            }
        }
        snapshots = next
    }

    func trash(_ identifier: String) {
        guard let held = snapshots[identifier] else { return }
        snapshots[identifier] = LinearTestFixtures.snapshot(held.issue, updatedAt: tick(), isTrashed: true)
    }

    func set(deltaPageSize: Int) { self.deltaPageSize = deltaPageSize }

    private func tick() -> Date {
        lastUpdatedAt = max(Date(), lastUpdatedAt.addingTimeInterval(1))
        return lastUpdatedAt
    }
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
            if let snapshot = snapshots[identifier], !snapshot.isTrashed {
                result[identifier] = .found(snapshot)
            } else if let failure = issueFailures[identifier] {
                result[identifier] = .failed(failure)
            } else {
                result[identifier] = .notFound
            }
        }
        return result
    }

    func fetchIssuesUpdated(since: Date, cursor: String?) throws -> LinearIssuePage {
        deltaCalls.append(since)
        if let issueError { throw issueError }
        let matching = snapshots.values
            .filter { $0.updatedAt >= since }
            .sorted { $0.updatedAt > $1.updatedAt }
        let start = cursor.flatMap { Int($0) } ?? 0
        let end = min(start + deltaPageSize, matching.count)
        return LinearIssuePage(
            issues: Array(matching[start..<end]),
            nextCursor: end < matching.count ? String(end) : nil
        )
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

    func fetchIssuesUpdated(since: Date, cursor: String?) async throws -> LinearIssuePage {
        try await workspace.fetchIssuesUpdated(since: since, cursor: cursor)
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

    /// The wire form of `issue`, with ids derived from its names so the cache
    /// resolves it back to an equal `LinearIssue`.
    static func snapshot(_ issue: LinearIssue, updatedAt: Date, isTrashed: Bool = false) -> LinearIssueSnapshot {
        LinearIssueSnapshot(
            id: "id-\(issue.identifier)",
            updatedAt: updatedAt,
            archivedAt: nil,
            isTrashed: isTrashed,
            state: LinearWorkflowState(
                id: "state-\(issue.stateName)", name: issue.stateName, type: issue.stateType, color: issue.stateColor),
            assignee: issue.assigneeName.map { LinearUser(id: "user-\($0)", name: $0) },
            teamID: "team-\(issue.teamKey)",
            issue: issue
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
