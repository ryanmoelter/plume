import Testing
import Foundation
@testable import Plume

@MainActor
struct LinearAccountsTests {
    private func makeAccounts(
        _ workspaces: [String: FakeLinearWorkspace],
        defaults: UserDefaults = LinearTestFixtures.scratchDefaults(),
        secrets: InMemorySecretStore = InMemorySecretStore()
    ) -> LinearAccounts {
        LinearAccounts(defaults: defaults, secrets: secrets, clientFactory: LinearTestFixtures.factory(workspaces))
    }

    @Test func addingAVerifiedKeyStoresItUnderTheOrgAndPersistsTheAccount() async throws {
        let workspace = FakeLinearWorkspace(orgID: "org-1", teamKeys: ["PLUME"])
        let defaults = LinearTestFixtures.scratchDefaults()
        let secrets = InMemorySecretStore()
        let accounts = makeAccounts(["key-1": workspace], defaults: defaults, secrets: secrets)

        let account = try await accounts.add(apiKey: "  key-1\n")

        #expect(account.orgID == "org-1")
        #expect(accounts.apiKey(for: "org-1") == "key-1")
        let reloaded = makeAccounts([:], defaults: defaults, secrets: secrets)
        #expect(reloaded.accounts == [account])
    }

    @Test func aRejectedKeyStoresNothing() async {
        let workspace = FakeLinearWorkspace(orgID: "org-1", teamKeys: ["PLUME"])
        await workspace.set(viewerError: LinearError.unauthorized)
        let accounts = makeAccounts(["bad": workspace])

        await #expect(throws: LinearError.unauthorized) {
            try await accounts.add(apiKey: "bad")
        }
        #expect(accounts.accounts.isEmpty)
        #expect(accounts.apiKey(for: "org-1") == nil)
    }

    @Test func aSecondKeyForTheSameOrgReplacesTheFirst() async throws {
        let workspace = FakeLinearWorkspace(orgID: "org-1", teamKeys: ["PLUME"])
        let accounts = makeAccounts(["old": workspace, "new": workspace])
        var changes: [LinearAccounts.Change] = []
        accounts.onChange = { changes.append($0) }

        try await accounts.add(apiKey: "old")
        try await accounts.add(apiKey: "new")

        #expect(accounts.accounts.count == 1)
        #expect(accounts.apiKey(for: "org-1") == "new")
        #expect(changes == [.keyChanged(orgID: "org-1"), .keyChanged(orgID: "org-1")])
    }

    @Test func removingAnAccountDeletesItsKey() async throws {
        let workspace = FakeLinearWorkspace(orgID: "org-1", teamKeys: ["PLUME"])
        let defaults = LinearTestFixtures.scratchDefaults()
        let secrets = InMemorySecretStore()
        let accounts = makeAccounts(["key-1": workspace], defaults: defaults, secrets: secrets)
        try await accounts.add(apiKey: "key-1")

        accounts.remove(orgID: "org-1")

        #expect(accounts.accounts.isEmpty)
        #expect(accounts.apiKey(for: "org-1") == nil)
        #expect(makeAccounts([:], defaults: defaults, secrets: secrets).accounts.isEmpty)
    }

    @Test func ownersAreTheCatalogsHoldingTheTeamKeyInOrder() {
        let a = LinearCatalog(orgID: "A", teams: [LinearTestFixtures.team(key: "PLUME")], fetchedAt: Date())
        let b = LinearCatalog(orgID: "B", teams: [LinearTestFixtures.team(key: "DROID"), LinearTestFixtures.team(key: "PLUME")], fetchedAt: Date())

        #expect(LinearAccounts.owners(ofTeamKey: "plume", catalogs: [a, b]) == ["A", "B"])
        #expect(LinearAccounts.owners(ofTeamKey: "DROID", catalogs: [a, b]) == ["B"])
        #expect(LinearAccounts.owners(ofTeamKey: "ZZZ", catalogs: [a, b]).isEmpty)
    }
}
