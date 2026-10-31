import Foundation
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

    @Test func rejectsWhatIsNotAPullRequest() {
        for text in ["", "#12", "owner/repo", "owner/repo#0", "https://github.com/a/b/issues/3", "PLUME-12"] {
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

    @Test func storedDataWithoutPinsStillDecodes() {
        let data = Data(#"{"version":1,"linear":{"manual":[]}}"#.utf8)
        #expect(TaskIntegrations.decode(data).pullRequests == nil)
    }

    @Test func aMalformedPinIsDroppedRatherThanFailingTheRest() {
        let data = Data(#"{"version":1,"pullRequests":{"pinned":[{"owner":"a"},{"owner":"a","repo":"b","number":2}]}}"#.utf8)
        #expect(TaskIntegrations.decode(data).pullRequests?.pinned == [ref(2)])
    }
}
