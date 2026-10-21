import Foundation
import Testing
@testable import Plume

struct LinearStateGroupsTests {
    private func state(_ name: String, _ type: LinearStateType, _ color: String = "#aaaaaa", id: String? = nil) -> LinearWorkflowState {
        LinearWorkflowState(id: id ?? name, name: name, type: type, color: color)
    }

    private func team(_ key: String, _ states: [LinearWorkflowState]) -> LinearTeam {
        let renamed = states.map { LinearWorkflowState(id: "\(key)-\($0.id)", name: $0.name, type: $0.type, color: $0.color) }
        return LinearTeam(id: "team-\(key)", key: key, name: key, states: renamed)
    }

    private func groups(_ teams: [LinearTeam]) -> LinearStateGroups {
        LinearStateGroups(catalog: LinearCatalog(orgID: "org", teams: teams, fetchedAt: Date()))
    }

    private func names(_ section: LinearStateGroups.Section) -> [String] {
        section.entries.map(\.state.name)
    }

    private let common: [LinearWorkflowState] = [
        LinearWorkflowState(id: "1", name: "Todo", type: .unstarted, color: "#e2e2e2"),
        LinearWorkflowState(id: "2", name: "Done", type: .completed, color: "#5e6ad2"),
    ]

    @Test func oneTeamYieldsASingleOnlyTeamSectionInCategoryThenNameOrder() {
        let result = groups([team("A", [
            state("Canceled", .canceled), state("Done", .completed), state("In Review", .started),
            state("In Progress", .started), state("Todo", .unstarted), state("Backlog", .backlog),
            state("Triage", .triage),
        ])])

        #expect(result.sections.count == 1)
        #expect(result.sections[0].kind == .onlyTeam)
        #expect(names(result.sections[0]) == [
            "Triage", "Backlog", "Todo", "In Progress", "In Review", "Done", "Canceled",
        ])
    }

    @Test func identicalStatesAcrossTeamsFormOneSharedSection() {
        let result = groups([team("B", common), team("A", common)])

        #expect(result.sections.count == 1)
        #expect(result.sections[0].kind == .sharedByTeams)
        #expect(names(result.sections[0]) == ["Todo", "Done"])
        #expect(result.sections[0].entries.allSatisfy { $0.teamKeys == ["A", "B"] })
    }

    @Test func colorsDifferingOnlyInCaseAreIdentical() {
        let a = team("A", [state("Todo", .unstarted, "#E2E2E2")])
        let b = team("B", [state("Todo", .unstarted, "#e2e2e2")])
        let result = groups([a, b])

        #expect(result.sections.map(\.kind) == [.sharedByTeams])
        #expect(result.sections[0].entries.count == 1)
        #expect(result.sections[0].entries[0].teamKeys == ["A", "B"])
    }

    @Test func aStateOnlyOneTeamHasGetsItsOwnSection() {
        let a = team("A", common)
        let b = team("B", common + [state("QA", .started, "#123456")])
        let result = groups([a, b])

        #expect(result.sections.map(\.kind) == [.sharedByTeams, .team(b)])
        #expect(names(result.sections[0]) == ["Todo", "Done"])
        #expect(names(result.sections[1]) == ["QA"])
        #expect(result.sections[1].entries[0].teamKeys == ["B"])
    }

    @Test func aRedefinedColorMovesTheStateToItsTeamsSections() {
        let a = team("A", common)
        let b = team("B", [common[0], state("Done", .completed, "#00ff00")])
        let result = groups([a, b])

        #expect(result.sections.map(\.kind) == [.sharedByTeams, .team(a), .team(b)])
        #expect(names(result.sections[0]) == ["Todo"])
        #expect(names(result.sections[1]) == ["Done"])
        #expect(names(result.sections[2]) == ["Done"])
        #expect(result.sections[2].entries[0].state.color == "#00ff00")
    }

    @Test func aTeamWithNothingOfItsOwnGetsNoSection() {
        let a = team("A", [common[0]])
        let b = team("B", common)
        let result = groups([a, b])

        #expect(result.sections.map(\.kind) == [.sharedByTeams, .team(b)])
        #expect(names(result.sections[1]) == ["Done"])
    }

    @Test func teamSectionsAreOrderedByTeamKey() {
        let c = team("C", [state("Only C", .started)])
        let a = team("A", [state("Only A", .started)])
        let b = team("B", [state("Only B", .started)])
        let result = groups([c, a, b])

        #expect(result.sections.map(\.kind) == [.team(a), .team(b), .team(c)])
    }

    @Test func anEmptyCatalogHasNoSections() {
        #expect(groups([]).sections.isEmpty)
        #expect(groups([team("A", [])]).sections.isEmpty)
    }
}
