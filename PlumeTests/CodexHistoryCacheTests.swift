import Foundation
import Testing
@testable import Plume

@MainActor
struct CodexHistoryCacheTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "plume-history-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func entry(_ id: String, text: String = "Hello") -> CodexHistoryCache.Entry {
        .init(stableID: "turn#\(id)", turnID: "turn", item: .object([
            "id": .string(id), "type": .string("agentMessage"), "text": .string(text)
        ]), completed: true, historical: true)
    }

    @Test func roundTripPreservesRawItemsOrderingAndLifecycleWithoutAProcess() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tabID = UUID()
        let snapshot = CodexHistoryCache.Snapshot(threadID: "thread", entries: [
            entry("first"),
            .init(stableID: "next#partial", turnID: "next", item: .object([
                "id": .string("partial"), "type": .string("reasoning"), "summary": .array([.string("Thinking")])
            ]), completed: false, historical: false)
        ])
        let cache = CodexHistoryCache(directory: directory, debounce: .seconds(60))
        await cache.schedule(tabID: tabID, snapshot: snapshot)
        await cache.flush()
        let reopened = CodexHistoryCache(directory: directory)
        #expect(await reopened.load(tabID: tabID, threadID: "thread") == snapshot)
    }

    @Test func pendingWritesCoalesceAndDifferentThreadCannotReadOldHistory() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tabID = UUID()
        let cache = CodexHistoryCache(directory: directory, debounce: .seconds(60))
        let old = CodexHistoryCache.Snapshot(threadID: "old", entries: [entry("old")])
        let new = CodexHistoryCache.Snapshot(threadID: "new", entries: [entry("new")])
        await cache.schedule(tabID: tabID, snapshot: old)
        await cache.flush(tabID: tabID)
        #expect(await cache.load(tabID: tabID, threadID: "new") == nil)
        await cache.schedule(tabID: tabID, snapshot: old)
        await cache.schedule(tabID: tabID, snapshot: new)
        #expect(await cache.load(tabID: tabID, threadID: "old") == nil)
        #expect(await cache.load(tabID: tabID, threadID: "new") == new)
        await cache.flush(tabID: tabID)
        let reopened = CodexHistoryCache(directory: directory)
        #expect(await reopened.load(tabID: tabID, threadID: "old") == nil)
        #expect(await reopened.load(tabID: tabID, threadID: "new") == new)
    }

    @Test func removalCancelsPendingWriteAndDeletesExistingSnapshot() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tabID = UUID()
        let cache = CodexHistoryCache(directory: directory, debounce: .seconds(60))
        let snapshot = CodexHistoryCache.Snapshot(threadID: "thread", entries: [entry("one")])
        await cache.schedule(tabID: tabID, snapshot: snapshot)
        await cache.flush()
        await cache.schedule(tabID: tabID, snapshot: snapshot)
        await cache.remove(tabID: tabID)
        await cache.flush()
        #expect(await cache.load(tabID: tabID, threadID: "thread") == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: tabID.uuidString + ".json").path))
    }

    @Test func corruptAndUnsupportedVersionAreCacheMisses() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tabID = UUID()
        let file = directory.appending(path: tabID.uuidString + ".json")
        let cache = CodexHistoryCache(directory: directory)
        try Data("not JSON".utf8).write(to: file)
        #expect(await cache.load(tabID: tabID, threadID: "thread") == nil)
        try Data(#"{"version":99,"threadID":"thread","entries":[]}"#.utf8).write(to: file)
        #expect(await cache.load(tabID: tabID, threadID: "thread") == nil)
    }

    @Test func entryAndByteLimitsKeepAnOrderedSuffixOfWholeItems() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tabID = UUID()
        var limits = CodexHistoryCache.Limits()
        limits.maximumEntries = 2
        limits.maximumFileBytes = 550
        let cache = CodexHistoryCache(directory: directory, debounce: .seconds(60), limits: limits)
        let snapshot = CodexHistoryCache.Snapshot(threadID: "thread", entries: [
            entry("one"), entry("two", text: String(repeating: "a", count: 200)), entry("three", text: String(repeating: "b", count: 200))
        ])
        await cache.schedule(tabID: tabID, snapshot: snapshot)
        await cache.flush()
        let loaded = try #require(await cache.load(tabID: tabID, threadID: "thread"))
        #expect(loaded.entries == [snapshot.entries[2]])
        let size = try directory.appending(path: tabID.uuidString + ".json").resourceValues(forKeys: [.fileSizeKey]).fileSize
        #expect(try #require(size) <= limits.maximumFileBytes)
    }

    @Test func directoryBudgetEvictsOldCacheFilesButKeepsOtherFiles() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let unrelated = directory.appending(path: "notes.json")
        try Data("keep".utf8).write(to: unrelated)
        var limits = CodexHistoryCache.Limits()
        limits.maximumFiles = 1
        let cache = CodexHistoryCache(directory: directory, debounce: .seconds(60), limits: limits)
        let first = UUID(), second = UUID()
        let snapshot = CodexHistoryCache.Snapshot(threadID: "thread", entries: [entry("one")])
        await cache.schedule(tabID: first, snapshot: snapshot)
        await cache.flush(tabID: first)
        await cache.schedule(tabID: second, snapshot: snapshot)
        await cache.flush(tabID: second)
        #expect(await cache.load(tabID: first, threadID: "thread") == nil)
        #expect(await cache.load(tabID: second, threadID: "thread") == snapshot)
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }
}
