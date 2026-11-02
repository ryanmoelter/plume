import Foundation
import SwiftData
import Testing
@testable import Plume

struct PullRequestPinsTests {
    private func ref(_ number: Int) -> PullRequestReference {
        PullRequestReference(owner: "a", repo: "b", number: number)
    }

    @Test func parsesAURLAndTheShorthand() {
        #expect(PullRequestReference.parse("https://github.com/Owner/Repo/pull/12/files")
            == PullRequestReference(owner: "owner", repo: "repo", number: 12))
        #expect(PullRequestReference.parse("  owner/my.repo#7 ")
            == PullRequestReference(owner: "owner", repo: "my.repo", number: 7))
    }

    @Test func parsesAQueryStringFragmentAndUppercaseShorthand() {
        let expected = PullRequestReference(owner: "owner", repo: "repo", number: 12)
        #expect(PullRequestReference.parse("https://github.com/owner/repo/pull/12?diff=split") == expected)
        #expect(PullRequestReference.parse("https://github.com/owner/repo/pull/12#discussion_r1") == expected)
        #expect(PullRequestReference.parse("github.com/owner/repo/pull/12") == expected)
        #expect(PullRequestReference.parse("OWNER/REPO#12") == expected)
    }

    @Test func rejectsWhatIsNotAPullRequest() {
        for text in [
            "", "#12", "owner/repo", "owner/repo#0", "https://github.com/a/b/issues/3", "PLUME-12",
            "https://github.com/a/b/pull/0",
            "https://notgithub.com/a/b/pull/3",
            "https://github.example.com/a/b/pull/3",
            "see https://github.com/a/b/pull/3 for details",
            "https://github.com/a/b/pull/3 and more",
        ] {
            #expect(PullRequestReference.parse(text) == nil, "\(text)")
        }
    }

    @Test func pinningIsIdempotentAndUnpinningRemoves() {
        var links = PullRequestTaskLinks()
        links.pin(ref(1))
        links.pin(ref(2))
        links.pin(ref(1))
        #expect(links.pinned == [ref(1), ref(2)])
        links.unpin(ref(1))
        #expect(links.pinned == [ref(2)])
        links.unpin(ref(2))
        #expect(links.isEmpty)
    }

    @Test func mergePutsPinnedFirstAndShowsEachOnce() {
        let merged = LinkedPullRequest.merge(pinned: [ref(3), ref(1)], mentioned: [ref(1), ref(2), ref(2)])
        #expect(merged.map(\.reference) == [ref(3), ref(1), ref(2)])
        #expect(merged.map(\.role) == [.pinned, .pinned, .mentioned])
    }

    @Test func pinsRoundTripThroughTaskIntegrations() {
        let integrations = TaskIntegrations(pullRequests: PullRequestTaskLinks(pinned: [ref(1)]))
        #expect(TaskIntegrations.decode(integrations.encoded()) == integrations)
    }

    @Test func decodingLowercasesAStoredOwnerAndRepository() {
        let data = Data(#"{"version":1,"pullRequests":{"pinned":[{"owner":"Owner","repo":"Repo","number":2}]}}"#.utf8)
        #expect(TaskIntegrations.decode(data).pullRequests?.pinned
            == [PullRequestReference(owner: "owner", repo: "repo", number: 2)])
    }

    @Test func storedDataWithoutPinsStillDecodes() {
        let data = Data(#"{"version":1,"linear":{"manual":[]}}"#.utf8)
        #expect(TaskIntegrations.decode(data).pullRequests == nil)
    }

    @Test func aMalformedPinIsDroppedRatherThanFailingTheRest() {
        let data = Data(#"{"version":1,"pullRequests":{"pinned":[{"owner":"a"},{"owner":"a","repo":"b","number":2}]}}"#.utf8)
        #expect(TaskIntegrations.decode(data).pullRequests?.pinned == [ref(2)])
    }
}

@MainActor
struct TaskStorePullRequestPinTests {
    private let ref = PullRequestReference(owner: "a", repo: "b", number: 1)

    private func makeTask() throws -> (WorkTask, ModelContext) {
        let container = try ModelContainer(
            for: Schema([TaskGroup.self, WorkTask.self, TaskTab.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        return (TaskStore.createTask(in: context, siblings: []), context)
    }

    @Test func pinningKeepsLinearLinks() throws {
        let (task, context) = try makeTask()
        _ = context
        TaskStore.linkLinearIssue("PLUME-1", to: task)
        TaskStore.pinPullRequest(ref, to: task)
        TaskStore.unpinPullRequest(ref, from: task)
        #expect(TaskStore.linearLinks(for: task).manual == [LinearIssueRef(identifier: "PLUME-1")])
    }

    @Test func theLastUnpinClearsThePullRequestLinks() throws {
        let (task, context) = try makeTask()
        _ = context
        TaskStore.pinPullRequest(ref, to: task)
        #expect(TaskStore.pinnedPullRequests(of: task) == [ref])
        TaskStore.unpinPullRequest(ref, from: task)
        #expect(TaskIntegrations.decode(task.integrationsData).pullRequests == nil)
        #expect(TaskStore.pinnedPullRequests(of: task).isEmpty)
    }

    @Test func pinningAgainWritesNothing() throws {
        let (task, context) = try makeTask()
        #expect(TaskStore.pinPullRequest("https://github.com/A/B/pull/1", to: task))
        try context.save()
        #expect(TaskStore.pinPullRequest("a/b#1", to: task))
        #expect(!context.hasChanges)
    }
}
