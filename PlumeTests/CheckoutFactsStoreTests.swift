import Testing
import Foundation
@testable import Plume

@MainActor
struct CheckoutFactsStoreTests {
    private func store(
        resolve: @escaping @Sendable (String) async -> CheckoutFacts?
    ) -> CheckoutFactsStore {
        let store = CheckoutFactsStore()
        store.resolve = resolve
        return store
    }

    /// Reading must never start a lookup: the read happens in a view's `body`,
    /// where any write invalidates the render that made it.
    @Test func readingAloneNeverResolves() async {
        let calls = Counter()
        let store = store { _ in await calls.increment(); return nil }
        for _ in 0..<5 { #expect(store.facts(for: "/repo") == nil) }
        #expect(await calls.count == 0)
    }

    @Test func aLoadedDirectoryAnswersFromCache() async throws {
        let store = store { CheckoutFacts(projectRoot: "/repo", checkoutRoot: $0) }
        store.load("/wt/a")
        try await Task.sleep(for: .milliseconds(50))
        let facts = try #require(store.facts(for: "/wt/a"))
        #expect(facts.projectRoot == "/repo")
        #expect(facts.isWorktree)
    }

    @Test func aResolvedDirectoryIsNotLookedUpTwice() async {
        let calls = Counter()
        let store = store { path in
            await calls.increment()
            return CheckoutFacts(projectRoot: path, checkoutRoot: path)
        }
        store.load("/repo")
        try? await Task.sleep(for: .milliseconds(50))
        store.load("/repo")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await calls.count == 1)
    }

    /// Otherwise every directory that is not a repository spawns a `git`
    /// process each time its row is scrolled back into view.
    @Test func aDirectoryWithNoRepositoryIsNotRetried() async {
        let calls = Counter()
        let store = store { _ in await calls.increment(); return nil }
        store.load("/tmp/plain")
        try? await Task.sleep(for: .milliseconds(50))
        store.load("/tmp/plain")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await calls.count == 1)
    }
}

private actor Counter {
    private(set) var count = 0
    func increment() { count += 1 }
}

/// A fixture directory has no repository on disk, so any real lookup resolves
/// it to nothing. Each store must leave seeded state alone.
@MainActor
struct FixtureStateSurvivesRealLookupTests {
    @Test func aSeededCheckoutIsNeverLookedUp() async {
        let store = CheckoutFactsStore()
        let resolved = Counter()
        store.resolve = { _ in await resolved.increment(); return nil }
        let seeded = CheckoutFacts(projectRoot: "/p/Notability", checkoutRoot: "/p/wt")
        store.seedFixture(directory: "/p/wt", facts: seeded)

        store.load("/p/wt")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await resolved.count == 0)
        #expect(store.facts(for: "/p/wt") == seeded)
    }

    /// The lazy `List` releases whatever scrolls out of view, so a fixture
    /// that does not survive release blanks on the way back in.
    @Test func aSeededBranchSurvivesWatchAndRelease() {
        let store = GitStateStore()
        let state = GitState(branch: "ryanm/demo", upstream: "origin/ryanm/demo", ahead: 0, behind: 0, isDirty: false)
        store.seedFixture(directory: "/tmp/plume-fixtures/demo", state: state)

        store.watch("/tmp/plume-fixtures/demo")
        #expect(store.state(for: "/tmp/plume-fixtures/demo")?.branch == "ryanm/demo")
        store.release("/tmp/plume-fixtures/demo")
        store.watch("/tmp/plume-fixtures/demo")
        #expect(store.state(for: "/tmp/plume-fixtures/demo")?.branch == "ryanm/demo")
    }
}

/// The catalog's worktree cases must key their seeded facts to the same path
/// the row looks up, or the marker silently never appears.
@MainActor
struct SidebarWorktreeFixtureTests {
    @Test func theWorktreeFixturesSeedFactsForTheirOwnDirectory() throws {
        let worktrees = SidebarFixtureCatalog.cases.filter { $0.checkout?.isWorktree == true }
        #expect(worktrees.count >= 2)
        for fixture in worktrees {
            let seeded = try #require(fixture.checkout)
            #expect(seeded.checkoutRoot == "/tmp/plume-fixtures/\(fixture.directory)")
        }
    }

    /// The header's whole purpose: differently-named folders reading as one
    /// project.
    @Test func theWorktreeFixturesShareOneProjectHeader() throws {
        let named = SidebarFixtureCatalog.cases.filter { $0.checkout != nil }
        let projects = Set(named.compactMap { $0.checkout?.projectName })
        #expect(projects == ["Notability"])
        #expect(Set(named.map(\.directory)).count == named.count)
    }
}
