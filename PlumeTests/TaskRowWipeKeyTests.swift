import Foundation
import Testing
@testable import Plume

/// A sidebar line wipes only when its text changes and its key stays the
/// same, so a line that shifts into another's place must take a new key.
@MainActor
struct TaskRowWipeKeyTests {
    private func header(_ id: UUID) -> TaskRowDetails.Line {
        .agentHeader(TaskRowDetails.AgentHeader(tabID: id, title: "Chat", status: .working))
    }

    @Test func aBranchRenamedInPlaceKeepsItsKey() {
        let before = TaskRowDetails.wipeKeys([.project("Plume"), .branch("main")])
        let after = TaskRowDetails.wipeKeys([.project("Plume"), .branch("fix-login")])
        #expect(before == after)
    }

    @Test func aGroupInsertedAboveGivesTheShiftedLinesNewKeys() {
        let first = UUID(), second = UUID()
        let before = TaskRowDetails.wipeKeys([header(second), .project("Plume")])
        let after = TaskRowDetails.wipeKeys([header(first), .project("Other"), header(second), .project("Plume")])
        #expect(before[1] != after[1])
        #expect(before == Array(after[2...]))
    }

    @Test func linesOfOneKindInOneGroupCountUp() {
        let keys = TaskRowDetails.wipeKeys([.project("A"), .branch("a"), .project("B"), .branch("b")])
        #expect(Set(keys).count == 4)
    }

    @Test func issuesAndPinnedPullRequestsKeyOnWhatTheyName() {
        let reference = PullRequestReference(owner: "ryanmoelter", repo: "plume", number: 12)
        let keys = TaskRowDetails.wipeKeys([
            .linearIssue(identifier: "PLUME-1", state: nil),
            .pinnedPullRequest(reference, detail: nil),
        ])
        let reordered = TaskRowDetails.wipeKeys([
            .pinnedPullRequest(reference, detail: nil),
            .linearIssue(identifier: "PLUME-1", state: nil),
        ])
        #expect(Set(keys) == Set(reordered))
    }

    @Test func aPullRequestLineKeysOnThePullRequestItShows() {
        func line(_ number: Int, title: String) -> TaskRowDetails.Line {
            .pullRequest(directory: nil, state: .pullRequest(PullRequest(
                number: number, state: .open, isDraft: false,
                url: "https://github.com/ryanmoelter/plume/pull/\(number)", title: title
            )))
        }
        let retitled = TaskRowDetails.wipeKeys([line(7, title: "Old"), line(7, title: "New")])
        #expect(retitled[0] == retitled[1])
        #expect(TaskRowDetails.wipeKeys([line(7, title: "Fix")]) != TaskRowDetails.wipeKeys([line(8, title: "Fix")]))
    }

    @Test func theTitleStandsForItsHeaderOrItsOnlyAgent() {
        let parent = UUID(), child = UUID(), sole = UUID()
        var standing = TaskRowDetails.AgentHeader(tabID: parent, title: "Chat", status: .working)
        standing.standsForTask = true
        #expect(TaskRowDetails.titleTabID([.agentHeader(standing), header(child)], soleAgent: sole) == parent)
        #expect(TaskRowDetails.titleTabID([.project("Plume")], soleAgent: sole) == sole)
        #expect(TaskRowDetails.titleTabID([header(child)], soleAgent: sole) == nil)
    }
}
