import Testing
@testable import Plume

struct PullRequestChipTests {
    private func labels(
        _ state: PullRequestFetchState,
        rollup: CheckRollup? = nil
    ) -> [String] {
        PullRequestChipContent.glyphs(for: state) { pullRequest in
            rollup ?? pullRequest.checkRollup()
        }
        .map(\.label)
    }

    @Test func theOrderIsNumberDraftChecksReview() {
        let pullRequest = PullRequest(
            number: 12,
            state: .open,
            isDraft: true,
            reviewDecision: .approved
        )
        #expect(labels(.pullRequest(pullRequest), rollup: .success)
            == ["PR #12", "draft", "checks pass", "approved"])
    }

    @Test func mergedShowsOnlyItsOwnGlyph() {
        let pullRequest = PullRequest(
            number: 3,
            state: .merged,
            isDraft: true,
            reviewDecision: .changesRequested
        )
        #expect(labels(.pullRequest(pullRequest), rollup: .failure) == ["PR #3", "merged"])
    }

    @Test func closedShowsOnlyItsOwnGlyph() {
        let pullRequest = PullRequest(
            number: 4,
            state: .closed,
            isDraft: true,
            reviewDecision: .approved
        )
        #expect(labels(.pullRequest(pullRequest), rollup: .success) == ["PR #4", "closed"])
    }

    /// An open pull request with no checks and no review still has to look
    /// like one rather than a bare number.
    @Test func anOpenPullRequestWithNothingToSayStillMarksItselfOpen() {
        let pullRequest = PullRequest(number: 5, state: .open, isDraft: false)
        #expect(labels(.pullRequest(pullRequest), rollup: .none) == ["PR #5", "open"])
    }

    @Test func aFailingCheckAndRequestedChangesBothShow() {
        let pullRequest = PullRequest(
            number: 6,
            state: .open,
            isDraft: false,
            reviewDecision: .changesRequested
        )
        #expect(labels(.pullRequest(pullRequest), rollup: .failure)
            == ["PR #6", "checks fail", "changes requested"])
    }

    /// Every non-GitHub repository lands here, so it must not draw an error.
    @Test func anUnsupportedForgeDrawsNothing() {
        #expect(PullRequestChipContent.glyphs(for: .forgeUnsupported).isEmpty)
        #expect(PullRequestChipContent.accessibilityText(for: .forgeUnsupported) == nil)
    }

    @Test func theQuietStatesEachDrawOneDistinctGlyph() {
        let states: [PullRequestFetchState] = [.loading, .timedOut, .failed("offline"), .localOnly, .noPR]
        let symbols = states.flatMap { PullRequestChipContent.glyphs(for: $0) }.compactMap(\.symbol)
        #expect(symbols.count == states.count)
        #expect(Set(symbols).count == states.count)
    }

    @Test func aPendingCheckIgnoredByTheRepositoryDoesNotShowAsPending() {
        let pullRequest = PullRequest(
            number: 8,
            state: .open,
            isDraft: false,
            checkContexts: [CheckContext(name: "flaky", status: "PENDING")]
        )
        let ignored = PullRequestChipContent.glyphs(for: .pullRequest(pullRequest)) {
            $0.checkRollup(ignoredWhenPending: ["flaky"])
        }
        #expect(ignored.map(\.label) == ["PR #8", "checks pass"])
    }
}
