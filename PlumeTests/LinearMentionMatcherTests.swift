import Foundation
import Testing
@testable import Plume

struct LinearMentionMatcherTests {
    private func issue(
        _ identifier: String,
        _ title: String,
        state: LinearStateType = .started,
        updated: TimeInterval = 0
    ) -> MentionCandidate.LinearIssue {
        .init(
            identifier: identifier,
            title: title,
            url: "https://linear.app/acme/issue/\(identifier)",
            stateType: state,
            stateColor: "#000000",
            updatedAt: Date(timeIntervalSince1970: updated)
        )
    }

    private func identifiers(_ query: String, in issues: [MentionCandidate.LinearIssue]) -> [String] {
        LinearMentionMatcher.matches(query, in: issues).compactMap {
            if case .linear(let issue) = $0.candidate { issue.identifier } else { nil }
        }
    }

    private var corpus: [MentionCandidate.LinearIssue] {
        [
            issue("DROID-123", "Fix the text layout"),
            issue("DROID-7", "Crash on launch"),
            issue("IOS-145", "Text field loses focus"),
            issue("IOS-146", "Fix layout on iPad"),
            issue("WEB-9", "Layout shift in the header"),
        ]
    }

    @Test func aTeamKeyPrefixThenTitleWordsFindsTheIssue() {
        #expect(identifiers("dro layout", in: corpus) == ["DROID-123"])
    }

    @Test func iosTexFindsTheIOSIssueAboutText() {
        #expect(identifiers("ios tex", in: corpus) == ["IOS-145"])
    }

    @Test func theTeamRuleOutranksPlainTitleWords() {
        let issues = [
            issue("WEB-1", "Droid layout notes", updated: 100),
            issue("DROID-2", "Fix layout", updated: 0),
        ]
        let results = LinearMentionMatcher.matches("dro layout", in: issues)
        #expect(results.map(\.candidate.id) == ["linear:DROID-2", "linear:WEB-1"])
        #expect(results.allSatisfy { $0.quality == .words })
    }

    @Test func aPrefixSharedByTwoTeamKeysMatchesBothTeams() {
        let issues = [
            issue("IOS-1", "Fix sensor crash", updated: 10),
            issue("IOT-2", "Fix sensor reading", updated: 20),
            issue("DROID-3", "Fix sensor", updated: 30),
        ]
        #expect(identifiers("io sensor", in: issues) == ["IOT-2", "IOS-1"])
    }

    @Test func anExactIdentifierRanksFirst() {
        let issues = [
            issue("DROID-1234", "Other", updated: 100),
            issue("DROID-123", "Fix the text layout"),
        ]
        let results = LinearMentionMatcher.matches("droid-123", in: issues)
        #expect(results.first?.candidate.id == "linear:DROID-123")
        #expect(results.first?.quality == .exact)
        #expect(results.last?.quality == .prefix)
    }

    @Test func aTeamKeyAloneListsThatTeamsIssues() {
        #expect(Set(identifiers("droid", in: corpus)) == ["DROID-123", "DROID-7"])
    }

    @Test func allWordsPrefixingTitleWordsMatch() {
        let results = LinearMentionMatcher.matches("fix lay", in: corpus)
        #expect(Set(results.map(\.candidate.id)) == ["linear:DROID-123", "linear:IOS-146"])
        #expect(results.allSatisfy { $0.quality == .words })
    }

    @Test func aTitleSubstringMatchesLoosely() {
        let results = LinearMentionMatcher.matches("ayou", in: corpus)
        #expect(results.count == 3)
        #expect(results.allSatisfy { $0.quality == .loose })
    }

    @Test func openIssuesRankBeforeDoneOnes() {
        let issues = [
            issue("A-1", "Layout", state: .completed, updated: 100),
            issue("A-2", "Layout", state: .canceled, updated: 90),
            issue("A-3", "Layout", state: .backlog, updated: 0),
        ]
        #expect(identifiers("layout", in: issues) == ["A-3", "A-1", "A-2"])
    }

    @Test func tiesGoToTheMostRecentlyUpdated() {
        let issues = [
            issue("A-1", "Layout", updated: 10),
            issue("A-2", "Layout", updated: 30),
            issue("A-3", "Layout", updated: 20),
        ]
        #expect(identifiers("layout", in: issues) == ["A-2", "A-3", "A-1"])
    }

    @Test func anEmptyQueryListsOpenRecentIssues() {
        let issues = [
            issue("A-1", "One", state: .completed, updated: 30),
            issue("A-2", "Two", updated: 10),
            issue("A-3", "Three", updated: 20),
        ]
        #expect(identifiers("", in: issues) == ["A-3", "A-2", "A-1"])
    }

    @Test func resultsAreCapped() {
        let issues = (1...30).map { issue("A-\($0)", "Same title") }
        #expect(LinearMentionMatcher.matches("same", in: issues).count == LinearMentionMatcher.defaultLimit)
    }

    @Test func aCachedIssueTakesItsStateFromTheLookup() {
        let fallback = LinearWorkflowState(id: "s0", name: "Todo", type: .unstarted, color: "#111111")
        let cached = LinearSyncCache.Issue(
            id: "i1",
            identifier: "DROID-1",
            title: "Title",
            url: "https://linear.app/x",
            updatedAt: Date(timeIntervalSince1970: 5),
            archivedAt: nil,
            stateID: "s1",
            assigneeID: nil,
            teamID: "t1",
            teamKey: "DROID",
            fallbackState: fallback
        )
        let done = LinearWorkflowState(id: "s1", name: "Done", type: .completed, color: "#222222")
        let fromLookup = MentionCandidate.LinearIssue(cached, state: done)
        #expect(fromLookup.stateType == .completed)
        #expect(fromLookup.stateColor == "#222222")
        #expect(MentionCandidate.LinearIssue(cached, state: nil).stateType == .unstarted)
    }

    @Test func aSearchTakesATeamPrefixAsItsFilter() {
        let keys: Set<String> = ["DROID", "DRONE", "IOS"]
        #expect(LinearMentionSearch.parse("dro layout", teamKeys: keys) == .text(term: "layout", teamKeys: ["DROID", "DRONE"]))
        #expect(LinearMentionSearch.parse("text layout", teamKeys: keys) == .text(term: "text layout", teamKeys: []))
        #expect(LinearMentionSearch.parse("ios", teamKeys: keys) == .text(term: "ios", teamKeys: []))
    }

    @Test func aOneLetterFirstWordFiltersOnlyByAnExactTeamKey() {
        let keys: Set<String> = ["DROID", "A"]
        #expect(LinearMentionSearch.parse("d layout", teamKeys: keys) == .text(term: "d layout", teamKeys: []))
        #expect(LinearMentionSearch.parse("a layout", teamKeys: keys) == .text(term: "layout", teamKeys: ["A"]))
    }

    @Test func aSearchNeedsTwoCharactersAndSpotsIdentifiers() {
        #expect(LinearMentionSearch.parse("a", teamKeys: []) == nil)
        #expect(LinearMentionSearch.parse("ios x", teamKeys: ["IOS"]) == nil)
        #expect(LinearMentionSearch.parse("droid-12", teamKeys: []) == .identifier("DROID-12"))
    }
}
