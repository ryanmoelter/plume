import Testing
import Foundation
@testable import Plume

/// Records every request so the batching claim — one call per repository, not
/// one per branch — is assertable.
private actor FakeForgeClient: ForgeClient {
    struct Call: Sendable, Equatable {
        let branches: [String]
        let repository: String
    }

    private(set) var calls: [Call] = []
    private let result: [String: PullRequest?]
    private let error: Error?

    init(result: [String: PullRequest?] = [:], error: Error? = nil) {
        self.result = result
        self.error = error
    }

    func fetchPullRequests(
        forBranches branches: [String],
        in repository: String
    ) async throws -> [String: PullRequest?] {
        calls.append(Call(branches: branches.sorted(), repository: repository))
        if let error { throw error }
        return result
    }
}

@MainActor
struct PullRequestStoreTests {
    private static let githubFacts = RepositoryFacts(
        originURL: "git@github.com:ryanmoelter/Plume.git",
        defaultBranch: "main"
    )

    private static func store(
        client: ForgeClient,
        repository: String = "/repo",
        facts: RepositoryFacts = githubFacts
    ) -> PullRequestStore {
        PullRequestStore(client: client) { _ in (repository, facts) }
    }

    private static func pushed(_ branch: String) -> GitState {
        GitState(branch: branch, upstream: "origin/\(branch)", ahead: 0, behind: 0, isDirty: false)
    }

    @Test func manyDirectoriesInOneRepositoryCostOneFetch() async {
        let client = FakeForgeClient()
        let store = Self.store(client: client)
        for index in 0..<5 {
            let directory = "/repo/wt\(index)"
            store.watch(directory)
            store.apply(gitState: Self.pushed("ryanm/branch\(index)"), for: directory)
        }
        await store.settle()

        let calls = await client.calls
        #expect(calls.count == 1)
        #expect(calls.first?.branches.count == 5)
    }

    @Test func aBranchWithNoUpstreamIsLocalOnlyAndNeverFetched() async {
        let client = FakeForgeClient()
        let store = Self.store(client: client)
        store.watch("/repo/wt")
        store.apply(
            gitState: GitState(branch: "ryanm/new", upstream: nil, ahead: nil, behind: nil, isDirty: false),
            for: "/repo/wt"
        )
        await store.settle()

        #expect(store.state(for: "/repo/wt") == .localOnly)
        #expect(await client.calls.isEmpty)
    }

    @Test func theTrunkShowsNoPullRequestEvenWhenOneComesBack() async {
        let client = FakeForgeClient(result: [
            "main": PullRequest(number: 1, state: .open, isDraft: false),
        ])
        let store = Self.store(client: client)
        store.watch("/repo")
        store.apply(gitState: Self.pushed("main"), for: "/repo")
        await store.settle()

        #expect(store.state(for: "/repo") == .noPR)
        #expect(await client.calls.isEmpty)
    }

    @Test func aGitLabOriginCostsNoNetworkCall() async {
        let client = FakeForgeClient()
        let store = Self.store(
            client: client,
            facts: RepositoryFacts(originURL: "git@gitlab.com:ryanm/plume.git", defaultBranch: "main")
        )
        store.watch("/repo/wt")
        store.apply(gitState: Self.pushed("ryanm/branch"), for: "/repo/wt")
        await store.settle()

        #expect(store.state(for: "/repo/wt") == .forgeUnsupported)
        #expect(await client.calls.isEmpty)
    }

    /// A thrown error must not read as "your PR does not exist".
    @Test func aThrownErrorBecomesFailed() async {
        let client = FakeForgeClient(error: ForgeError(message: "gh exited 1"))
        let store = Self.store(client: client)
        store.watch("/repo/wt")
        store.apply(gitState: Self.pushed("ryanm/branch"), for: "/repo/wt")
        await store.settle()

        #expect(store.state(for: "/repo/wt") == .failed("gh exited 1"))
    }

    @Test func aTimeoutReadsAsATimeoutRatherThanAFailure() async {
        let client = FakeForgeClient(error: ForgeError(message: "killed", kind: .timedOut))
        let store = Self.store(client: client)
        store.watch("/repo/wt")
        store.apply(gitState: Self.pushed("ryanm/branch"), for: "/repo/wt")
        await store.settle()

        #expect(store.state(for: "/repo/wt") == .timedOut)
    }

    @Test func aFetchedPullRequestReachesTheDirectory() async {
        let pullRequest = PullRequest(number: 7, state: .open, isDraft: true)
        let client = FakeForgeClient(result: ["ryanm/branch": pullRequest])
        let store = Self.store(client: client)
        store.watch("/repo/wt")
        store.apply(gitState: Self.pushed("ryanm/branch"), for: "/repo/wt")
        await store.settle()

        #expect(store.state(for: "/repo/wt") == .pullRequest(pullRequest))
    }

    /// Re-publishing an equal value would invalidate every row reading it.
    @Test func anUnchangedAnswerIsNotRepublished() async {
        let client = FakeForgeClient(result: ["ryanm/branch": PullRequest(number: 7, state: .open, isDraft: false)])
        let store = Self.store(client: client)
        store.watch("/repo/wt")
        store.apply(gitState: Self.pushed("ryanm/branch"), for: "/repo/wt")
        await store.settle()

        var publishes = 0
        withObservationTracking {
            _ = store.state(for: "/repo/wt")
        } onChange: {
            publishes += 1
        }

        store.apply(gitState: Self.pushed("ryanm/branch"), for: "/repo/wt")
        await store.settle()
        #expect(publishes == 0)
    }

    @Test func releasingTheLastReferenceDropsTheDirectory() async {
        let store = Self.store(client: FakeForgeClient())
        store.watch("/repo/wt")
        store.watch("/repo/wt")
        await store.settle()

        store.release("/repo/wt")
        #expect(store.state(for: "/repo/wt") != nil)
        store.release("/repo/wt")
        #expect(store.state(for: "/repo/wt") == nil)
    }

    @Test func forgettingDropsADirectoryWhateverItsRefcount() async {
        let store = Self.store(client: FakeForgeClient())
        store.watch("/repo/wt")
        store.watch("/repo/wt")
        await store.settle()

        store.forget(directory: "/repo/wt")
        #expect(store.state(for: "/repo/wt") == nil)
    }

    /// A network round trip against a rate-limited API cannot poll at
    /// `GitStateStore`'s pace.
    @Test func thePollIsFarSlowerThanTheGitStatePoll() {
        #expect(PullRequestStore.pollInterval >= 60)
    }
}
