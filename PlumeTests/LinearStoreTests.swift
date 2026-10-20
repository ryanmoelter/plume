import Testing
import Foundation
import SwiftData
@testable import Plume

/// Routing, batching and failure handling across several fake workspaces,
/// with no Keychain and no network.
@MainActor
struct LinearStoreTests {
    private struct Harness {
        let store: LinearStore
        let accounts: LinearAccounts
    }

    /// Accounts are added in `workspaces` order, which is the order a shared
    /// team key's workspaces are tried in. The key for each is `key-<orgID>`.
    private func makeHarness(
        _ workspaces: [FakeLinearWorkspace],
        cacheDirectory: URL? = nil,
        now: @escaping () -> Date = Date.init
    ) async throws -> Harness {
        var byKey: [String: FakeLinearWorkspace] = [:]
        for workspace in workspaces { byKey["key-\(workspace.account.orgID)"] = workspace }
        let accounts = LinearAccounts(
            defaults: LinearTestFixtures.scratchDefaults(),
            secrets: InMemorySecretStore(),
            clientFactory: LinearTestFixtures.factory(byKey)
        )
        let store = LinearStore(accounts: accounts, cacheDirectory: cacheDirectory, now: now)
        for workspace in workspaces {
            try await accounts.add(apiKey: "key-\(workspace.account.orgID)")
        }
        await store.settle()
        return Harness(store: store, accounts: accounts)
    }

    private func waitForIssueCalls(_ workspace: FakeLinearWorkspace, count: Int) async {
        for _ in 0..<1_000 where await workspace.issueCalls.count < count {
            await Task.yield()
        }
    }

    @Test func eachIdentifierGoesOnlyToTheWorkspaceOwningItsTeamKey() async throws {
        let a = FakeLinearWorkspace(orgID: "A", teamKeys: ["PLUME"])
        let b = FakeLinearWorkspace(orgID: "B", teamKeys: ["DROID"])
        let harness = try await makeHarness([a, b])

        harness.store.setWanted(["PLUME-1", "DROID-2"], owner: UUID())
        await harness.store.settle()

        #expect(await a.issueCalls == [["PLUME-1"]])
        #expect(await b.issueCalls == [["DROID-2"]])
    }

    @Test func aSharedTeamKeyQueriesBothAndKeepsTheOneThatFindsIt() async throws {
        let a = FakeLinearWorkspace(orgID: "A", teamKeys: ["PLUME"])
        let b = FakeLinearWorkspace(orgID: "B", teamKeys: ["PLUME"])
        let issue = LinearTestFixtures.issue("PLUME-1", title: "From B")
        await b.set(issues: ["PLUME-1": issue])
        let harness = try await makeHarness([a, b])

        harness.store.setWanted(["PLUME-1"], owner: UUID())
        await harness.store.settle()
        #expect(harness.store.state(for: "PLUME-1") == .issue(issue))
        #expect(await a.issueCalls.count == 1)
        #expect(await b.issueCalls.count == 1)

        harness.store.poll()
        await harness.store.settle()
        #expect(await a.issueCalls.count == 1)
        #expect(await b.issueCalls.count == 2)
    }

    @Test func aSharedTeamKeyIsNotFoundOnlyOnceEveryWorkspaceSaysSo() async throws {
        let a = FakeLinearWorkspace(orgID: "A", teamKeys: ["PLUME"])
        let b = FakeLinearWorkspace(orgID: "B", teamKeys: ["PLUME"])
        let harness = try await makeHarness([a, b])

        harness.store.setWanted(["PLUME-9"], owner: UUID())
        await harness.store.settle()
        #expect(harness.store.state(for: "PLUME-9") == .notFound)
    }

    @Test func wantsFromManyOwnersInOneTurnShareOneRequest() async throws {
        let a = FakeLinearWorkspace(orgID: "A", teamKeys: ["PLUME"])
        let harness = try await makeHarness([a])

        harness.store.setWanted(["PLUME-1"], owner: UUID())
        harness.store.setWanted(["PLUME-2"], owner: UUID())
        harness.store.setWanted(["PLUME-3", "PLUME-1"], owner: UUID())
        await harness.store.settle()

        #expect(await a.issueCalls == [["PLUME-1", "PLUME-2", "PLUME-3"]])
    }

    @Test func aWorkspaceHasOneRequestInFlightAndQueuesTheRest() async throws {
        let a = FakeLinearWorkspace(orgID: "A", teamKeys: ["PLUME"])
        let harness = try await makeHarness([a])
        await a.holdIssueFetches()

        harness.store.setWanted(["PLUME-1"], owner: UUID())
        await waitForIssueCalls(a, count: 1)
        harness.store.setWanted(["PLUME-2"], owner: UUID())
        harness.store.setWanted(["PLUME-3"], owner: UUID())
        for _ in 0..<50 { await Task.yield() }
        #expect(await a.issueCalls.count == 1)

        await a.releaseIssueFetches()
        await harness.store.settle()
        #expect(await a.issueCalls == [["PLUME-1"], ["PLUME-2", "PLUME-3"]])
    }

    @Test func anUnchangedAnswerIsNotRepublished() async throws {
        let a = FakeLinearWorkspace(orgID: "A", teamKeys: ["PLUME"])
        await a.set(issues: ["PLUME-1": LinearTestFixtures.issue("PLUME-1")])
        let harness = try await makeHarness([a])
        harness.store.setWanted(["PLUME-1"], owner: UUID())
        await harness.store.settle()

        var publishes = 0
        withObservationTracking {
            _ = harness.store.state(for: "PLUME-1")
        } onChange: {
            publishes += 1
        }
        harness.store.poll()
        await harness.store.settle()

        #expect(await a.issueCalls.count == 2)
        #expect(publishes == 0)
    }

    @Test func aFailureKeepsTheLastGoodIssueAsStale() async throws {
        let a = FakeLinearWorkspace(orgID: "A", teamKeys: ["PLUME"])
        let issue = LinearTestFixtures.issue("PLUME-1")
        await a.set(issues: ["PLUME-1": issue])
        let harness = try await makeHarness([a])
        harness.store.setWanted(["PLUME-1"], owner: UUID())
        await harness.store.settle()

        await a.set(issueError: LinearError.failed("boom"))
        harness.store.poll()
        await harness.store.settle()

        #expect(harness.store.state(for: "PLUME-1") == .stale(issue, reason: "boom"))
        #expect(harness.store.accountStatus(orgID: "A") == .failed("boom"))
    }

    @Test func aRateLimitedWorkspacePausesAloneUntilItsReset() async throws {
        let until = Date().addingTimeInterval(600)
        let a = FakeLinearWorkspace(orgID: "A", teamKeys: ["PLUME"])
        let b = FakeLinearWorkspace(orgID: "B", teamKeys: ["DROID"])
        await a.set(issueError: LinearError.rateLimited(until: until))
        let harness = try await makeHarness([a, b])

        harness.store.setWanted(["PLUME-1", "DROID-1"], owner: UUID())
        await harness.store.settle()
        #expect(harness.store.state(for: "PLUME-1") == .rateLimited(until: until))
        #expect(harness.store.accountStatus(orgID: "A") == .rateLimited(until: until))
        #expect(harness.store.state(for: "DROID-1") == .notFound)

        harness.store.poll()
        harness.store.setWanted(["PLUME-2"], owner: UUID())
        await harness.store.settle()
        #expect(await a.issueCalls.count == 1)
        #expect(await b.issueCalls.count == 2)
    }

    @Test func aLowBudgetSkipsOnlyThatWorkspacesPolls() async throws {
        let a = FakeLinearWorkspace(orgID: "A", teamKeys: ["PLUME"])
        let b = FakeLinearWorkspace(orgID: "B", teamKeys: ["DROID"])
        await a.set(rateLimit: LinearRateLimit(limit: 1_500, remaining: 100, resetAt: Date().addingTimeInterval(600)))
        await b.set(rateLimit: LinearRateLimit(limit: 1_500, remaining: 1_400, resetAt: Date().addingTimeInterval(600)))
        let harness = try await makeHarness([a, b])
        harness.store.setWanted(["PLUME-1", "DROID-1"], owner: UUID())
        await harness.store.settle()

        harness.store.poll()
        await harness.store.settle()

        #expect(await a.issueCalls.count == 1)
        #expect(await b.issueCalls.count == 2)
    }

    @Test func anUnauthorizedWorkspaceStopsAloneUntilItsKeyChanges() async throws {
        let a = FakeLinearWorkspace(orgID: "A", teamKeys: ["PLUME"])
        let b = FakeLinearWorkspace(orgID: "B", teamKeys: ["DROID"])
        await a.set(issueError: LinearError.unauthorized)
        let harness = try await makeHarness([a, b])

        harness.store.setWanted(["PLUME-1", "DROID-1"], owner: UUID())
        await harness.store.settle()
        #expect(harness.store.state(for: "PLUME-1") == .unauthorized)
        #expect(harness.store.accountStatus(orgID: "A") == .unauthorized)
        #expect(harness.store.accountStatus(orgID: "B") == .connected)

        harness.store.poll()
        harness.store.setWanted(["PLUME-2"], owner: UUID())
        await harness.store.settle()
        #expect(await a.issueCalls.count == 1)
        #expect(await b.issueCalls.count == 2)
        #expect(harness.store.state(for: "PLUME-2") == .unauthorized)

        let issue = LinearTestFixtures.issue("PLUME-1")
        await a.set(issueError: nil)
        await a.set(issues: ["PLUME-1": issue])
        try await harness.accounts.add(apiKey: "key-A")
        await harness.store.settle()
        #expect(harness.store.state(for: "PLUME-1") == .issue(issue))
        #expect(harness.store.accountStatus(orgID: "A") == .connected)
    }

    @Test func releasingTheLastOwnerKeepsTheStateAndStopsPollingIt() async throws {
        let a = FakeLinearWorkspace(orgID: "A", teamKeys: ["PLUME"])
        let issue = LinearTestFixtures.issue("PLUME-1")
        await a.set(issues: ["PLUME-1": issue])
        let harness = try await makeHarness([a])
        let first = UUID()
        let second = UUID()
        harness.store.setWanted(["PLUME-1"], owner: first)
        harness.store.setWanted(["PLUME-1"], owner: second)
        await harness.store.settle()

        harness.store.setWanted([], owner: first)
        harness.store.setWanted([], owner: second)
        harness.store.poll()
        await harness.store.settle()

        #expect(harness.store.state(for: "PLUME-1") == .issue(issue))
        #expect(await a.issueCalls.count == 1)
    }

    @Test func aRowComingBackWithinAPollIntervalDoesNotRefetch() async throws {
        let clock = TestClock()
        let a = FakeLinearWorkspace(orgID: "A", teamKeys: ["PLUME"])
        let issue = LinearTestFixtures.issue("PLUME-1")
        await a.set(issues: ["PLUME-1": issue])
        let harness = try await makeHarness([a], now: clock.now)
        let row = UUID()
        harness.store.setWanted(["PLUME-1"], owner: row)
        await harness.store.settle()

        harness.store.setWanted([], owner: row)
        clock.advance(LinearStore.pollInterval - 1)
        harness.store.setWanted(["PLUME-1"], owner: row)
        await harness.store.settle()
        #expect(harness.store.state(for: "PLUME-1") == .issue(issue))
        #expect(await a.issueCalls.count == 1)

        harness.store.setWanted([], owner: row)
        clock.advance(2)
        harness.store.setWanted(["PLUME-1"], owner: row)
        #expect(harness.store.state(for: "PLUME-1") == .issue(issue))
        await harness.store.settle()
        #expect(await a.issueCalls.count == 2)
    }

    @Test func anActivationPollIsSkippedWithinAMinuteOfTheLastPoll() async throws {
        let clock = TestClock()
        let a = FakeLinearWorkspace(orgID: "A", teamKeys: ["PLUME"])
        let harness = try await makeHarness([a], now: clock.now)
        harness.store.setWanted(["PLUME-1"], owner: UUID())
        await harness.store.settle()
        harness.store.poll()
        await harness.store.settle()
        #expect(await a.issueCalls.count == 2)

        clock.advance(LinearStore.activationPollInterval - 1)
        harness.store.pollOnActivation()
        await harness.store.settle()
        #expect(await a.issueCalls.count == 2)

        clock.advance(2)
        harness.store.pollOnActivation()
        await harness.store.settle()
        #expect(await a.issueCalls.count == 3)
    }

    @Test func anAnswerFromARemovedKeyNeverApplies() async throws {
        let old = FakeLinearWorkspace(orgID: "A", teamKeys: ["PLUME"])
        let new = FakeLinearWorkspace(orgID: "A", teamKeys: ["PLUME"])
        let issue = LinearTestFixtures.issue("PLUME-1")
        await old.set(issueError: LinearError.unauthorized)
        await new.set(issues: ["PLUME-1": issue])
        let accounts = LinearAccounts(
            defaults: LinearTestFixtures.scratchDefaults(),
            secrets: InMemorySecretStore(),
            clientFactory: LinearTestFixtures.factory(["old": old, "new": new])
        )
        let store = LinearStore(accounts: accounts, cacheDirectory: nil)
        try await accounts.add(apiKey: "old")
        await store.settle()
        await old.holdIssueFetches()
        store.setWanted(["PLUME-1"], owner: UUID())
        await waitForIssueCalls(old, count: 1)

        accounts.remove(orgID: "A")
        try await accounts.add(apiKey: "new")
        await waitForIssueCalls(new, count: 1)
        await old.releaseIssueFetches()
        await store.settle()

        #expect(store.state(for: "PLUME-1") == .issue(issue))
        #expect(store.accountStatus(orgID: "A") == .connected)
        #expect(await new.catalogCalls == 1)
    }

    @Test func aSharedKeyBlockedInOneWorkspaceAndMissingInTheOtherPublishesTheBlocker() async throws {
        let a = FakeLinearWorkspace(orgID: "A", teamKeys: ["PLUME"])
        let b = FakeLinearWorkspace(orgID: "B", teamKeys: ["PLUME"])
        await a.set(issueError: LinearError.unauthorized)
        let harness = try await makeHarness([a, b])
        harness.store.setWanted(["PLUME-1"], owner: UUID())
        await harness.store.settle()
        #expect(harness.store.accountStatus(orgID: "A") == .unauthorized)

        harness.store.setWanted(["PLUME-9"], owner: UUID())
        await harness.store.settle()

        #expect(harness.store.state(for: "PLUME-9") == .unauthorized)
        #expect(await a.issueCalls.count == 1)
    }

    @Test func anErrorScopedToOneIssueKeepsItStale() async throws {
        let a = FakeLinearWorkspace(orgID: "A", teamKeys: ["PLUME"])
        let issue = LinearTestFixtures.issue("PLUME-1")
        let other = LinearTestFixtures.issue("PLUME-2")
        await a.set(issues: ["PLUME-1": issue, "PLUME-2": other])
        let harness = try await makeHarness([a])
        harness.store.setWanted(["PLUME-1", "PLUME-2"], owner: UUID())
        await harness.store.settle()

        await a.set(issues: ["PLUME-2": other])
        await a.set(issueFailures: ["PLUME-1": "Internal error"])
        harness.store.poll()
        await harness.store.settle()

        #expect(harness.store.state(for: "PLUME-1") == .stale(issue, reason: "Internal error"))
        #expect(harness.store.state(for: "PLUME-2") == .issue(other))
        #expect(harness.store.accountStatus(orgID: "A") == .connected)
    }

    @Test func aFetchCancelledByResetAppliesNothing() async throws {
        let a = FakeLinearWorkspace(orgID: "A", teamKeys: ["PLUME"])
        await a.set(issues: ["PLUME-1": LinearTestFixtures.issue("PLUME-1")])
        let harness = try await makeHarness([a])
        await a.holdIssueFetches()
        harness.store.setWanted(["PLUME-1"], owner: UUID())
        await waitForIssueCalls(a, count: 1)

        harness.store.reset()
        await a.releaseIssueFetches()
        for _ in 0..<200 { await Task.yield() }

        #expect(harness.store.accountStatus(orgID: "A") == .unknown)
        #expect(harness.store.state(for: "PLUME-1") == nil)
    }

    @Test func oneIssuesChangeDoesNotInvalidateAnotherIssuesReader() async throws {
        let a = FakeLinearWorkspace(orgID: "A", teamKeys: ["PLUME"])
        await a.set(issues: ["PLUME-1": LinearTestFixtures.issue("PLUME-1"), "PLUME-2": LinearTestFixtures.issue("PLUME-2")])
        let harness = try await makeHarness([a])
        harness.store.setWanted(["PLUME-1", "PLUME-2"], owner: UUID())
        await harness.store.settle()

        var invalidations = 0
        withObservationTracking {
            _ = harness.store.state(for: "PLUME-1")
        } onChange: {
            invalidations += 1
        }
        let renamed = LinearTestFixtures.issue("PLUME-2", title: "Renamed")
        await a.set(issues: ["PLUME-1": LinearTestFixtures.issue("PLUME-1"), "PLUME-2": renamed])
        harness.store.poll()
        await harness.store.settle()

        #expect(harness.store.state(for: "PLUME-2") == .issue(renamed))
        #expect(invalidations == 0)
    }

    @Test func aTeamKeyNoCatalogHasIsNoWorkspaceAndNeverFetched() async throws {
        let a = FakeLinearWorkspace(orgID: "A", teamKeys: ["PLUME"])
        let harness = try await makeHarness([a])

        harness.store.setWanted(["ZZZ-1"], owner: UUID())
        await harness.store.settle()

        #expect(harness.store.state(for: "ZZZ-1") == .noWorkspace)
        #expect(await a.issueCalls.isEmpty)
    }

    @Test func aNewWriteRefetchesItsIssueEarly() async throws {
        let a = FakeLinearWorkspace(orgID: "A", teamKeys: ["PLUME"])
        let harness = try await makeHarness([a])
        let tab = UUID()
        harness.store.setWanted(["PLUME-1"], owner: UUID())
        await harness.store.settle()

        let write = LinearEvidence(identifier: "PLUME-1", tool: "save_issue", requestedState: "Done", subagent: nil, outcome: .succeeded)
        harness.store.replaceActivity(tabID: tab, evidence: [write])
        await harness.store.settle()
        harness.store.replaceActivity(tabID: tab, evidence: [write])
        await harness.store.settle()

        #expect(await a.issueCalls.count == 2)
    }

    @Test func aWriteRefetchesOnlyOnceItsResultArrives() async throws {
        let a = FakeLinearWorkspace(orgID: "A", teamKeys: ["PLUME"])
        let harness = try await makeHarness([a])
        let tab = UUID()
        harness.store.setWanted(["PLUME-1"], owner: UUID())
        await harness.store.settle()

        let pending = LinearEvidence(identifier: "PLUME-1", tool: "save_issue", requestedState: "Done", subagent: nil, outcome: .pending)
        harness.store.replaceActivity(tabID: tab, evidence: [pending])
        await harness.store.settle()
        #expect(await a.issueCalls.count == 1)

        let landed = LinearEvidence(identifier: "PLUME-1", tool: "save_issue", requestedState: "Done", subagent: nil, outcome: .succeeded)
        harness.store.replaceActivity(tabID: tab, evidence: [landed])
        await harness.store.settle()
        #expect(await a.issueCalls.count == 2)
    }

    @Test func aStartRequestIsReportedOnlyOnceItSucceeds() async throws {
        let a = FakeLinearWorkspace(orgID: "A", teamKeys: ["PLUME"])
        let harness = try await makeHarness([a])
        var reports: [Set<String>] = []
        harness.store.onAgentStarted = { reports.append($1) }
        let tab = UUID()
        func start(_ outcome: LinearCallOutcome) -> LinearEvidence {
            LinearEvidence(identifier: "PLUME-1", tool: "save_issue", requestedState: "In Progress", subagent: nil, outcome: outcome)
        }

        harness.store.replaceActivity(tabID: tab, evidence: [start(.pending)])
        harness.store.replaceActivity(tabID: tab, evidence: [start(.failed)])
        #expect(reports.isEmpty)

        harness.store.replaceActivity(tabID: tab, evidence: [start(.failed), start(.succeeded)])
        #expect(reports == [["PLUME-1"]])
    }

    @Test func anAgentStartedIssueIsReportedOncePerTab() async throws {
        let a = FakeLinearWorkspace(orgID: "A", teamKeys: ["PLUME"])
        let harness = try await makeHarness([a])
        var reports: [(UUID, Set<String>)] = []
        harness.store.onAgentStarted = { reports.append(($0, $1)) }
        let tab = UUID()
        let start = LinearEvidence(identifier: "PLUME-1", tool: "save_issue", requestedState: "In Progress", subagent: nil, outcome: .succeeded)

        harness.store.replaceActivity(tabID: tab, evidence: [start])
        harness.store.replaceActivity(tabID: tab, evidence: [start, start])

        #expect(reports.count == 1)
        #expect(reports.first?.0 == tab)
        #expect(reports.first?.1 == ["PLUME-1"])
    }

    /// A state named rather than typed resolves only once the catalog exists.
    @Test func anAgentStartedIssueIsReportedWhenItsCatalogArrivesLate() async throws {
        let a = FakeLinearWorkspace(orgID: "A", teamKeys: ["PLUME"])
        await a.set(catalogError: LinearError.failed("offline"))
        let harness = try await makeHarness([a])
        var reports: [Set<String>] = []
        harness.store.onAgentStarted = { reports.append($1) }
        let start = LinearEvidence(identifier: "PLUME-1", tool: "save_issue", requestedState: "In Progress", subagent: nil, outcome: .succeeded)

        harness.store.replaceActivity(tabID: UUID(), evidence: [start])
        #expect(reports.isEmpty)

        await a.set(catalogError: nil)
        harness.store.poll()
        await harness.store.settle()

        #expect(reports == [["PLUME-1"]])
    }

    @Test func aCachedCatalogLoadsBeforeTheNetworkAnswers() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "LinearStoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cached = LinearCatalog(orgID: "A", teams: [LinearTestFixtures.team(key: "CACHE")], fetchedAt: Date())
        try JSONEncoder().encode(cached).write(to: directory.appending(path: "catalog-A.json"))

        let a = FakeLinearWorkspace(orgID: "A", teamKeys: ["PLUME"])
        await a.set(catalogError: LinearError.failed("offline"))
        let harness = try await makeHarness([a], cacheDirectory: directory)
        #expect(harness.store.teamKeys.isEmpty)

        harness.store.start()
        defer { harness.store.reset() }
        #expect(harness.store.teamKeys == ["CACHE"])
    }

    @Test func aFetchedCatalogIsWrittenToTheCache() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "LinearStoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = FakeLinearWorkspace(orgID: "A", teamKeys: ["PLUME"])
        _ = try await makeHarness([a], cacheDirectory: directory)

        let data = try Data(contentsOf: directory.appending(path: "catalog-A.json"))
        let catalog = try JSONDecoder().decode(LinearCatalog.self, from: data)
        #expect(catalog.teamKeys == ["PLUME"])
    }

    @Test func anUnknownTeamKeyRefetchesCatalogsAtMostOncePerInterval() async throws {
        let a = FakeLinearWorkspace(orgID: "A", teamKeys: ["PLUME"])
        let harness = try await makeHarness([a])
        #expect(await a.catalogCalls == 1)

        harness.store.refreshCatalogIfUnknown(teamKey: "NEW")
        await harness.store.settle()
        harness.store.refreshCatalogIfUnknown(teamKey: "NEW")
        await harness.store.settle()
        harness.store.refreshCatalogIfUnknown(teamKey: "PLUME")
        await harness.store.settle()

        #expect(await a.catalogCalls == 2)
    }

    @Test func linksFoldBranchAndAgentActivityForATask() async throws {
        let a = FakeLinearWorkspace(orgID: "A", teamKeys: ["PLUME"])
        let harness = try await makeHarness([a])
        let container = try ModelContainer(
            for: Schema([TaskGroup.self, WorkTask.self, TaskTab.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let task = TaskStore.createTask(in: ModelContext(container), siblings: [])
        let tab = try #require(task.tabs.first)
        harness.store.replaceActivity(tabID: tab.id, evidence: [
            LinearEvidence(identifier: "PLUME-7", tool: "get_issue", requestedState: nil, subagent: nil, outcome: .succeeded),
        ])

        let links = harness.store.links(for: task, branches: ["ryanm/plume-102-linear", "other/zzz-1"])

        #expect(links.map(\.identifier) == ["PLUME-102", "PLUME-7"])
        #expect(links.first?.sources == [.branch])
        #expect(links.last?.role == .mentioned)
    }
}

/// A settable clock for `LinearStore`'s `now`.
@MainActor
private final class TestClock {
    private var current = Date(timeIntervalSince1970: 1_700_000_000)

    var now: () -> Date { { [unowned self] in current } }

    func advance(_ interval: TimeInterval) {
        current = current.addingTimeInterval(interval)
    }
}
