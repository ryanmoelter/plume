import Foundation
import Testing
@testable import Plume

@MainActor
struct InfoPaneOrderTests {
    private func issue(
        _ identifier: String, _ type: LinearStateType, _ position: Double? = nil, team: String = "P"
    ) -> LinearIssue {
        LinearIssue(
            identifier: identifier, title: "T", url: "https://linear.app/x/issue/\(identifier)",
            stateName: "S", stateType: type, stateColor: "#000000", statePosition: position,
            assigneeName: nil, teamKey: team
        )
    }

    private func link(_ identifier: String, _ role: LinearLinkRole = .working) -> LinkedLinearIssue {
        LinkedLinearIssue(
            identifier: identifier, role: role, sources: [.branch], subagents: [], touchedByMainAgent: false
        )
    }

    private func order(_ links: [LinkedLinearIssue], _ fetched: [String: LinearIssueFetchState]) -> [String] {
        InfoPaneFacts.linearIssues(links: links, state: { fetched[$0] }).map(\.identifier)
    }

    @Test func linearTypesRankStartedThroughCanceled() {
        let types: [(String, LinearStateType)] = [
            ("CAN", .canceled), ("DON", .completed), ("OTH", .other("x")), ("TRI", .triage),
            ("BAC", .backlog), ("TOD", .unstarted), ("DUP", .duplicate), ("STA", .started),
        ]
        var fetched: [String: LinearIssueFetchState] = [:]
        for (identifier, type) in types { fetched[identifier] = .issue(issue(identifier, type)) }
        let sorted = order(types.map { link($0.0) }, fetched)
        #expect(Array(sorted.prefix(6)) == ["STA", "TOD", "BAC", "TRI", "OTH", "DON"])
        #expect(Set(sorted.suffix(2)) == ["CAN", "DUP"])
    }

    @Test func aHigherPositionComesFirstWithinAType() {
        let fetched: [String: LinearIssueFetchState] = [
            "A-1": .issue(issue("A-1", .started, 1)),
            "A-2": .issue(issue("A-2", .started, 3)),
            "A-3": .issue(issue("A-3", .started, 2)),
            "A-4": .issue(issue("A-4", .started)),
        ]
        #expect(order(["A-1", "A-2", "A-3", "A-4"].map { link($0) }, fetched) == ["A-2", "A-3", "A-1", "A-4"])
    }

    @Test func positionsOnlyCompareWithinOneTeamAndTeamsGroupByFirstAppearance() {
        let fetched: [String: LinearIssueFetchState] = [
            "A-1": .issue(issue("A-1", .started, 1, team: "A")),
            "B-1": .issue(issue("B-1", .started, 9, team: "B")),
            "A-2": .issue(issue("A-2", .started, 2, team: "A")),
            "B-2": .issue(issue("B-2", .started, 5, team: "B")),
        ]
        #expect(order(["A-1", "B-1", "A-2", "B-2"].map { link($0) }, fetched) == ["A-2", "A-1", "B-1", "B-2"])
    }

    @Test func equalIssuesKeepTheirOrder() {
        let fetched: [String: LinearIssueFetchState] = [
            "A-1": .issue(issue("A-1", .started, 1)),
            "A-2": .issue(issue("A-2", .started, 1)),
            "A-3": .issue(issue("A-3", .started, 1)),
        ]
        #expect(order(["A-3", "A-1", "A-2"].map { link($0) }, fetched) == ["A-3", "A-1", "A-2"])
    }

    @Test func issuesWithoutAStateGoLastInTheirGroup() {
        let fetched: [String: LinearIssueFetchState] = [
            "A-2": .issue(issue("A-2", .canceled)),
            "A-3": .failed("offline"),
        ]
        #expect(order([link("A-1"), link("A-2"), link("A-3")], fetched) == ["A-2", "A-1", "A-3"])
    }

    @Test func workingStaysBeforeMentionedWhateverTheStatus() {
        let fetched: [String: LinearIssueFetchState] = [
            "W-1": .issue(issue("W-1", .canceled)),
            "M-1": .issue(issue("M-1", .started)),
        ]
        #expect(order([link("M-1", .mentioned), link("W-1")], fetched) == ["W-1", "M-1"])
    }

    @Test func settledMentionedIssuesAreSortedInTheirOwnGroup() throws {
        let fetched: [String: LinearIssueFetchState] = [
            "M-1": .issue(issue("M-1", .completed)),
            "M-2": .issue(issue("M-2", .started)),
        ]
        let facts = try #require(InfoPaneFacts.linear(
            isEnabled: true, isConfigured: true,
            links: [link("M-1", .mentioned), link("M-2", .mentioned)],
            state: { fetched[$0] }, hasSettled: { _ in true }
        ))
        #expect(facts.mentioned.map(\.identifier) == ["M-2", "M-1"])
    }

    // MARK: Pull requests

    private func entry(_ number: Int, _ state: PullRequestState, draft: Bool = false) -> MentionCandidate.PullRequestEntry {
        MentionCandidate.PullRequestEntry(
            number: number, title: "T", url: "https://github.com/a/b/pull/\(number)",
            state: state, isDraft: draft, updatedAt: nil
        )
    }

    private func linked(
        _ number: Int,
        _ role: LinkedPullRequestRole,
        _ entry: MentionCandidate.PullRequestEntry?
    ) -> InfoPaneFacts.LinkedPullRequestFacts {
        InfoPaneFacts.LinkedPullRequestFacts(
            reference: PullRequestReference(owner: "a", repo: "b", number: number), role: role, pullRequest: entry
        )
    }

    @Test func pullRequestsRankOpenDraftUnknownClosedMerged() {
        let summaries: [PullRequestSummary?] = [
            PullRequestSummary(number: 1, state: .open, isDraft: false),
            PullRequestSummary(number: 1, state: .open, isDraft: true),
            nil,
            PullRequestSummary(number: 1, state: .closed, isDraft: false),
            PullRequestSummary(number: 1, state: .merged, isDraft: false),
        ]
        let ranks = summaries.map(PullRequestStatusOrder.rank)
        #expect(ranks == ranks.sorted())
        #expect(Set(ranks).count == 5)
    }

    @Test func pullRequestGroupsSortSeparatelyAndStably() {
        let items = InfoPanePullRequestItem.items(
            branch: nil,
            linked: [
                linked(1, .mentioned, entry(1, .merged)),
                linked(2, .pinned, entry(2, .closed)),
                linked(3, .mentioned, entry(3, .open)),
                linked(4, .pinned, nil),
                linked(5, .pinned, entry(5, .open, draft: true)),
                linked(6, .mentioned, entry(6, .open)),
                linked(7, .pinned, entry(7, .open, draft: true)),
            ]
        )
        #expect(items.map(\.number) == [5, 7, 4, 2, 3, 6, 1])
        #expect(items.map(\.role) == [.pinned, .pinned, .pinned, .pinned, .mentioned, .mentioned, .mentioned])
    }
}
