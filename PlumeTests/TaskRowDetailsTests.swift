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
        #expect(lines == ["working", "ryanm/fix-login", "Plume"])
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
        #expect(lines == ["idle", "Plume"])
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
