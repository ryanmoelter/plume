#if DEBUG
import Foundation

/// One row worth of fake sidebar data: a task with this status, this
/// directory, and (if any) this PR state.
///
/// Pure data, no SwiftData and no store — `SidebarFixtures` is what turns a
/// catalog into a seeded task. Keeping this pure is what makes the catalog's
/// completeness testable without a model context.
nonisolated struct SidebarFixtureCase: Equatable {
    let name: String
    let status: TaskStatus
    /// Distinct per case so each renders under its own directory name in the
    /// sidebar, and so `PullRequestStore` fixture state never collides across
    /// cases sharing a task.
    let directory: String
    let branch: String?
    let pullRequestState: PullRequestFetchState?
    /// Nil renders as a plain directory, which is also the pre-lookup state
    /// every real row passes through.
    let checkout: CheckoutFacts?

    init(
        name: String,
        status: TaskStatus,
        directory: String,
        branch: String?,
        pullRequestState: PullRequestFetchState?,
        checkout: CheckoutFacts? = nil
    ) {
        self.name = name
        self.status = status
        self.directory = directory
        self.branch = branch
        self.pullRequestState = pullRequestState
        self.checkout = checkout
    }
}

/// The fixed set of fake rows the DEBUG sidebar fixture button seeds.
///
/// A flat list of named cases rather than a hardcoded blob: adding a new kind
/// of row to check — a new `PullRequestFetchState`, a problematic chat
/// transcript — means appending a case here, not touching the seeding
/// plumbing in `SidebarFixtures`.
enum SidebarFixtureCatalog {
    /// A pull request in every review/check combination the chip draws
    /// differently. Draft, merged and closed intentionally leave checks and
    /// review off the fixture PR (`TaskRowDetails`/`PullRequestChip` don't
    /// draw them for those states), everything else pairs a review decision
    /// with a check rollup so both marks are visible in the same case.
    private static func pullRequest(
        number: Int,
        state: PullRequestState = .open,
        isDraft: Bool = false,
        reviewDecision: ReviewDecision = .none,
        checks: [CheckContext] = []
    ) -> PullRequest {
        PullRequest(
            number: number,
            state: state,
            isDraft: isDraft,
            url: "https://github.com/example/example/pull/\(number)",
            title: "Fixture PR #\(number)",
            baseRefName: "main",
            reviewDecision: reviewDecision,
            checkContexts: checks
        )
    }

    private static let passingChecks = [CheckContext(name: "build", conclusion: "SUCCESS")]
    private static let failingChecks = [CheckContext(name: "build", conclusion: "FAILURE")]
    private static let pendingChecks = [CheckContext(name: "build", status: "IN_PROGRESS")]

    /// Every case the fixture task seeds, in sidebar order.
    static let cases: [SidebarFixtureCase] = {
        var cases: [SidebarFixtureCase] = []
        var nextPRNumber = 100

        func addPullRequest(
            _ name: String,
            status: TaskStatus = .idle,
            state: PullRequestState = .open,
            isDraft: Bool = false,
            reviewDecision: ReviewDecision = .none,
            checks: [CheckContext] = []
        ) {
            let pr = pullRequest(
                number: nextPRNumber,
                state: state,
                isDraft: isDraft,
                reviewDecision: reviewDecision,
                checks: checks
            )
            nextPRNumber += 1
            cases.append(SidebarFixtureCase(
                name: name,
                status: status,
                directory: "fixture-\(name)",
                branch: "ryanm/\(name)",
                pullRequestState: .pullRequest(pr)
            ))
        }

        func addState(_ name: String, status: TaskStatus = .idle, _ state: PullRequestFetchState?) {
            cases.append(SidebarFixtureCase(
                name: name,
                status: status,
                directory: "fixture-\(name)",
                branch: state == nil ? nil : "ryanm/\(name)",
                pullRequestState: state
            ))
        }

        // PR checks/review combinations, open state.
        addPullRequest("checks-passing", checks: passingChecks)
        addPullRequest("checks-failing", checks: failingChecks)
        addPullRequest("checks-pending", checks: pendingChecks)
        addPullRequest("no-checks")
        addPullRequest("approved", reviewDecision: .approved, checks: passingChecks)
        addPullRequest("changes-requested", reviewDecision: .changesRequested, checks: failingChecks)
        addPullRequest("draft", isDraft: true)
        addPullRequest("merged", state: .merged)
        addPullRequest("closed", state: .closed)

        // Every other `PullRequestFetchState` case. `.noPR` and `.localOnly`
        // and `.loading` render no row today — seeded anyway, so "renders
        // nothing" is itself checkable rather than assumed.
        addState("no-pr", .noPR)
        addState("local-only", .localOnly)
        addState("loading", .loading)
        addState("timed-out", .timedOut)
        addState("failed", .failed("Fixture: forge unreachable"))
        addState("forge-unsupported", .forgeUnsupported)

        // The worktree marker, and the header naming a project rather than a
        // folder. Two worktrees of one project sit next to each other so the
        // shared header is visible as a repetition, not just as a label.
        let project = "/tmp/plume-fixtures/projects/Notability"
        for name in ["worktree-one", "worktree-two"] {
            cases.append(SidebarFixtureCase(
                name: name,
                status: .idle,
                directory: "worktrees/\(name)",
                branch: "ryanm/\(name)",
                pullRequestState: .noPR,
                checkout: CheckoutFacts(
                    projectRoot: project,
                    checkoutRoot: "/tmp/plume-fixtures/worktrees/\(name)"
                )
            ))
        }
        cases.append(SidebarFixtureCase(
            name: "main-checkout",
            status: .idle,
            directory: "projects/Notability",
            branch: "main",
            pullRequestState: .noPR,
            checkout: CheckoutFacts(projectRoot: project, checkoutRoot: project)
        ))

        // Every `TaskStatus`, paired with a plain no-PR row so the status
        // badge is the only thing varying.
        for status in TaskStatus.allCases {
            let name = "status-\(status.rawValue)"
            cases.append(SidebarFixtureCase(
                name: name,
                status: status,
                directory: "fixture-\(name)",
                branch: "ryanm/\(name)",
                pullRequestState: .noPR
            ))
        }

        return cases
    }()

    /// Cases already covered by `cases`, keyed the same way a completeness
    /// test would check them — every `PullRequestFetchState` case name and
    /// every `TaskStatus` covered at least once.
    static var coveredPullRequestFetchStateCases: Set<String> {
        Set(cases.compactMap { $0.pullRequestState.map(pullRequestFetchStateCaseName) })
    }

    static var coveredTaskStatuses: Set<TaskStatus> {
        Set(cases.map(\.status))
    }

    /// A stable name per `PullRequestFetchState` case, ignoring associated
    /// values — this is deliberately not `Hashable`/`CaseIterable` on the enum
    /// itself, so this is the seam a completeness test hangs off.
    static func pullRequestFetchStateCaseName(_ state: PullRequestFetchState) -> String {
        switch state {
        case .pullRequest: "pullRequest"
        case .noPR: "noPR"
        case .localOnly: "localOnly"
        case .loading: "loading"
        case .timedOut: "timedOut"
        case .failed: "failed"
        case .forgeUnsupported: "forgeUnsupported"
        }
    }

    /// Every case name `PullRequestFetchState` has today, for the
    /// completeness test to compare `coveredPullRequestFetchStateCases`
    /// against. Not `CaseIterable` itself (it carries associated values), so
    /// this list is the thing that must be kept in sync by hand — a mismatch
    /// here is exactly what the test is for.
    static let allPullRequestFetchStateCaseNames: Set<String> = [
        "pullRequest", "noPR", "localOnly", "loading", "timedOut", "failed", "forgeUnsupported",
    ]
}
#endif
