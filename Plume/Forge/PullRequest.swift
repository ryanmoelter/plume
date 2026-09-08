import Foundation

/// One CI check on a pull request, flattened from whatever shape its forge
/// reports. GitHub's rollup mixes `StatusContext` (context/state) and
/// `CheckRun` (name/conclusion/status); both reduce to a name and an
/// uppercased status here.
nonisolated struct CheckContext: Sendable, Equatable {
    let name: String
    let status: String

    init(name: String, status: String) {
        self.name = name
        self.status = status.uppercased()
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
        status: String? = nil
    ) {
        self.init(
            name: name ?? context ?? "",
            status: conclusion ?? state ?? status ?? ""
        )
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
nonisolated enum ReviewDecision: Sendable, Equatable {
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
    let checkContexts: [CheckContext]

    init(
        number: Int,
        state: PullRequestState,
        isDraft: Bool,
        url: String? = nil,
        title: String? = nil,
        baseRefName: String? = nil,
        headRefOid: String? = nil,
        reviewDecision: ReviewDecision = .none,
        checkContexts: [CheckContext] = []
    ) {
        self.number = number
        self.state = state
        self.isDraft = isDraft
        self.url = url
        self.title = title
        self.baseRefName = baseRefName
        self.headRefOid = headRefOid
        self.reviewDecision = reviewDecision
        self.checkContexts = checkContexts
    }
}
