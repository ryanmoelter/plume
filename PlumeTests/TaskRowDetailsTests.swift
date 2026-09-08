import Testing
import Foundation
@testable import Plume

struct TaskRowDetailsTests {
    @Test func linesFollowStatusBranchDirectoryOrder() {
        let lines = TaskRowDetails.lines(
            status: .working,
            branch: "ryanm/fix-login",
            workingDirectory: "/Users/me/Plume"
        )
        #expect(lines == [.text("working"), .text("ryanm/fix-login"), .text("Plume")])
    }

    /// An unconfigured task should collapse to nothing rather than show gaps.
    @Test func absentValuesProduceNoLines() {
        #expect(TaskRowDetails.lines(
            status: .unset, branch: nil, workingDirectory: nil
        ).isEmpty)
    }

    @Test func emptyStringsCountAsAbsent() {
        #expect(TaskRowDetails.lines(
            status: .unset, branch: "", workingDirectory: ""
        ).isEmpty)
    }

    @Test func aDirectoryWithoutABranchStillShows() {
        let lines = TaskRowDetails.lines(
            status: .idle, branch: nil, workingDirectory: "/Users/me/Plume"
        )
        #expect(lines == [.text("idle"), .text("Plume")])
    }

    /// Between the branch it belongs to and the directory it lives in.
    @Test func thePullRequestLineSitsAfterTheBranch() {
        let lines = TaskRowDetails.lines(
            status: .idle,
            branch: "ryanm/fix-login",
            workingDirectory: "/Users/me/Plume",
            pullRequest: .noPR
        )
        #expect(lines == [.text("idle"), .text("ryanm/fix-login"), .pullRequest(.noPR), .text("Plume")])
    }

    @Test func aRepositoryOnAnUnsupportedForgeAddsNoLine() {
        let lines = TaskRowDetails.lines(
            status: .idle,
            branch: "ryanm/fix-login",
            workingDirectory: "/Users/me/Plume",
            pullRequest: .forgeUnsupported
        )
        #expect(lines == [.text("idle"), .text("ryanm/fix-login"), .text("Plume")])
    }

    @Test func noPullRequestStateAddsNoLine() {
        let lines = TaskRowDetails.lines(
            status: .unset, branch: nil, workingDirectory: nil, pullRequest: nil
        )
        #expect(lines.isEmpty)
    }

    @Test func aPullRequestLineReachesTheAccessibilityLabel() {
        let line = TaskRowDetails.Line.pullRequest(
            .pullRequest(PullRequest(number: 42, state: .open, isDraft: false))
        )
        #expect(TaskRowDetails.accessibilityText(line)?.contains("PR #42") == true)
    }

    @Test func needsInputReadsAsWords() {
        #expect(TaskRowDetails.statusText(.needsInput) == "needs input")
    }

    @Test func unsetStatusHasNoLine() {
        #expect(TaskRowDetails.statusText(.unset) == nil)
    }

    @Test func directoryUsesTheLastPathComponent() {
        #expect(TaskRowDetails.directoryName("/Users/me/Development/Plume") == "Plume")
    }
}
