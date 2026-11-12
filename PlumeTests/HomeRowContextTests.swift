import Testing
@testable import Plume

/// The context line under a Home row: project, branch, then the first Linear
/// issue and pull request with a count of the rest. A segment with no data is
/// left out, and a context with none has no segments at all.
@MainActor
struct HomeRowContextTests {
    private typealias Reference = HomeRowContext.Reference

    @Test func anEmptyContextHasNoSegments() {
        #expect(HomeRowContext().segments.isEmpty)
        #expect(HomeRowContext(project: "", branch: "").segments.isEmpty)
    }

    @Test func everySegmentInOrder() {
        let issue = Reference(id: "PLUME-334", icon: .linear(.started, progress: .half, colorHex: "#f2c94c"))
        let pullRequest = Reference(id: "#12", icon: .pullRequest(number: 12, state: .open, isDraft: false))
        let context = HomeRowContext(
            project: "Plume",
            branch: "ryanm/home-tab",
            isWorktree: true,
            isLocalOnly: false,
            issues: [issue, Reference(id: "PLUME-1"), Reference(id: "PLUME-2"), Reference(id: "PLUME-3")],
            pullRequests: [pullRequest, Reference(id: "#13"), Reference(id: "#14")]
        )
        #expect(context.segments == [
            .project("Plume"),
            .branch("ryanm/home-tab", isWorktree: true, isLocalOnly: false),
            .issue(issue, more: 3),
            .pullRequest(pullRequest, more: 2),
        ])
    }

    @Test func aSingleReferenceHasNoMore() {
        let context = HomeRowContext(issues: [Reference(id: "PLUME-1")], pullRequests: [Reference(id: "#1")])
        #expect(context.segments == [
            .issue(Reference(id: "PLUME-1"), more: 0),
            .pullRequest(Reference(id: "#1"), more: 0),
        ])
    }

    @Test func missingSegmentsAreLeftOut() {
        #expect(HomeRowContext(branch: "main").segments == [.branch("main", isWorktree: false, isLocalOnly: false)])
        #expect(HomeRowContext(project: "Plume", pullRequests: [Reference(id: "#7")]).segments == [
            .project("Plume"), .pullRequest(Reference(id: "#7"), more: 0),
        ])
    }
}
