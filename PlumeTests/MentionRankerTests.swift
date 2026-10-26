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

    private let teams: Set<String> = ["DROID", "IOS"]

    // MARK: - Source order

    @Test func digitsPutPullRequestsFirst() {
        #expect(MentionRanker.sourceOrder(for: "12", teamKeys: teams).first == .pullRequests)
    }

    @Test func anIdentifierOrTeamKeyPutsLinearFirst() {
        #expect(MentionRanker.sourceOrder(for: "DROID-12", teamKeys: teams).first == .linear)
        #expect(MentionRanker.sourceOrder(for: "droid-", teamKeys: teams).first == .linear)
        #expect(MentionRanker.sourceOrder(for: "ios", teamKeys: teams).first == .linear)
        #expect(MentionRanker.sourceOrder(for: "dro layout", teamKeys: teams).first == .linear)
    }

    @Test func aBareTeamKeyPrefixKeepsTheDefaultOrder() {
        #expect(MentionRanker.sourceOrder(for: "dro", teamKeys: teams) == [.files, .linear, .pullRequests])
    }

    @Test func aPathShapePutsFilesFirst() {
        #expect(MentionRanker.sourceOrder(for: "ios.swift", teamKeys: teams).first == .files)
        #expect(MentionRanker.sourceOrder(for: "droid-1/x", teamKeys: teams).first == .files)
    }

    @Test func anythingElseIsFilesThenLinearThenPullRequests() {
        #expect(MentionRanker.sourceOrder(for: "layout", teamKeys: teams) == [.files, .linear, .pullRequests])
        #expect(MentionRanker.sourceOrder(for: "", teamKeys: teams) == [.files, .linear, .pullRequests])
    }

    // MARK: - Merging

    @Test func betterMatchesComeFirstWhateverTheirSource() {
        let merged = MentionRanker.merge(
            [
                .files: [file("a", .loose)],
                .linear: [linear("DROID-1", .exact)],
                .pullRequests: [pull(1, .words)],
            ],
            query: "layout",
            teamKeys: teams
        )
        #expect(merged.map(\.id) == ["linear:DROID-1", "pr:https://github.com/o/r/pull/1", "file:a"])
    }

    @Test func withinAQualityGroupTheSourceOrderDecides() {
        let results: [MentionCandidate.Source: [RankedMention]] = [
            .files: [file("a", .prefix)],
            .linear: [linear("DROID-1", .prefix)],
            .pullRequests: [pull(1, .prefix)],
        ]
        let byDigits = MentionRanker.merge(results, query: "1", teamKeys: teams)
        #expect(byDigits.map(\.source) == [.pullRequests, .files, .linear])
        let byWords = MentionRanker.merge(results, query: "layout", teamKeys: teams)
        #expect(byWords.map(\.source) == [.files, .linear, .pullRequests])
    }

    @Test func eachSourceIsCappedAtFive() {
        let merged = MentionRanker.merge(
            [.files: (0..<9).map { file("f\($0)", .prefix) }],
            query: "f",
            teamKeys: teams
        )
        #expect(merged.map(\.id) == (0..<5).map { "file:f\($0)" })
    }

    @Test func theCapKeepsEachSourcesOwnBestAndLetsAWorseOneThroughLater() {
        let merged = MentionRanker.merge(
            [.files: [file("good", .exact)] + (0..<6).map { file("f\($0)", .loose) }],
            query: "f",
            teamKeys: teams
        )
        #expect(merged.count == 5)
        #expect(merged.first?.id == "file:good")
    }

    @Test func theListIsCappedAtTwelve() {
        let merged = MentionRanker.merge(
            [
                .files: (0..<5).map { file("f\($0)", .words) },
                .linear: (0..<5).map { linear("DROID-\($0)", .words) },
                .pullRequests: (0..<5).map { pull($0, .words) },
            ],
            query: "x",
            teamKeys: teams
        )
        #expect(merged.count == 12)
        #expect(merged.filter { $0.source == .pullRequests }.count == 2)
    }

    // MARK: - Selection

    @Test func theSelectionFollowsItsCandidateWhenResultsArrive() {
        let before = MentionRanker.merge([.files: [file("a", .prefix)]], query: "a", teamKeys: teams)
        let selected = before[0].id
        let after = MentionRanker.merge(
            [.files: [file("a", .prefix)], .linear: [linear("DROID-1", .exact)]],
            query: "a",
            teamKeys: teams
        )
        #expect(MentionRanker.selectionIndex(keeping: selected, in: after) == 1)
    }

    @Test func aVanishedSelectionFallsBackToTheTop() {
        let list = MentionRanker.merge([.files: [file("b", .prefix)]], query: "b", teamKeys: teams)
        #expect(MentionRanker.selectionIndex(keeping: "file:a", in: list) == 0)
        #expect(MentionRanker.selectionIndex(keeping: nil, in: list) == 0)
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
