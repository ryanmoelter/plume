import Foundation

/// Linear's fixed workflow categories. Every team names its own states, but
/// each one belongs to exactly one of these, which is what lets Plume tell
/// "In Progress" from "In Review" without knowing either name.
nonisolated enum LinearStateType: Sendable, Equatable, Hashable, Codable {
    case triage
    case backlog
    case unstarted
    case started
    case completed
    case canceled
    case other(String)

    init(rawValue: String) {
        switch rawValue.lowercased() {
        case "triage": self = .triage
        case "backlog": self = .backlog
        case "unstarted": self = .unstarted
        case "started": self = .started
        case "completed": self = .completed
        case "canceled", "cancelled": self = .canceled
        default: self = .other(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .triage: "triage"
        case .backlog: "backlog"
        case .unstarted: "unstarted"
        case .started: "started"
        case .completed: "completed"
        case .canceled: "canceled"
        case .other(let raw): raw
        }
    }

    init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

nonisolated struct LinearWorkflowState: Sendable, Equatable, Hashable, Codable {
    let id: String
    let name: String
    let type: LinearStateType
    /// A `#rrggbb` hex string, as Linear reports it.
    let color: String
}

nonisolated struct LinearTeam: Sendable, Equatable, Codable {
    let id: String
    /// The uppercase identifier prefix, `PLUME` in `PLUME-102`.
    let key: String
    let name: String
    let states: [LinearWorkflowState]
}

/// One workspace's teams and their workflow states. Small and slow-changing,
/// so it is cached on disk and refreshed rarely.
nonisolated struct LinearCatalog: Sendable, Equatable, Codable {
    let orgID: String
    let teams: [LinearTeam]
    let fetchedAt: Date

    var teamKeys: Set<String> { Set(teams.map(\.key)) }

    func team(key: String) -> LinearTeam? {
        teams.first { $0.key == key.uppercased() }
    }
}

/// A connected Linear workspace. The API key lives in Keychain under
/// `orgID`; this metadata lives in UserDefaults.
nonisolated struct LinearAccount: Sendable, Equatable, Hashable, Codable, Identifiable {
    let orgID: String
    let orgName: String
    /// The workspace's URL slug, `plume-term` in `linear.app/plume-term/…`.
    let urlKey: String
    let viewerName: String

    var id: String { orgID }
}

nonisolated struct LinearIssue: Sendable, Equatable {
    let identifier: String
    let title: String
    let url: String
    let stateName: String
    let stateType: LinearStateType
    let stateColor: String
    let assigneeName: String?
    let teamKey: String
}

/// What an issue line knows right now. An enum rather than an optional for the
/// same reason as `PullRequestFetchState`: offline must never read as "no
/// such issue".
nonisolated enum LinearIssueFetchState: Sendable, Equatable {
    case issue(LinearIssue)
    /// The last refresh failed; this is the last good answer.
    case stale(LinearIssue, reason: String)
    case loading
    /// The owning workspace answered and has no such issue.
    case notFound
    /// No connected workspace has this issue's team key.
    case noWorkspace
    case failed(String)
    case unauthorized
    case rateLimited(until: Date)

    var issue: LinearIssue? {
        switch self {
        case .issue(let issue), .stale(let issue, _): issue
        default: nil
        }
    }
}

nonisolated enum LinearError: LocalizedError, Equatable {
    case unauthorized
    case rateLimited(until: Date)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized: "Linear rejected the API key."
        case .rateLimited(let until): "Linear rate limit reached until \(until.formatted(date: .omitted, time: .shortened))."
        case .failed(let message): message
        }
    }
}

extension LinearIssueFetchState {
    static func failing(_ error: any Error) -> LinearIssueFetchState {
        switch error as? LinearError {
        case .unauthorized: .unauthorized
        case .rateLimited(let until): .rateLimited(until: until)
        case .failed(let message): .failed(message)
        case nil: .failed(error.localizedDescription)
        }
    }
}

/// Linear's budget for one API key, from the `X-RateLimit-Requests-*` headers.
nonisolated struct LinearRateLimit: Sendable, Equatable {
    let limit: Int
    let remaining: Int
    let resetAt: Date
}

/// A link persisted on a task. `orgID` is nil until the identifier has been
/// routed to a workspace once.
nonisolated struct LinearIssueRef: Sendable, Equatable, Hashable, Codable {
    var orgID: String?
    let identifier: String

    init(orgID: String? = nil, identifier: String) {
        self.orgID = orgID
        self.identifier = identifier.uppercased()
    }
}

nonisolated struct LinearSubagentRef: Sendable, Equatable, Hashable {
    let id: String
    let label: String
}

/// Where a tool call stands, from its result.
nonisolated enum LinearCallOutcome: Sendable, Equatable, Hashable {
    /// The call has no result yet, so a write may not have landed.
    case pending
    case succeeded
    case failed
}

/// One Linear tool call an agent made, reduced to what classification needs.
nonisolated struct LinearEvidence: Sendable, Equatable, Hashable {
    let identifier: String
    /// The MCP tool's own name, `save_issue` in `mcp__linear__save_issue`.
    let tool: String
    /// The `state` a `save_issue` call asked for: a name, a type or an id.
    let requestedState: String?
    let subagent: LinearSubagentRef?
    let outcome: LinearCallOutcome

    var isWrite: Bool { tool == "save_issue" || tool == "update_issue" }
}

nonisolated enum LinearLinkRole: Sendable, Equatable, Comparable {
    case working
    case mentioned
}

/// Why an issue is linked. Declaration order is display order.
nonisolated enum LinearLinkSource: Sendable, Equatable, Hashable, Comparable {
    case manual
    case branch
    case promoted
    case agentStarted
    case agent
    /// The user unlinked it, which overrides every other source.
    case unlinked
}

/// One issue as a task shows it, after every source has been folded together.
nonisolated struct LinkedLinearIssue: Sendable, Equatable, Identifiable {
    let identifier: String
    let role: LinearLinkRole
    let sources: Set<LinearLinkSource>
    /// Subagents that touched the issue, in first-seen order.
    let subagents: [LinearSubagentRef]
    let touchedByMainAgent: Bool

    var id: String { identifier }
}
