import Foundation

/// One workspace's local copy of its issues, workflow states and users, each
/// keyed by Linear id, plus the `updatedAt` cursor the next delta sync starts
/// from. A value type with no I/O; `LinearStore` owns it and `LinearCacheDisk`
/// persists it. `docs/linear-sync.md` has the design.
///
/// Every issue held here is current as of the cursor: an incomplete delta
/// drops what it could not vouch for rather than keep it unverified.
nonisolated struct LinearSyncCache: Sendable, Equatable, Codable {
    static let formatVersion = 1
    /// How far before the cursor each delta starts. A write that commits late
    /// with an earlier `updatedAt` still lands inside the next query; ids
    /// dedupe the rows seen twice.
    static let overlap: TimeInterval = 30
    /// What the first sync of a workspace backfills.
    static let backfillWindow: TimeInterval = 14 * 24 * 60 * 60
    /// Issues no one references are dropped once untouched this long.
    static let retention: TimeInterval = 30 * 24 * 60 * 60

    nonisolated struct Issue: Sendable, Equatable, Codable {
        let id: String
        let identifier: String
        let title: String
        let url: String
        let updatedAt: Date
        let archivedAt: Date?
        let stateID: String
        let assigneeID: String?
        let teamID: String
        let teamKey: String
        /// Read only when the state is missing from `states`.
        let fallbackState: LinearWorkflowState
    }

    private(set) var formatVersion = LinearSyncCache.formatVersion
    let orgID: String
    private(set) var cursor: Date?
    private(set) var issues: [String: Issue] = [:]
    private(set) var states: [String: LinearWorkflowState] = [:]
    private(set) var users: [String: LinearUser] = [:]
    /// Identifiers an issue answered to before it moved teams, to its id.
    private(set) var aliases: [String: String] = [:]
    private var idByIdentifier: [String: String] = [:]

    private enum CodingKeys: String, CodingKey {
        case formatVersion, orgID, cursor, issues, states, users, aliases
    }

    init(orgID: String) {
        self.orgID = orgID
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        orgID = try container.decode(String.self, forKey: .orgID)
        cursor = try container.decodeIfPresent(Date.self, forKey: .cursor)
        issues = try container.decode([String: Issue].self, forKey: .issues)
        states = try container.decode([String: LinearWorkflowState].self, forKey: .states)
        users = try container.decode([String: LinearUser].self, forKey: .users)
        aliases = try container.decode([String: String].self, forKey: .aliases)
        rebuildIndex()
    }

    // MARK: Reading

    var isEmpty: Bool { issues.isEmpty && cursor == nil }

    func issueID(identifier: String) -> String? {
        let key = identifier.uppercased()
        return idByIdentifier[key] ?? aliases[key].flatMap { issues[$0] == nil ? nil : $0 }
    }

    func issue(identifier: String) -> LinearIssue? {
        guard let id = issueID(identifier: identifier), let issue = issues[id] else { return nil }
        let state = states[issue.stateID] ?? issue.fallbackState
        return LinearIssue(
            identifier: issue.identifier,
            title: issue.title,
            url: issue.url,
            stateName: state.name,
            stateType: state.type,
            stateColor: state.color,
            assigneeName: issue.assigneeID.flatMap { users[$0]?.name },
            teamKey: issue.teamKey
        )
    }

    /// Where the next delta query starts.
    func deltaLowerBound(now: Date) -> Date {
        cursor.map { $0.addingTimeInterval(-Self.overlap) } ?? now.addingTimeInterval(-Self.backfillWindow)
    }

    // MARK: Writing

    /// Applies one issue. An older snapshot than the one held is ignored, and
    /// a trashed one removes the issue. `requestedAs` records the identifier a
    /// lookup asked for, so a moved issue still answers to it.
    mutating func upsert(_ snapshot: LinearIssueSnapshot, requestedAs: String? = nil) {
        if let held = issues[snapshot.id], held.updatedAt > snapshot.updatedAt {
            recordAlias(requestedAs, id: snapshot.id)
            return
        }
        if snapshot.isTrashed {
            removeIssue(id: snapshot.id)
            return
        }
        let identifier = snapshot.issue.identifier.uppercased()
        if let held = issues[snapshot.id], held.identifier != identifier {
            idByIdentifier.removeValue(forKey: held.identifier)
            aliases[held.identifier] = snapshot.id
        }
        if let displaced = idByIdentifier[identifier], displaced != snapshot.id {
            removeIssue(id: displaced)
        }
        issues[snapshot.id] = Issue(
            id: snapshot.id,
            identifier: identifier,
            title: snapshot.issue.title,
            url: snapshot.issue.url,
            updatedAt: snapshot.updatedAt,
            archivedAt: snapshot.archivedAt,
            stateID: snapshot.state.id,
            assigneeID: snapshot.assignee?.id,
            teamID: snapshot.teamID,
            teamKey: snapshot.issue.teamKey.uppercased(),
            fallbackState: snapshot.state
        )
        idByIdentifier[identifier] = snapshot.id
        aliases.removeValue(forKey: identifier)
        states[snapshot.state.id] = snapshot.state
        if let assignee = snapshot.assignee { users[assignee.id] = assignee }
        recordAlias(requestedAs, id: snapshot.id)
    }

    /// A lookup by identifier found nothing, so whatever answered to it is gone.
    mutating func removeIssue(identifier: String) {
        guard let id = issueID(identifier: identifier) else {
            aliases.removeValue(forKey: identifier.uppercased())
            return
        }
        removeIssue(id: id)
    }

    /// Applies one delta sync. `complete` is false when the page cap stopped
    /// it early: the pages are newest first, so everything held that the delta
    /// did not cover may have missed an update and is dropped.
    mutating func applyDelta(_ snapshots: [LinearIssueSnapshot], complete: Bool, queriedFrom: Date) {
        if !complete {
            let covered = Set(snapshots.map(\.id))
            for id in issues.keys where !covered.contains(id) { removeIssue(id: id) }
        }
        for snapshot in snapshots { upsert(snapshot) }
        let newest = snapshots.map(\.updatedAt).max()
        cursor = [cursor ?? queriedFrom, newest].compactMap { $0 }.max()
    }

    mutating func install(_ catalog: LinearCatalog) {
        for team in catalog.teams {
            for state in team.states { states[state.id] = state }
        }
    }

    /// Drops issues untouched for `retention` that no identifier in `keeping`
    /// names, then any user no issue references.
    mutating func prune(keeping identifiers: Set<String>, now: Date) {
        let kept = Set(identifiers.compactMap { issueID(identifier: $0) })
        let horizon = now.addingTimeInterval(-Self.retention)
        for (id, issue) in issues where issue.updatedAt < horizon && !kept.contains(id) {
            removeIssue(id: id)
        }
        let referenced = Set(issues.values.compactMap(\.assigneeID))
        users = users.filter { referenced.contains($0.key) }
    }

    /// Folds in a copy read from disk after this one started filling. The
    /// newer of each issue wins, and this copy's cursor wins when it has one.
    mutating func absorb(_ other: LinearSyncCache) {
        guard other.orgID == orgID else { return }
        for (id, issue) in other.issues where (issues[id]?.updatedAt ?? .distantPast) < issue.updatedAt {
            if idByIdentifier[issue.identifier].map({ $0 != id }) ?? false { continue }
            if let held = issues[id] { idByIdentifier.removeValue(forKey: held.identifier) }
            issues[id] = issue
            idByIdentifier[issue.identifier] = id
        }
        for (key, id) in other.aliases where aliases[key] == nil && idByIdentifier[key] == nil {
            aliases[key] = id
        }
        states.merge(other.states) { mine, _ in mine }
        users.merge(other.users) { mine, _ in mine }
        if cursor == nil { cursor = other.cursor }
    }

    // MARK: Private

    private mutating func removeIssue(id: String) {
        guard let issue = issues.removeValue(forKey: id) else { return }
        if idByIdentifier[issue.identifier] == id { idByIdentifier.removeValue(forKey: issue.identifier) }
        aliases = aliases.filter { $0.value != id }
    }

    private mutating func recordAlias(_ requested: String?, id: String) {
        guard let key = requested?.uppercased(), idByIdentifier[key] == nil else { return }
        aliases[key] = id
    }

    private mutating func rebuildIndex() {
        idByIdentifier = Dictionary(issues.values.map { ($0.identifier, $0.id) }) { first, _ in first }
    }
}

/// The issues one delta sync fetched, newest first.
nonisolated struct LinearDelta: Sendable, Equatable {
    let issues: [LinearIssueSnapshot]
    /// False when `maxPages` ran out before the last page.
    let isComplete: Bool

    static func fetch(from client: LinearClient, since: Date, maxPages: Int) async throws -> LinearDelta {
        var issues: [LinearIssueSnapshot] = []
        var cursor: String?
        for _ in 0..<maxPages {
            let page = try await client.fetchIssuesUpdated(since: since, cursor: cursor)
            issues += page.issues
            cursor = page.nextCursor
            if cursor == nil { return LinearDelta(issues: issues, isComplete: true) }
        }
        return LinearDelta(issues: issues, isComplete: false)
    }
}
