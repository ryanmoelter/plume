import Foundation
import Testing
@testable import Plume

@MainActor
struct CodexSubagentOfflineHistoryTests {
    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "plume-child-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    private func entry(_ id: String, _ text: String, completed: Bool = true) -> CodexHistoryCache.Entry {
        .init(stableID: "turn#\(id)", turnID: "turn", item: .object([
            "id": .string(id), "type": .string("agentMessage"), "text": .string(text)
        ]), completed: completed, historical: true)
    }
    private func savedChild(status: String = "working") -> CodexSubagentHistoryCache.Child {
        .init(threadID: "child", path: "reviewer", description: "Review the code", agentType: "reviewer",
              model: "gpt-5.6-luna", status: status, modifiedAt: Date(timeIntervalSince1970: 123),
              entries: [entry("one", "First"), entry("two", "Second")])
    }
    private func seed(_ cache: CodexSubagentHistoryCache, tabID: UUID, child: CodexSubagentHistoryCache.Child? = nil) async {
        await cache.schedule(tabID: tabID, parentThreadID: "parent", children: [child ?? savedChild()])
        await cache.flush(tabID: tabID)
    }

    @Test func coldRestoreKeepsDescriptorAndOrderedTranscriptWithoutAwakeActivity() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = CodexSubagentHistoryCache(directory: directory)
        let tabID = UUID(), taskID = UUID()
        await seed(cache, tabID: tabID)
        let engine = StatusEngine()
        engine.setStatus(.awaitingReply, taskID: taskID, tabID: tabID)
        let store = CodexSubagentStore(statusEngine: engine, cache: cache)
        await store.restore(tabID: tabID, taskID: taskID, parentThreadID: "parent")
        let child = try #require(store.subagents(forTab: tabID).first)
        #expect(child.id == "child")
        #expect(child.title == "reviewer: Review the code")
        #expect(child.descriptor?.model == "gpt-5.6-luna")
        #expect(child.status == .interrupted)
        #expect(child.transcript.messages.map(\.id) == ["turn#one", "turn#two"])
        #expect(engine.status(forTab: tabID) == .awaitingReply)
        #expect(BackgroundTaskTracker.shared.inFlight(tabID: tabID).isEmpty)
        await store.flush(tabID: tabID)
    }

    @Test func liveStatusAndContentWinWhenRestoreStartsAfterNotifications() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = CodexSubagentHistoryCache(directory: directory)
        let tabID = UUID(), taskID = UUID()
        await seed(cache, tabID: tabID, child: savedChild(status: "done"))
        let store = CodexSubagentStore(cache: cache)
        store.receiveParentItem(tabID: tabID, taskID: taskID, item: .object([
            "type": .string("collabAgentToolCall"), "receiverThreadIds": .array([.string("child")]),
            "prompt": .string("Live assignment"), "model": .string("live-model")
        ]))
        store.receiveTurnLifecycle(tabID: tabID, threadID: "child", working: true)
        store.receiveChildItem(tabID: tabID, threadID: "child", item: .object([
            "id": .string("two"), "type": .string("agentMessage"), "text": .string("Live")
        ]), turnID: "turn", lifecycle: .completed)
        await store.restore(tabID: tabID, taskID: taskID, parentThreadID: "parent")
        let child = try #require(store.subagents(forTab: tabID).first)
        #expect(child.status == .working)
        #expect(child.descriptor?.description == "Live assignment")
        #expect(child.descriptor?.model == "live-model")
        #expect(child.transcript.messages.map(\.id) == ["turn#one", "turn#two"])
        #expect(child.transcript.messages.last?.blocks == [.markdown("Live")])
        store.connectionClosed(tabID: tabID)
        await store.flush(tabID: tabID)
    }

    @Test func archivePreservesCacheAndOtherParentOrTabCannotReadIt() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = CodexSubagentHistoryCache(directory: directory)
        let tabID = UUID(), taskID = UUID()
        let store = CodexSubagentStore(cache: cache)
        await store.restore(tabID: tabID, taskID: taskID, parentThreadID: "parent")
        store.receiveChildItem(tabID: tabID, threadID: "child", item: .object([
            "id": .string("reply"), "type": .string("agentMessage"), "text": .string("Saved")
        ]), turnID: "turn", lifecycle: .completed)
        store.receiveTurnLifecycle(tabID: tabID, threadID: "child", working: false, status: "completed")
        await store.flush(tabID: tabID)
        store.forget(tabID: tabID)
        let restored = CodexSubagentStore(cache: cache)
        await restored.restore(tabID: tabID, taskID: taskID, parentThreadID: "parent")
        #expect(restored.subagents(forTab: tabID).first?.status == .done)
        #expect(restored.subagents(forTab: tabID).first?.transcript.messages.first?.blocks == [.markdown("Saved")])
        #expect(await cache.load(tabID: tabID, parentThreadID: "different") == nil)
        #expect(await cache.load(tabID: UUID(), parentThreadID: "parent") == nil)
        await restored.flush(tabID: tabID)
    }

    @Test func authoritativeParentAndChildHistoryPreventStaleCacheResurrection() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = CodexSubagentHistoryCache(directory: directory)
        let tabID = UUID(), taskID = UUID()
        await seed(cache, tabID: tabID)
        let removed = CodexSubagentStore(cache: cache)
        removed.parentHistoryHydrated(tabID: tabID)
        await removed.restore(tabID: tabID, taskID: taskID, parentThreadID: "parent")
        #expect(removed.subagents(forTab: tabID).isEmpty)
        await removed.flush(tabID: tabID)
        await seed(cache, tabID: tabID)
        let surviving = CodexSubagentStore(cache: cache)
        let revision = surviving.revision(tabID: tabID, threadID: "child")
        surviving.mergeHistory(tabID: tabID, threadID: "child", entries: [], since: revision)
        surviving.parentHistoryHydrated(tabID: tabID)
        await surviving.restore(tabID: tabID, taskID: taskID, parentThreadID: "parent")
        #expect(surviving.subagents(forTab: tabID).first?.transcript.messages.isEmpty == true)
        await surviving.flush(tabID: tabID)
    }

    @Test func cachedCompletionDoesNotBlockResumedChildStreaming() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = CodexSubagentHistoryCache(directory: directory)
        let tabID = UUID(), taskID = UUID()
        await seed(cache, tabID: tabID)
        let store = CodexSubagentStore(cache: cache)
        await store.restore(tabID: tabID, taskID: taskID, parentThreadID: "parent")
        store.receiveChildItem(tabID: tabID, threadID: "child", item: .object([
            "id": .string("two"), "type": .string("agentMessage"), "text": .string("New")
        ]), turnID: "turn", lifecycle: .started)
        store.appendText(tabID: tabID, threadID: "child", itemID: "two", turnID: "turn", type: "agentMessage", field: "text", delta: " reply")
        #expect(store.subagents(forTab: tabID).first?.transcript.messages.last?.blocks == [.markdown("New reply")])
        #expect(store.subagents(forTab: tabID).first?.status == .working)
        store.connectionClosed(tabID: tabID)
        await store.flush(tabID: tabID)
    }

    @Test func cacheBudgetKeepsIdentityWithNewestRetainedChildItems() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var limits = CodexHistoryCache.Limits()
        limits.maximumEntries = 1
        let cache = CodexSubagentHistoryCache(directory: directory, limits: limits)
        let tabID = UUID()
        await seed(cache, tabID: tabID)
        let children = try #require(await cache.load(tabID: tabID, parentThreadID: "parent"))
        #expect(children.count == 1)
        #expect(children.first?.description == "Review the code")
        #expect(children.first?.entries.map(\.stableID) == ["turn#two"])
        await cache.remove(tabID: tabID)
        #expect(await cache.load(tabID: tabID, parentThreadID: "parent") == nil)
    }
}
