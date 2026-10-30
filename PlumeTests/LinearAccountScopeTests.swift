import Foundation
import Testing
@testable import Plume

struct LinearAccountScopeTests {
    private func account(_ orgID: String) -> LinearAccount {
        LinearAccount(orgID: orgID, orgName: orgID, urlKey: orgID, viewerName: "Ryan")
    }

    @Test func nilSelectionKeepsEveryAccount() {
        let accounts = [account("a"), account("b")]
        #expect(LinearAccountScope.filter(accounts, allowing: nil) == accounts)
    }

    @Test func selectionKeepsOnlyNamedAccountsInOrder() {
        let accounts = [account("a"), account("b"), account("c")]
        #expect(LinearAccountScope.filter(accounts, allowing: ["c", "a"]).map(\.orgID) == ["a", "c"])
        #expect(LinearAccountScope.filter(accounts, allowing: []).isEmpty)
    }

    @Test func projectSelectionOverridesTheDefaultsRow() {
        let configuration = ProjectsConfiguration(
            defaults: ProjectSettings(linearOrgIDs: ["a"]),
            repositories: ["/p": ProjectSettings(linearOrgIDs: ["b"]), "/q": ProjectSettings()]
        )
        #expect(LinearAccountScope.allowedOrgIDs(root: "/p", configuration: configuration) == ["b"])
        #expect(LinearAccountScope.allowedOrgIDs(root: "/q", configuration: configuration) == ["a"])
        #expect(LinearAccountScope.allowedOrgIDs(root: "/other", configuration: configuration) == ["a"])
        #expect(LinearAccountScope.allowedOrgIDs(root: nil, configuration: configuration) == ["a"])
    }

    @Test func unsetEverywhereMeansAll() {
        let configuration = ProjectsConfiguration(repositories: ["/p": ProjectSettings(branchPrefix: "x/")])
        #expect(LinearAccountScope.allowedOrgIDs(root: "/p", configuration: configuration) == nil)
    }

    @Test func bareLayoutRepositoryMapsToItsProjectFolder() {
        let configuration = ProjectsConfiguration(repositories: ["/p": ProjectSettings(linearOrgIDs: ["b"])])
        #expect(LinearAccountScope.allowedOrgIDs(repository: "/p/.bare", configuration: configuration) == ["b"])
        #expect(LinearAccountScope.allowedOrgIDs(repository: "/p", configuration: configuration) == ["b"])
    }

    @Test func togglingOffNarrowsAndOnBackToAllClearsTheSelection() {
        let connected = ["a", "b"]
        let narrowed = LinearAccountScope.toggling("b", on: false, selection: nil, connected: connected)
        #expect(narrowed == ["a"])
        #expect(LinearAccountScope.toggling("b", on: true, selection: narrowed, connected: connected) == nil)
    }

    @Test func settingsRoundTripKeepsTheSelection() throws {
        let configuration = ProjectsConfiguration(repositories: ["/p": ProjectSettings(linearOrgIDs: ["b"])])
        let decoded = try JSONDecoder().decode(ProjectsConfiguration.self, from: JSONEncoder().encode(configuration))
        #expect(decoded == configuration)
    }
}
