import Foundation
import Testing
@testable import Plume

@MainActor
struct CodexOfflineHistoryTests {
    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "plume-offline-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    private func message(_ text: String, id: String = "message", type: String = "agentMessage") -> JSONValue {
        .object(["id": .string(id), "type": .string(type), "text": .string(text)])
    }
    private func seed(_ cache: CodexHistoryCache, tabID: UUID, item: JSONValue, completed: Bool = true) async {
        await cache.schedule(tabID: tabID, snapshot: .init(threadID: "thread", entries: [
            .init(stableID: "turn#message", turnID: "turn", item: item, completed: completed, historical: true)
        ]))
        await cache.flush(tabID: tabID)
    }

    @Test func savedPlanRendersAsHistoryWithoutBecomingAnActionableProposal() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = CodexHistoryCache(directory: directory)
        let tabID = UUID()
        await seed(cache, tabID: tabID, item: message("Saved plan", type: "plan"))
        let store = CodexItemStore(cache: cache)
        await store.restore(tabID: tabID, threadID: "thread")
        #expect(store.transcript(forTab: tabID)?.messages.count == 1)
        #expect(store.isSavedCopy(forTab: tabID))
        #expect(store.latestPendingPlan(forTab: tabID) == nil)
        store.upsert(tabID: tabID, item: message("Live commentary", id: "other"), turnID: "next", lifecycle: .completed)
        #expect(store.latestPendingPlan(forTab: tabID) == nil)
        #expect(store.isSavedCopy(forTab: tabID))
        await store.flush(tabID: tabID)
    }

    @Test func savedUserReplyPreventsAnOlderLivePlanFromBecomingActionable() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = CodexHistoryCache(directory: directory)
        let tabID = UUID()
        await seed(cache, tabID: tabID, item: message("Already approved", type: "userMessage"))
        let store = CodexItemStore(cache: cache)
        store.upsert(tabID: tabID, item: message("Older proposal", id: "plan", type: "plan"), turnID: "older", lifecycle: .completed)
        await store.restore(tabID: tabID, threadID: "thread")
        #expect(store.isSavedCopy(forTab: tabID))
        #expect(store.latestPendingPlan(forTab: tabID) == nil)
        await store.flush(tabID: tabID)
    }

    @Test func liveContentAlreadyPresentWinsOverSavedSnapshot() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = CodexHistoryCache(directory: directory)
        let tabID = UUID()
        await seed(cache, tabID: tabID, item: message("Old"))
        let store = CodexItemStore(cache: cache)
        store.upsert(tabID: tabID, item: message("New"), turnID: "turn", lifecycle: .completed)
        await store.restore(tabID: tabID, threadID: "thread")
        #expect(store.item(tabID: tabID, id: "turn#message")?["text"] == .string("New"))
        #expect(store.transcript(forTab: tabID)?.messages.count == 1)
        await store.flush(tabID: tabID)
    }

    @Test func cachedCompletionDoesNotBlockNewLiveDeltas() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = CodexHistoryCache(directory: directory)
        let tabID = UUID()
        await seed(cache, tabID: tabID, item: message("Old"))
        let store = CodexItemStore(cache: cache)
        await store.restore(tabID: tabID, threadID: "thread")
        store.upsert(tabID: tabID, item: message("New"), turnID: "turn", lifecycle: .started)
        store.appendText(tabID: tabID, itemID: "message", turnID: "turn", type: "agentMessage", field: "text", delta: " reply")
        #expect(store.item(tabID: tabID, id: "turn#message")?["text"] == .string("New reply"))
        await store.flush(tabID: tabID)
    }

    @Test func anIncompleteCachedItemDoesNotAnimateAsLive() throws {
        let tabID = UUID()
        let store = CodexItemStore()
        store.restoreSnapshot(tabID: tabID, snapshot: .init(threadID: "thread", entries: [
            .init(
                stableID: "turn#message",
                turnID: "turn",
                item: message("Interrupted reply"),
                completed: false,
                historical: false
            )
        ]))

        #expect(store.transcript(forTab: tabID)?.messages.first?.isLive == false)
    }

    @Test func completedHydrationBeforeViewRestorePreventsStaleRowsReturning() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = CodexHistoryCache(directory: directory)
        let tabID = UUID()
        await seed(cache, tabID: tabID, item: message("Removed by rollback"))
        let store = CodexItemStore(cache: cache)
        store.mergeHistory(tabID: tabID, entries: [], since: 0)
        store.historyHydrated(tabID: tabID)
        await store.restore(tabID: tabID, threadID: "thread")
        #expect(store.transcript(forTab: tabID)?.messages.isEmpty == true)
        #expect(!store.isSavedCopy(forTab: tabID))
        await store.flush(tabID: tabID)
        #expect(await cache.load(tabID: tabID, threadID: "thread")?.entries.isEmpty == true)
    }

    @Test func authoritativeHydrationClearsSavedOnlyRowsAndForgetKeepsDiskHistory() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = CodexHistoryCache(directory: directory)
        let tabID = UUID()
        await seed(cache, tabID: tabID, item: message("Obsolete"))
        let store = CodexItemStore(cache: cache)
        await store.restore(tabID: tabID, threadID: "thread")
        store.mergeHistory(tabID: tabID, entries: [.object(["turnId": .string("new"), "item": message("Authoritative", id: "new")])], since: store.revision(forTab: tabID))
        store.historyHydrated(tabID: tabID)
        #expect(!store.isSavedCopy(forTab: tabID))
        #expect(store.transcript(forTab: tabID)?.messages.map(\.id) == ["new#new"])
        await store.flush(tabID: tabID)
        store.forget(tabID: tabID)
        #expect(store.transcript(forTab: tabID) == nil)
        let reopened = CodexItemStore(cache: cache)
        await reopened.restore(tabID: tabID, threadID: "thread")
        #expect(reopened.transcript(forTab: tabID)?.messages.map(\.id) == ["new#new"])
        await reopened.flush(tabID: tabID)
    }
}
