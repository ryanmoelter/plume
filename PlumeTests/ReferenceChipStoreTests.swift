import Foundation
import Observation
import Synchronization
import Testing
@testable import Plume

/// `ReferenceChipStore` with faked sources: what a chip shows, and which
/// chat list's revision bumps when it arrives.
@MainActor
struct ReferenceChipStoreTests {
    @Observable
    final class FakeLinear {
        var issues: [String: LinearIssue] = [:]
        var wanted: [UUID: Set<String>] = [:]
    }

    /// Holds the revision flush until opened, so a test can land several
    /// arrivals inside one flush.
    private final class Gate: Sendable {
        private let state = Mutex<(isOpen: Bool, waiting: [CheckedContinuation<Void, Never>])>((false, []))

        func wait() async {
            await withCheckedContinuation { continuation in
                let resume = state.withLock { state -> Bool in
                    if state.isOpen { return true }
                    state.waiting.append(continuation)
                    return false
                }
                if resume { continuation.resume() }
            }
        }

        func open() {
            let waiting = state.withLock { state in
                state.isOpen = true
                defer { state.waiting = [] }
                return state.waiting
            }
            for continuation in waiting { continuation.resume() }
        }
    }

    private let linear = FakeLinear()
    private let ownerA = UUID()
    private let ownerB = UUID()

    private func makeStore(
        files: [String: Bool] = [:],
        pullRequests: [PullRequestLinkSource.Key: PullRequestLinkSource.Lookup] = [:],
        flushGate: Gate? = nil
    ) -> ReferenceChipStore {
        let linear = linear
        return ReferenceChipStore(dependencies: .init(
            linearIssue: { linear.issues[$0] },
            wantLinear: { linear.wanted[$1] = $0 },
            pullRequests: { keys in pullRequests.filter { keys.contains($0.key) } },
            fileKinds: { paths in files.filter { paths.contains($0.key) } },
            sleep: { duration in
                if duration == ReferenceChipStore.coalescing { await flushGate?.wait() }
            },
            now: { Date(timeIntervalSince1970: 0) }
        ))
    }

    private func issue(_ identifier: String, title: String) -> LinearIssue {
        LinearIssue(identifier: identifier, title: title, url: "u", stateName: "Todo", stateType: .unstarted, stateColor: "#aaaaaa", assigneeName: nil, teamKey: "A")
    }

    @Test func aFileThatExistsChipsAsItsName() async {
        let store = makeStore(files: ["/repo/Notes.md": false, "/repo/Sources": true])
        store.want([.file(path: "/repo/Notes.md"), .file(path: "/repo/Sources"), .file(path: "/repo/Gone.md")], owner: ownerA)
        await store.settled()
        #expect(store.title(for: .file(path: "/repo/Notes.md")) == "Notes.md")
        #expect(store.icon(for: .file(path: "/repo/Sources")) == .file(isDirectory: true))
        #expect(store.title(for: .file(path: "/repo/Gone.md")) == nil)
    }

    @Test func aPullRequestChipsAsItsTitleAndState() async {
        let key = PullRequestLinkSource.Key(owner: "o", repo: "r", number: 7)
        let store = makeStore(pullRequests: [key: .found(.init(number: 7, title: "Fix it", state: .merged, isDraft: false))])
        let target = ReferenceTarget.pullRequest(owner: "o", repo: "r", number: 7)
        store.want([target], owner: ownerA)
        await store.settled()
        #expect(store.title(for: target) == "Fix it")
        #expect(store.icon(for: target) == .pullRequest(number: 7, state: .merged, isDraft: false))
    }

    @Test func onlyTheOwnerOfAnArrivalBumps() async {
        let store = makeStore(files: ["/repo/Notes.md": false])
        store.want([.file(path: "/repo/Notes.md")], owner: ownerA)
        store.want([.file(path: "/repo/Gone.md")], owner: ownerB)
        await store.settled()
        #expect(store.revision(for: ownerA) == 1)
        #expect(store.revision(for: ownerB) == 0)
    }

    @Test func arrivalsBeforeAFlushBumpOnce() async {
        let gate = Gate()
        let key = PullRequestLinkSource.Key(owner: "o", repo: "r", number: 7)
        let store = makeStore(
            files: ["/repo/Notes.md": false],
            pullRequests: [key: .found(.init(number: 7, title: "Fix it", state: .open, isDraft: false))],
            flushGate: gate
        )
        store.want([.file(path: "/repo/Notes.md"), .pullRequest(owner: "o", repo: "r", number: 7)], owner: ownerA)
        await store.lookupsSettled()
        #expect(store.revision(for: ownerA) == 0)
        #expect(store.title(for: .file(path: "/repo/Notes.md")) == nil)
        gate.open()
        await store.settled()
        #expect(store.revision(for: ownerA) == 1)
    }

    @Test func aLinearIssueWantedUnderItsOwnOwnerArrivesAndBumps() async throws {
        let store = makeStore()
        let target = ReferenceTarget.linear(identifier: "A-1")
        store.want([target], owner: ownerA)
        let wanted = try #require(linear.wanted.first)
        #expect(wanted.value == ["A-1"])
        #expect(wanted.key != ownerA)
        #expect(store.title(for: target) == nil)

        linear.issues["A-1"] = issue("A-1", title: "Add chips")
        for _ in 0..<1000 where store.icon(for: target) == nil { await Task.yield() }
        await store.settled()
        #expect(store.title(for: target) == "Add chips")
        #expect(store.revision(for: ownerA) == 1)
    }

    @Test func releasingDropsTheLinearWant() async {
        let store = makeStore()
        store.want([.linear(identifier: "A-1")], owner: ownerA)
        let linearOwner = linear.wanted.keys.first
        store.release(owner: ownerA)
        #expect(linearOwner.flatMap { linear.wanted[$0] } == [])
    }

    @Test func aResolvedTargetIsNotLookedUpAgain() async {
        let counter = Mutex(0)
        let store = ReferenceChipStore(dependencies: .init(
            linearIssue: { _ in nil },
            wantLinear: { _, _ in },
            pullRequests: { _ in [:] },
            fileKinds: { paths in
                counter.withLock { $0 += 1 }
                return Dictionary(uniqueKeysWithValues: paths.map { ($0, false) })
            },
            sleep: { _ in },
            now: { Date(timeIntervalSince1970: 0) }
        ))
        store.want([.file(path: "/repo/Notes.md")], owner: ownerA)
        await store.settled()
        store.want([.file(path: "/repo/Notes.md")], owner: ownerB)
        await store.settled()
        #expect(counter.withLock { $0 } == 1)
    }
}
