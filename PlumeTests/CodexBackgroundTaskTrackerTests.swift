import Foundation
import Testing
@testable import Plume

@MainActor
struct CodexBackgroundTaskTrackerTests {
    private func page(_ ids: [String], cursor: String? = nil) -> JSONValue {
        .object([
            "data": .array(ids.map { .object(["processId": .string($0)]) }),
            "nextCursor": cursor.map(JSONValue.string) ?? .null
        ])
    }

    @Test func inventoriesCombineParentAndChildAndReleaseCompletedProcesses() async {
        let tracker = BackgroundTaskTracker()
        let tabID = UUID()
        var finishedParent = false
        let store = CodexBackgroundTaskTracker(tabID: tabID, tracker: tracker) { _, params in
            self.page(params["threadId"]?.stringValue == "parent" && finishedParent ? [] : ["same-id"])
        }
        await store.refresh(threadID: "parent")?.value
        await store.refresh(threadID: "child")?.value
        #expect(tracker.inFlight(tabID: tabID).count == 2)
        finishedParent = true
        await store.refresh(threadID: "parent")?.value
        #expect(tracker.inFlight(tabID: tabID).map(\.id) == ["child/same-id"])
        store.stop()
        #expect(tracker.inFlight(tabID: tabID).isEmpty)
    }

    @Test func paginatesBeforeReplacingAndDoesNotRenewHardCap() async {
        let tracker = BackgroundTaskTracker()
        let tabID = UUID()
        var calls = 0
        let store = CodexBackgroundTaskTracker(tabID: tabID, tracker: tracker) { method, params in
            #expect(method == "thread/backgroundTerminals/list")
            calls += 1
            return params["cursor"] == nil ? self.page(["one"], cursor: "next") : self.page(["two"])
        }
        await store.refresh(threadID: "parent")?.value
        let first = tracker.inFlight(tabID: tabID)
        #expect(first.count == 2)
        await store.refresh(threadID: "parent")?.value
        #expect(tracker.inFlight(tabID: tabID) == first)
        #expect(calls == 4)
        store.stop()
    }

    @Test func failedInventoryRetainsOnlyPreviouslyConfirmedWork() async {
        struct Failure: Error {}
        let tracker = BackgroundTaskTracker()
        let tabID = UUID()
        var fails = true
        let store = CodexBackgroundTaskTracker(tabID: tabID, tracker: tracker) { _, _ in
            if fails { throw Failure() }
            return self.page(["one"])
        }
        await store.refresh(threadID: "parent")?.value
        #expect(tracker.inFlight(tabID: tabID).isEmpty)
        fails = false
        await store.refresh(threadID: "parent")?.value
        let first = tracker.inFlight(tabID: tabID)
        fails = true
        await store.refresh(threadID: "parent")?.value
        #expect(tracker.inFlight(tabID: tabID) == first)
        store.stop()
    }

    @Test func stopIgnoresLateInventoryReply() async {
        let tracker = BackgroundTaskTracker()
        let tabID = UUID()
        var response: CheckedContinuation<JSONValue, Never>?
        var started: CheckedContinuation<Void, Never>?
        let store = CodexBackgroundTaskTracker(tabID: tabID, tracker: tracker) { _, _ in
            await withCheckedContinuation { continuation in
                response = continuation
                started?.resume()
            }
        }
        await withCheckedContinuation { continuation in
            started = continuation
            store.refresh(threadID: "parent")
        }
        store.stop()
        response?.resume(returning: page(["one"]))
        await Task.yield()
        #expect(tracker.inFlight(tabID: tabID).isEmpty)
        #expect(store.refresh(threadID: "parent") == nil)
    }
}
