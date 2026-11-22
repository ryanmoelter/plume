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
}
