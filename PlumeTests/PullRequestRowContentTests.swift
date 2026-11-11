import Foundation
import Testing
@testable import Plume

/// The info pane and sidebar draw a pull request as one status glyph, the
/// title, then whatever checks and review glyphs the status did not take.
struct PullRequestRowContentTests {
    private func pull(
        state: PullRequestState = .open,
        isDraft: Bool = false,
        review: ReviewDecision = .none,
        hasReviewers: Bool = false,
        checks: [CheckContext] = [],
        ignored: Set<String> = []
    ) -> PullRequestSummary {
        PullRequestSummary(
            number: 66032,
            title: "Sweep",
            state: state,
            isDraft: isDraft,
            reviewDecision: review,
            hasReviewers: hasReviewers,
            checkContexts: checks,
            ignoredChecks: ignored
        )
    }

    private let passing = [CheckContext(name: "build", status: "SUCCESS")]

    @Test func aDraftLeadsWithItsDraftMarkThenChecksAndReview() {
        let draft = pull(isDraft: true, review: .approved, checks: passing)
        #expect(PullRequestRowContent.leading(draft).label == "draft")
        #expect(PullRequestRowContent.trailing(draft).map(\.label) == ["checks pass", "approved"])
    }

    @Test func checksLeadWhenNotADraft() {
        let open = pull(review: .changesRequested, checks: passing)
        #expect(PullRequestRowContent.leading(open).label == "checks pass")
        #expect(PullRequestRowContent.trailing(open).map(\.label) == ["changes requested"])
    }

    @Test func reviewLeadsWithNoChecks() {
        let open = pull(review: .approved)
        #expect(PullRequestRowContent.leading(open).label == "approved")
        #expect(PullRequestRowContent.trailing(open).isEmpty)
    }

    @Test func anAssignedReviewerWithNoDecisionReadsAsWaiting() {
        let waiting = PullRequestRowContent.leading(pull(hasReviewers: true))
        #expect(waiting.symbol == "person.badge.clock")
        #expect(!waiting.isDim)
        #expect(PullRequestRowContent.leading(pull()).label == "open")
    }

    @Test func aFinishedPullRequestShowsOnlyItsOwnGlyph() {
        let merged = pull(state: .merged, isDraft: true, review: .approved, checks: passing)
        #expect(PullRequestRowContent.leading(merged).label == "merged")
        #expect(PullRequestRowContent.trailing(merged).isEmpty)
        #expect(PullRequestRowContent.detail(merged) == "#66032 · merged")
    }

    @Test func theDetailLineNamesNumberStateAndReview() {
        #expect(PullRequestRowContent.detail(pull(isDraft: true, hasReviewers: true, checks: passing)) == "#66032 · draft · awaiting review")
        #expect(PullRequestRowContent.detail(pull(review: .approved)) == "#66032 · open · approved")
        #expect(PullRequestRowContent.detail(pull(review: .changesRequested)) == "#66032 · open · changes requested")
        #expect(PullRequestRowContent.detail(pull()) == "#66032 · open")
        #expect(PullRequestRowContent.detail(pull(state: .merged, review: .approved)) == "#66032 · merged")
    }

    @Test func theInfoPaneLeadingGlyphIgnoresChecks() {
        #expect(PullRequestRowContent.leadingWithoutChecks(pull(checks: passing)).label == "open")
        #expect(PullRequestRowContent.leadingWithoutChecks(pull(isDraft: true, checks: passing)).label == "draft")
        #expect(PullRequestRowContent.leadingWithoutChecks(pull(review: .approved, checks: passing)).label == "approved")
    }

    @Test func theTooltipNamesForgeTitleStateAndReview() {
        var draft = pull(isDraft: true, hasReviewers: true)
        draft.title = "Make Sparkle the only updater"
        #expect(
            PullRequestRowContent.tooltip(draft, number: 12, forgeName: "GitHub")
                == "PR #12 on GitHub, Make Sparkle the only updater. Draft, awaiting review"
        )
        var merged = pull(state: .merged, review: .approved)
        merged.title = "Done"
        #expect(PullRequestRowContent.tooltip(merged, number: 3, forgeName: "GitLab") == "PR #3 on GitLab, Done. Merged")
        #expect(PullRequestRowContent.tooltip(nil, number: 3, forgeName: "GitHub") == "PR #3 on GitHub")
    }

    @Test func anIgnoredPendingCheckDoesNotHoldUpTheRollup() {
        let checks = passing + [CheckContext(name: "flaky", status: "PENDING")]
        #expect(pull(checks: checks).checkRollup == .pending)
        #expect(pull(checks: checks, ignored: ["flaky"]).checkRollup == .success)
    }

    @Test func aMentionEntryCarriesItsChecksAndReview() {
        var entry = MentionCandidate.PullRequestEntry(
            number: 4, title: "", url: "https://github.com/o/r/pull/4", state: .open, isDraft: false, updatedAt: nil
        )
        entry.reviewDecision = .approved
        entry.checkContexts = passing
        let summary = PullRequestSummary(entry)
        #expect(summary.title == nil)
        #expect(summary.checkRollup == .success)
        #expect(summary.reviewDecision == .approved)
    }
}

struct CheckListContentTests {
    private let contexts = [
        CheckContext(name: "lint", status: "SUCCESS"),
        CheckContext(name: "Build", status: "FAILURE"),
        CheckContext(name: "deploy", status: "IN_PROGRESS"),
        CheckContext(name: "docs", status: "SKIPPED"),
        CheckContext(name: "flaky", status: "QUEUED"),
        CheckContext(name: "audit", status: "SUCCESS"),
    ]

    @Test func failingComesFirstThenPendingPassedAndSkipped() {
        let entries = CheckListContent.entries(contexts, ignored: ["flaky"])
        #expect(entries.map(\.name) == ["Build", "deploy", "flaky", "audit", "lint", "docs"])
        #expect(entries.first { $0.name == "flaky" }?.isIgnored == true)
    }

    @Test func theSummaryCountsAnIgnoredPendingCheckAsIgnored() {
        let entries = CheckListContent.entries(contexts, ignored: ["flaky"])
        #expect(CheckListContent.summary(entries) == "1 failing, 1 pending, 2 passed, 1 skipped, 1 ignored")
    }

    @Test func anIgnoredPendingCheckDrawsDim() {
        let entry = CheckListEntry(name: "flaky", verdict: .pending, isIgnored: true)
        #expect(CheckListContent.glyph(for: entry).isDim)
        #expect(!CheckListContent.glyph(for: CheckListEntry(name: "x", verdict: .pending, isIgnored: false)).isDim)
    }

    @Test func verdictsMatchTheRollup() {
        #expect(CheckContext(name: "a", status: "CANCELLED").verdict == .skipped)
        #expect(CheckContext(name: "a", status: "TIMED_OUT").verdict == .failure)
        #expect(CheckContext(name: "a", status: "").verdict == .pending)
        #expect(CheckContext(name: "a", status: "success").verdict == .success)
    }
}

@MainActor
struct InfoPanePullRequestItemTests {
    private let pinned = PullRequestReference(owner: "o", repo: "r", number: 2)
    private let mentioned = PullRequestReference(owner: "o", repo: "r", number: 3)

    @Test func theBranchsOwnLeadsThenPinnedThenMentioned() {
        let branch = InfoPaneFacts.PullRequestFacts(
            state: .pullRequest(PullRequest(number: 1, state: .open, isDraft: false, url: "https://github.com/o/r/pull/1")),
            checkRollup: CheckRollup.none,
            forge: .github
        )
        let items = InfoPanePullRequestItem.items(
            branch: branch,
            linked: [
                .init(reference: mentioned, role: .mentioned),
                .init(reference: pinned, role: .pinned),
            ]
        )
        #expect(items.map(\.role) == [.branch, .pinned, .mentioned])
        #expect(items.map(\.number) == [1, 2, 3])
        #expect(items[0].reference == nil)
    }

    @Test func anUnansweredLinkedPullRequestReadsAsItsRepository() {
        let items = InfoPanePullRequestItem.items(branch: nil, linked: [.init(reference: pinned, role: .pinned)])
        #expect(items.first?.title == "o/r")
        #expect(items.first?.summary == nil)
    }

    @Test func aBranchWithoutAPullRequestTakesNoRow() {
        let branch = InfoPaneFacts.PullRequestFacts(state: .noPR, checkRollup: nil)
        #expect(InfoPanePullRequestItem.items(branch: branch, linked: []).isEmpty)
    }
}
