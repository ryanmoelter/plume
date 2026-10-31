import Foundation
import Testing
@testable import Plume

@MainActor
struct LinkedPullRequestStoreTests {
    private let missingRepository = ForgeError(message: "Could not resolve to a Repository with the name 'a/b'.")

    @Test func missingRepositoryIsClassifiedAsSuch() {
        #expect(LinkedPullRequestStore.classify(missingRepository) == .repositoryMissing)
    }

    @Test func missingPullRequestsNameTheirNumbers() {
        let error = ForgeError(
            message: "Could not resolve to a PullRequest with the number of 4. Could not resolve to a PullRequest with the number of 9."
        )
        #expect(LinkedPullRequestStore.classify(error) == .missingPullRequests([4, 9]))
    }

    @Test func otherFailuresAreTransient() {
        #expect(LinkedPullRequestStore.classify(ForgeError(message: "gh: command not found")) == .transient)
        #expect(LinkedPullRequestStore.classify(CancellationError()) == .transient)
    }

    @Test func backoffDoublesUpToTheCap() {
        let base = LinkedPullRequestStore.failureBackoff
        #expect(LinkedPullRequestStore.backoff(afterFailures: 1) == base)
        #expect(LinkedPullRequestStore.backoff(afterFailures: 2) == base * 2)
        #expect(LinkedPullRequestStore.backoff(afterFailures: 3) == base * 4)
        #expect(LinkedPullRequestStore.backoff(afterFailures: 100) == LinkedPullRequestStore.maxFailureBackoff)
    }

    @Test func aRepositoryIsOneRequestAndSettlesWhenMissing() async {
        let counter = Counter()
        let error = missingRepository
        let store = LinkedPullRequestStore(run: { _ in
            await counter.bump()
            throw error
        })
        let refs = [
            PullRequestReference(owner: "a", repo: "b", number: 1),
            PullRequestReference(owner: "a", repo: "b", number: 2),
        ]
        store.refresh(refs)
        for _ in 0..<200 where store.detail(for: refs[1]) == nil { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(store.detail(for: refs[0]) == .unavailable)
        #expect(store.detail(for: refs[1]) == .unavailable)
        #expect(await counter.value == 1)
    }

    @Test func forgettingATabPrunesUnreferencedDetails() async {
        let error = missingRepository
        let store = LinkedPullRequestStore(run: { _ in throw error })
        let tab = UUID()
        let ref = PullRequestReference(owner: "a", repo: "b", number: 1)
        store.replace(tabID: tab, references: [ref])
        store.refresh([ref])
        for _ in 0..<200 where store.detail(for: ref) == nil { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(store.detail(for: ref) == .unavailable)
        store.forget(tabID: tab)
        #expect(store.detail(for: ref) == nil)
    }

    @Test func aTasksPinnedReferencesSurviveForgettingATab() async {
        let error = missingRepository
        let store = LinkedPullRequestStore(run: { _ in throw error })
        let tab = UUID()
        let task = UUID()
        let ref = PullRequestReference(owner: "a", repo: "b", number: 1)
        store.replace(tabID: tab, references: [ref])
        store.retain([ref], forTask: task)
        for _ in 0..<200 where store.detail(for: ref) == nil { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(store.detail(for: ref) == .unavailable)
        store.forget(tabID: tab)
        #expect(store.detail(for: ref) == .unavailable)
        store.forget(taskID: task)
        #expect(store.detail(for: ref) == nil)
    }
}

private actor Counter {
    private(set) var value = 0
    func bump() { value += 1 }
}
