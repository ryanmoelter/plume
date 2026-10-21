import Foundation
import Testing
@testable import Plume

struct LinearLinkResolverTests {
    private func state(_ id: String, _ name: String, _ type: LinearStateType) -> LinearWorkflowState {
        LinearWorkflowState(id: id, name: name, type: type, color: "#000000")
    }

    private var catalog: LinearCatalog {
        LinearCatalog(
            orgID: "o1",
            teams: [LinearTeam(id: "t1", key: "PLUME", name: "Plume", states: [
                state("s-backlog", "Backlog", .backlog),
                state("s-prog", "In Progress", .started),
                state("s-done", "Done", .completed),
            ])],
            fetchedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private let sub = LinearSubagentRef(id: "a1", label: "Explore")

    private func evidence(
        _ id: String,
        tool: String = "get_issue",
        state: String? = nil,
        sub: LinearSubagentRef? = nil,
        outcome: LinearCallOutcome = .succeeded
    ) -> LinearEvidence {
        LinearEvidence(identifier: id, tool: tool, requestedState: state, subagent: sub, outcome: outcome)
    }

    private func resolve(
        _ evidence: [LinearEvidence] = [],
        branch: [String] = [],
        links: LinearTaskLinks = LinearTaskLinks(),
        catalogs: [LinearCatalog]? = nil
    ) -> [LinkedLinearIssue] {
        LinearLinkResolver.resolve(evidence: evidence, branchIdentifiers: branch, links: links, catalogs: catalogs ?? [catalog])
    }

    @Test(arguments: ["s-prog", "in progress", "started"])
    func startedResolvesByIDNameAndType(requested: String) {
        let issues = resolve([evidence("PLUME-1", tool: "save_issue", state: requested)])
        #expect(issues.first?.role == .working)
    }

    @Test func nonStartedStatesAreMentioned() {
        #expect(resolve([evidence("PLUME-1", tool: "save_issue", state: "Done")]).first?.role == .mentioned)
        #expect(resolve([evidence("PLUME-1", tool: "get_issue", state: "In Progress")]).first?.role == .mentioned)
        #expect(resolve([evidence("PLUME-1")]).first?.role == .mentioned)
    }

    @Test func noCatalogMeansNoIssue() {
        let issues = resolve([evidence("PLUME-1", tool: "save_issue", state: "started")], catalogs: [])
        #expect(issues.isEmpty)
    }

    @Test func unresolvableStateIsMentioned() {
        let issues = resolve([evidence("PLUME-1", tool: "save_issue", state: "Shipping")])
        #expect(issues.first?.role == .mentioned)
    }

    @Test func unknownTeamKeysAreDropped() {
        let issues = resolve([evidence("UTF-8")], branch: ["UTF-8", "PLUME-2"])
        #expect(issues.map(\.identifier) == ["PLUME-2"])
    }

    @Test func manualLinksSurviveUnknownTeam() {
        var links = LinearTaskLinks()
        links.manual = [LinearIssueRef(identifier: "ZZZ-1")]
        let issues = resolve(links: links)
        #expect(issues.map(\.identifier) == ["ZZZ-1"])
        #expect(issues.first?.role == .working)
    }

    @Test func promotionAndBranchAreWorking() {
        var links = LinearTaskLinks()
        links.promoted = [LinearIssueRef(identifier: "PLUME-5")]
        let issues = resolve([evidence("PLUME-5"), evidence("PLUME-6")], branch: ["PLUME-7"], links: links)
        #expect(issues.map(\.role) == [.working, .working, .mentioned])
        #expect(issues.map(\.identifier) == ["PLUME-7", "PLUME-5", "PLUME-6"])
    }

    @Test func anUnlinkedIssueWithNoEvidenceIsMentioned() {
        var links = LinearTaskLinks()
        links.unlink("PLUME-1")
        let issues = resolve(links: links)
        #expect(issues.map(\.identifier) == ["PLUME-1"])
        #expect(issues.first?.role == .mentioned)
        #expect(issues.first?.sources.contains(.unlinked) == true)
    }

    @Test func anUnlinkedBranchIssueIsMentioned() {
        var links = LinearTaskLinks()
        links.unlink("PLUME-1")
        let issues = resolve(branch: ["PLUME-1"], links: links)
        #expect(issues.first?.role == .mentioned)
    }

    @Test func anUnlinkedIssueStaysMentionedDespiteStartEvidence() {
        var links = LinearTaskLinks()
        links.unlink("PLUME-1")
        let issues = resolve([evidence("PLUME-1", tool: "save_issue", state: "started")], links: links)
        #expect(issues.map(\.role) == [.mentioned])
    }

    @Test func persistedAgentStartedIsWorking() {
        var links = LinearTaskLinks()
        links.agentStarted = [LinearIssueRef(identifier: "PLUME-3")]
        #expect(resolve(links: links).first?.role == .working)
    }

    @Test func foldsSourcesAndSubagents() {
        let other = LinearSubagentRef(id: "a2", label: "Plan")
        let issues = resolve(
            [evidence("PLUME-1", sub: sub), evidence("PLUME-1", sub: other), evidence("PLUME-1", sub: sub)],
            branch: ["PLUME-1"]
        )
        #expect(issues.count == 1)
        #expect(issues[0].sources == [.branch, .agent])
        #expect(issues[0].subagents == [sub, other])
        #expect(!issues[0].touchedByMainAgent)

        let main = resolve([evidence("PLUME-1", sub: sub), evidence("PLUME-1")])
        #expect(main[0].touchedByMainAgent)
    }

    @Test func orderingWithinRoleFollowsBestSourceThenAppearance() {
        var links = LinearTaskLinks()
        links.manual = [LinearIssueRef(identifier: "PLUME-9"), LinearIssueRef(identifier: "PLUME-8")]
        let issues = resolve(
            [evidence("PLUME-4"), evidence("PLUME-3"), evidence("PLUME-2", tool: "save_issue", state: "started")],
            branch: ["PLUME-1"],
            links: links
        )
        #expect(issues.map(\.identifier) == ["PLUME-9", "PLUME-8", "PLUME-1", "PLUME-2", "PLUME-4", "PLUME-3"])
    }

    @Test func startedIdentifiersListsOnlyStartRequests() {
        let started = LinearLinkResolver.startedIdentifiers(
            evidence: [
                evidence("PLUME-1", tool: "save_issue", state: "In Progress"),
                evidence("PLUME-2", tool: "save_issue", state: "Done"),
                evidence("PLUME-3", tool: "get_issue"),
                evidence("OTHER-4", tool: "save_issue", state: "started"),
            ],
            catalogs: [catalog]
        )
        #expect(started == ["PLUME-1"])
    }

    @Test func startedIdentifiersSkipPendingAndFailedCalls() {
        let started = LinearLinkResolver.startedIdentifiers(
            evidence: [
                evidence("PLUME-1", tool: "save_issue", state: "In Progress", outcome: .pending),
                evidence("PLUME-2", tool: "save_issue", state: "In Progress", outcome: .failed),
                evidence("PLUME-3", tool: "save_issue", state: "In Progress"),
            ],
            catalogs: [catalog]
        )
        #expect(started == ["PLUME-3"])
    }

    @Test func aFailedStartRequestIsOnlyMentioned() {
        let issues = resolve([evidence("PLUME-1", tool: "save_issue", state: "In Progress", outcome: .failed)])
        #expect(issues.first?.role == .mentioned)
    }
}
