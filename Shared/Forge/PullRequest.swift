import Foundation

/// One CI check on a pull request, flattened from whatever shape its forge
/// reports. GitHub's rollup mixes `StatusContext` (context/state) and
/// `CheckRun` (name/conclusion/status); both reduce to a name and an
/// uppercased status here.
nonisolated struct CheckContext: Sendable, Hashable {
    let name: String
    let status: String
    /// When the run started, or the status was posted. Nil for a run still
    /// queued.
    let startedAt: Date?
    /// The check's own page: a check run's `detailsUrl`, or a status's
    /// `targetUrl`.
    let url: URL?

    init(name: String, status: String, startedAt: Date? = nil, url: URL? = nil) {
        self.name = name
        self.status = status.uppercased()
        self.startedAt = startedAt
        self.url = url
    }

    /// Flattens the two union members GitHub's rollup returns.
    ///
    /// `conclusion` is null while a check run is in progress, so falling
    /// through to `status` is what reports such a run as pending rather than
    /// as an empty status.
    init(
        context: String? = nil,
        state: String? = nil,
        name: String? = nil,
        conclusion: String? = nil,
        status: String? = nil,
        startedAt: String? = nil,
        url: String? = nil
    ) {
        self.init(
            name: name ?? context ?? "",
            status: conclusion ?? state ?? status ?? "",
            startedAt: startedAt.flatMap { try? Date.ISO8601FormatStyle().parse($0) },
            url: url.flatMap(URL.init(string:))
        )
    }

    /// One context per name, the most recent run of each, in the order each
    /// name first appears.
    ///
    /// A re-run adds a second check run under the same name on the same
    /// commit, and GitHub's rollup returns both. A run with no start time is
    /// still queued, so it counts as newer than any that started.
    static func latestRuns(_ contexts: [CheckContext]) -> [CheckContext] {
        var latest: [String: CheckContext] = [:]
        var order: [String] = []
        for context in contexts {
            guard let current = latest[context.name] else {
                latest[context.name] = context
                order.append(context.name)
                continue
            }
            if !context.startedBefore(current) { latest[context.name] = context }
        }
        return order.compactMap { latest[$0] }
    }

    private func startedBefore(_ other: CheckContext) -> Bool {
        switch (startedAt, other.startedAt) {
        case let (mine?, theirs?): mine < theirs
        case (_?, nil): true
        case (nil, _): false
        }
    }
}

nonisolated enum PullRequestState: String, Sendable, Equatable {
    case open = "OPEN"
    case merged = "MERGED"
    case closed = "CLOSED"
}

/// GitHub's `REVIEW_REQUIRED` and a null decision are the same fact to a
/// reader — nobody has weighed in yet — so both fold to `none` and show no
/// marker.
nonisolated enum ReviewDecision: Sendable, Hashable {
    case approved
    case changesRequested
    case none

    init(rawValue: String?) {
        switch rawValue {
        case "APPROVED": self = .approved
        case "CHANGES_REQUESTED": self = .changesRequested
        default: self = .none
        }
    }
}

/// A pull request's place in a GitHub native stack.
nonisolated struct GitHubStackMembership: Sendable, Equatable {
    let number: Int
    let size: Int?
    /// 1 at the bottom of the stack.
    let position: Int
}

/// A pull request in one shape, whichever forge it came from.
nonisolated struct PullRequest: Sendable, Equatable {
    let number: Int
    let state: PullRequestState
    let isDraft: Bool
    let url: String?
    let title: String?
    let baseRefName: String?
    let headRefOid: String?
    let reviewDecision: ReviewDecision
    /// Someone is requested or has reviewed, so a missing decision means
    /// waiting rather than nobody asked.
    let hasReviewers: Bool
    let checkContexts: [CheckContext]
    /// Nil off GitHub, outside a stack, or when the query didn't ask.
    let githubStack: GitHubStackMembership?

    init(
        number: Int,
        state: PullRequestState,
        isDraft: Bool,
        url: String? = nil,
        title: String? = nil,
        baseRefName: String? = nil,
        headRefOid: String? = nil,
        reviewDecision: ReviewDecision = .none,
        hasReviewers: Bool = false,
        checkContexts: [CheckContext] = [],
        githubStack: GitHubStackMembership? = nil
    ) {
        self.number = number
        self.state = state
        self.isDraft = isDraft
        self.url = url
        self.title = title
        self.baseRefName = baseRefName
        self.headRefOid = headRefOid
        self.reviewDecision = reviewDecision
        self.hasReviewers = hasReviewers
        self.checkContexts = checkContexts
        self.githubStack = githubStack
    }
}
