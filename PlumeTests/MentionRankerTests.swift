import Foundation
import Testing
@testable import Plume

struct MentionRankerTests {
    private func file(_ path: String, _ quality: MentionMatchQuality) -> RankedMention {
        RankedMention(candidate: .file(.init(path: path, isDirectory: false)), quality: quality)
    }

    private func linear(_ identifier: String, _ quality: MentionMatchQuality) -> RankedMention {
        RankedMention(
            candidate: .linear(.init(
                identifier: identifier,
                title: "t",
                url: "https://linear.app/x/\(identifier)",
                stateType: .started,
                stateColor: "#000000",
                updatedAt: Date(timeIntervalSince1970: 0)
            )),
            quality: quality
        )
    }

    private func pull(_ number: Int, _ quality: MentionMatchQuality) -> RankedMention {
        RankedMention(
            candidate: .pullRequest(.init(
                number: number,
                title: "t",
                url: "https://github.com/o/r/pull/\(number)",
                state: .open,
                isDraft: false,
                updatedAt: nil
            )),
            quality: quality
        )
    }

    // MARK: - Merging

    @Test func sourcesAlwaysRunLinearThenPullRequestsThenFiles() {
        let merged = MentionRanker.merge(
            [
                .files: [file("a", .exact)],
                .linear: [linear("DROID-1", .loose)],
                .pullRequests: [pull(1, .words)],
            ],
            isBare: false
        )
        #expect(merged.map(\.source) == [.linear, .pullRequests, .files])
    }

    @Test func aTypedQueryShowsTenFilesAndFiveOfEachOther() {
        let merged = MentionRanker.merge(
            [
                .files: (0..<15).map { file("f\($0)", .prefix) },
                .linear: (0..<8).map { linear("DROID-\($0)", .prefix) },
                .pullRequests: (0..<8).map { pull($0, .prefix) },
            ],
            isBare: false
        )
        #expect(merged.count == MentionRanker.totalLimit)
        #expect(merged.filter { $0.source == .files }.count == 10)
        #expect(merged.filter { $0.source == .linear }.count == 5)
        #expect(merged.filter { $0.source == .pullRequests }.count == 5)
        #expect(merged.suffix(10).map(\.id) == (0..<10).map { "file:f\($0)" })
    }

    @Test func aBareQueryShowsThreeFilesUnderTheRest() {
        let merged = MentionRanker.merge(
            [
                .files: (0..<9).map { file("f\($0)", .prefix) },
                .linear: [linear("DROID-1", .prefix)],
                .pullRequests: [pull(1, .prefix)],
            ],
            isBare: true
        )
        #expect(merged.map(\.id) == [
            "linear:DROID-1", "pr:https://github.com/o/r/pull/1", "file:f0", "file:f1", "file:f2",
        ])
    }

    @Test func aFilteredQueryShowsFiftyOfItsSource() {
        let files = MentionRanker.merge([.files: (0..<80).map { file("f\($0)", .prefix) }], isBare: false, isFiltered: true)
        #expect(files.count == MentionRanker.filteredLimit)
        #expect(files.map(\.id) == (0..<50).map { "file:f\($0)" })
        let issues = MentionRanker.merge([.linear: (0..<80).map { linear("DROID-\($0)", .prefix) }], isBare: false, isFiltered: true)
        #expect(issues.count == MentionRanker.filteredLimit)
    }

    @Test func onlyAFilteredQueryAsksSourcesForFifty() {
        let filtered = MentionQuery(trigger: .at, text: "src/", filter: .file, triggerLocation: 0, caretLocation: 10)
        let plain = MentionQuery(trigger: .at, text: "src/", triggerLocation: 0, caretLocation: 5)
        #expect(MentionRanker.matchLimit(for: filtered) == 50)
        #expect(MentionRanker.matchLimit(for: plain) == FileMentionMatcher.defaultLimit)
    }

    @Test func aSourceKeepsItsOwnOrder() {
        let merged = MentionRanker.merge([.files: [file("b", .loose), file("a", .exact)]], isBare: false)
        #expect(merged.map(\.id) == ["file:b", "file:a"])
    }

    // MARK: - Selection

    @Test func theSelectionFollowsItsCandidateWhenResultsArrive() {
        let before = MentionRanker.merge([.files: [file("a", .prefix)]], isBare: false)
        let selected = before[0].id
        let after = MentionRanker.merge(
            [.files: [file("a", .prefix)], .linear: [linear("DROID-1", .exact)]],
            isBare: false
        )
        #expect(MentionRanker.selectionIndex(keeping: selected, in: after) == 1)
    }

    @Test func aVanishedSelectionFallsBackToTheTop() {
        let list = MentionRanker.merge([.files: [file("b", .prefix)]], isBare: false)
        #expect(MentionRanker.selectionIndex(keeping: "file:a", in: list) == 0)
        #expect(MentionRanker.selectionIndex(keeping: nil, in: list) == 0)
    }

    @Test func aCompleteLinearIdentifierEndsInItsNumber() {
        #expect(LinearIdentifierShape.isComplete("DROID-12"))
        #expect(!LinearIdentifierShape.isComplete("DROID-"))
        #expect(!LinearIdentifierShape.isComplete("droid"))
    }

    // MARK: - Pull requests

    private func entry(
        _ number: Int,
        _ title: String,
        state: PullRequestState = .open,
        draft: Bool = false,
        updated: TimeInterval? = nil
    ) -> MentionCandidate.PullRequestEntry {
        .init(
            number: number,
            title: title,
            url: "https://github.com/o/r/pull/\(number)",
            state: state,
            isDraft: draft,
            updatedAt: updated.map { Date(timeIntervalSince1970: $0) }
        )
    }

    private func numbers(_ query: String, in pulls: [MentionCandidate.PullRequestEntry]) -> [Int] {
        PullRequestMentionMatcher.matches(query, in: pulls).compactMap {
            if case .pullRequest(let pull) = $0.candidate { pull.number } else { nil }
        }
    }

    @Test func pullRequestsRankExactNumberThenPrefixThenTitle() {
        let pulls = [entry(120, "Other"), entry(12, "Add mentions"), entry(7, "Fix 12 things")]
        let results = PullRequestMentionMatcher.matches("12", in: pulls)
        #expect(numbers("12", in: pulls) == [12, 120, 7])
        #expect(results.map(\.quality) == [.exact, .prefix, .words])
    }

    @Test func pullRequestTiesPreferOpenThenReadyThenRecent() {
        let pulls = [
            entry(1, "Layout", state: .merged, updated: 100),
            entry(2, "Layout", draft: true, updated: 90),
            entry(3, "Layout", updated: 10),
            entry(4, "Layout", updated: 20),
        ]
        #expect(numbers("lay", in: pulls) == [4, 3, 2, 1])
    }

    @Test func aPullRequestTitleSubstringMatchesLoosely() {
        let results = PullRequestMentionMatcher.matches("ntion", in: [entry(1, "Add mentions")])
        #expect(results.map(\.quality) == [.loose])
    }

    @Test func aLeadingHashOnAPullRequestQueryIsIgnored() {
        #expect(numbers("#12", in: [entry(12, "x")]) == [12])
    }
}
