import AppKit
import Testing

@testable import Plume

@MainActor
struct LinearStartedProgressTests {
    @Test(arguments: [
        (1.0, [1.0], LinearStartedProgress.half),
        (1.0, [1.0, 2.0], .half),
        (2.0, [1.0, 2.0], .threeQuarters),
        (1.0, [1.0, 2.0, 3.0], .quarter),
        (2.0, [1.0, 2.0, 3.0], .half),
        (3.0, [1.0, 2.0, 3.0], .threeQuarters),
        (2.0, [1.0, 2.0, 3.0, 4.0], .half),
        (3.0, [1.0, 2.0, 3.0, 4.0], .half),
        (4.0, [1.0, 2.0, 3.0, 4.0], .threeQuarters),
        (5.0, [], .half),
    ])
    func rankPicksFill(position: Double, positions: [Double], expected: LinearStartedProgress) {
        #expect(LinearStartedProgress(position: position, among: positions) == expected)
    }

    @Test(arguments: [LinearStartedProgress.quarter, .half, .threeQuarters])
    func everyFillDrawsTheProgressGlyph(progress: LinearStartedProgress) {
        #expect(LinearIssueGlyph.glyph(for: .started, progress: progress) == .linearProgress(progress))
    }

    @Test(arguments: [LinearStateType.backlog, .unstarted, .completed, .canceled, .duplicate, .triage, .other("custom")])
    func everyOtherStateNamesARealSymbol(stateType: LinearStateType) {
        guard case .symbol(let name) = LinearIssueGlyph.glyph(for: stateType, progress: .half) else {
            Issue.record("\(stateType) draws no symbol")
            return
        }
        #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil)
    }

    private func catalog(_ orgID: String, positions: [Double]) -> LinearCatalog {
        let states = positions.enumerated().map {
            LinearWorkflowState(id: "\(orgID)\($0.offset)", name: "S\($0.offset)", type: .started, color: "#000000", position: $0.element)
        }
        return LinearCatalog(orgID: orgID, teams: [LinearTeam(id: orgID, key: "PLUME", name: "Plume", states: states)], fetchedAt: Date())
    }

    @Test func theFirstCatalogDefiningTheTeamDecides() {
        let catalogs = [catalog("A", positions: [1, 2]), catalog("B", positions: [1, 2, 3])]
        #expect(LinearStartedProgress(stateType: .started, position: 2, teamKey: "plume", catalogs: catalogs) == .threeQuarters)
        #expect(LinearStartedProgress(stateType: .started, position: 2, teamKey: "PLUME", catalogs: Array(catalogs.reversed())) == .half)
    }

    @Test func anythingUnresolvableReadsAsHalf() {
        let catalogs = [catalog("A", positions: [1, 2, 3])]
        #expect(LinearStartedProgress(stateType: .unstarted, position: 1, teamKey: "PLUME", catalogs: catalogs) == .half)
        #expect(LinearStartedProgress(stateType: .started, position: nil, teamKey: "PLUME", catalogs: catalogs) == .half)
        #expect(LinearStartedProgress(stateType: .started, position: 1, teamKey: "DROID", catalogs: catalogs) == .half)
        #expect(LinearStartedProgress(stateType: .started, position: 1, teamKey: "PLUME", catalogs: []) == .half)
    }

    @Test func aStateGroupEntryCarriesItsTeamsProgress() {
        let groups = LinearStateGroups(catalog: catalog("A", positions: [1, 2, 3]))
        let entries = groups.sections.flatMap(\.entries).sorted { ($0.state.position ?? 0) < ($1.state.position ?? 0) }
        #expect(entries.map(\.startedProgress) == [.quarter, .half, .threeQuarters])
    }
}
