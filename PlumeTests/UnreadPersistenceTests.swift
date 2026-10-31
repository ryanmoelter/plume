import Foundation
import Testing
@testable import Plume

/// A chat tab's unread mark is stored with the ID of the latest message when
/// it was set, and comes back after a relaunch only while that message is
/// still the latest. Nothing stored reads as read.
@MainActor
struct UnreadPersistenceTests {
    private let task = UUID()
    private let tab = UUID()

    private final class Stored {
        var marks: [UUID: String?] = [:]
    }

    private func recording(_ store: UnreadStore) -> Stored {
        let stored = Stored()
        store.onStoredMarkChanged = { stored.marks[$0] = .some($1) }
        return stored
    }

    // MARK: - UnreadStore

    @Test func aMarkStoresTheLatestMessageAndReadingClearsIt() {
        let store = UnreadStore()
        let stored = recording(store)
        store.latestMessageChanged(tabID: tab, to: "m1")

        store.markUnread([tab])
        #expect(stored.marks[tab] == "m1")

        store.markRead([tab])
        #expect(stored.marks[tab] == .some(nil))
    }

    @Test func aMarkSetBeforeTheTranscriptCatchesUpStoresWhatItCatchesUpTo() {
        let store = UnreadStore()
        let stored = recording(store)
        store.latestMessageChanged(tabID: tab, to: "m1")
        store.record(.awaitingReply, tabID: tab, isSeen: false)

        store.latestMessageChanged(tabID: tab, to: "m2")

        #expect(store.isUnread(tabID: tab))
        #expect(stored.marks[tab] == "m2")
    }

    @Test func aReadTabStoresNothingWhenItsTranscriptMoves() {
        let store = UnreadStore()
        let stored = recording(store)

        store.latestMessageChanged(tabID: tab, to: "m1")

        #expect(stored.marks[tab] == nil)
    }

    @Test func aRestoredMarkShowsWhenItsMessageIsStillTheLatest() {
        let store = UnreadStore()
        let stored = recording(store)
        store.restore(tabID: tab, messageID: "m1")
        #expect(!store.isUnread(tabID: tab))

        store.latestMessageChanged(tabID: tab, to: "m1")

        #expect(store.isUnread(tabID: tab))
        #expect(stored.marks[tab] == nil)
    }

    @Test func aRestoredMarkIsDroppedWhenTheConversationMovedOn() {
        let store = UnreadStore()
        let stored = recording(store)
        store.restore(tabID: tab, messageID: "m1")

        store.latestMessageChanged(tabID: tab, to: "m2")

        #expect(!store.isUnread(tabID: tab))
        #expect(stored.marks[tab] == .some(nil))
    }

    @Test func aRestoredMarkIsDroppedWhenItsTranscriptMovesOnLater() {
        let store = UnreadStore()
        let stored = recording(store)
        store.restore(tabID: tab, messageID: "m1")
        store.latestMessageChanged(tabID: tab, to: "m1")

        store.latestMessageChanged(tabID: tab, to: "m2")

        #expect(!store.isUnread(tabID: tab))
        #expect(stored.marks[tab] == .some(nil))
    }

    @Test func aRestoreConfirmsAtOnceWhenTheLatestMessageIsKnown() {
        let store = UnreadStore()
        store.latestMessageChanged(tabID: tab, to: "m1")

        store.restore(tabID: tab, messageID: "m1")

        #expect(store.isUnread(tabID: tab))
    }

    @Test func viewingATabBeforeItsRestoreIsConfirmedCancelsIt() {
        let store = UnreadStore()
        let stored = recording(store)
        store.restore(tabID: tab, messageID: "m1")

        store.markViewed(NotificationAudience(isAppActive: true, selectedTaskID: task, onScreenTabIDs: [tab], focusedTabID: tab))
        store.latestMessageChanged(tabID: tab, to: "m1")

        #expect(!store.isUnread(tabID: tab))
        #expect(stored.marks[tab] == .some(nil))
    }

    @Test func theLaunchStatusRestoreNeitherWipesNorCreatesAMark() {
        let engine = StatusEngine(backgroundTasks: BackgroundTaskTracker())
        let store = UnreadStore()
        store.observe(engine) { .inactive }
        let other = UUID()
        engine.restore(tabID: tab, taskID: task)
        engine.restore(tabID: other, taskID: task)
        store.restore(tabID: tab, messageID: "m1")

        store.record(.notStarted, tabID: tab, isSeen: false)
        store.latestMessageChanged(tabID: tab, to: "m1")
        engine.restore(tabID: tab, taskID: task)
        store.latestMessageChanged(tabID: other, to: "m2")

        #expect(store.isUnread(tabID: tab))
        #expect(!store.isUnread(tabID: other))
    }

    @Test func aNewTurnClearsARestoredMark() {
        let store = UnreadStore()
        let stored = recording(store)
        store.restore(tabID: tab, messageID: "m1")
        store.latestMessageChanged(tabID: tab, to: "m1")

        store.record(.working, tabID: tab, isSeen: false)

        #expect(!store.isUnread(tabID: tab))
        #expect(stored.marks[tab] == .some(nil))
    }

    // MARK: - UnreadPersistence

    private func chatTab(provider: AgentProviderKind = .claudeCode, transport: AgentTransport = .headless) -> TaskTab {
        let tab = TaskTab(kind: .agent, orderIndex: 0)
        tab.provider = provider
        tab.transport = transport
        return tab
    }

    private func persistence(_ store: UnreadStore, cache: CodexHistoryCache? = nil) -> UnreadPersistence {
        UnreadPersistence(
            unread: store,
            transcripts: TranscriptStore(debounce: .milliseconds(10)),
            codexItems: CodexItemStore(),
            codexCache: cache
        )
    }

    @Test func onlyChatTabsStoreTheirMark() {
        let store = UnreadStore()
        let chat = chatTab()
        let terminal = chatTab(transport: .terminal)
        let tabs = [chat.id: chat, terminal.id: terminal]
        persistence(store).install { tabs[$0] }
        store.latestMessageChanged(tabID: chat.id, to: "m1")
        store.latestMessageChanged(tabID: terminal.id, to: "m1")

        store.markUnread([chat.id, terminal.id])

        #expect(chat.unreadMessageID == "m1")
        #expect(terminal.unreadMessageID == nil)
    }

    @Test func codexItemsFeedTheLatestMessage() {
        let store = UnreadStore()
        let chat = chatTab(provider: .codex)
        let items = CodexItemStore()
        UnreadPersistence(unread: store, transcripts: TranscriptStore(), codexItems: items, codexCache: nil)
            .install { $0 == chat.id ? chat : nil }
        items.upsert(tabID: chat.id, item: .object(["id": .string("a"), "type": .string("agentMessage")]), turnID: "t1")
        store.markUnread([chat.id])
        #expect(chat.unreadMessageID == "t1#a")

        items.upsert(tabID: chat.id, item: .object(["id": .string("b"), "type": .string("agentMessage")]), turnID: "t1")

        #expect(chat.unreadMessageID == "t1#b")
    }

    @Test func aCodexMarkIsConfirmedFromItsCachedHistory() async {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = CodexHistoryCache(directory: directory)
        let kept = chatTab(provider: .codex)
        let stale = chatTab(provider: .codex)
        for tab in [kept, stale] {
            tab.agentSessionID = "thread"
            await cache.schedule(tabID: tab.id, snapshot: .init(threadID: "thread", entries: [
                .init(stableID: "t1#a", item: .object([:])),
                .init(stableID: "t2#b", item: .object([:])),
            ]))
        }
        kept.unreadMessageID = "t2#b"
        stale.unreadMessageID = "t1#a"
        let tabs = [kept.id: kept, stale.id: stale]
        let store = UnreadStore()
        let persistence = persistence(store, cache: cache)
        persistence.install { tabs[$0] }

        for read in persistence.restore([kept, stale]) { await read.value }

        #expect(store.isUnread(tabID: kept.id))
        #expect(kept.unreadMessageID == "t2#b")
        #expect(!store.isUnread(tabID: stale.id))
        #expect(stale.unreadMessageID == nil)
    }

    @Test func aStoredMarkOnATerminalTabIsDiscarded() {
        let store = UnreadStore()
        let terminal = chatTab(transport: .terminal)
        terminal.unreadMessageID = "m1"

        persistence(store).restore([terminal])

        #expect(terminal.unreadMessageID == nil)
        #expect(!store.isUnread(tabID: terminal.id))
    }

    private func read(_ transcripts: TranscriptStore, tab: UUID, path: URL) async {
        await withCheckedContinuation { continuation in
            transcripts.didRead = { _ in
                transcripts.didRead = nil
                continuation.resume()
            }
            transcripts.watch(tabID: tab, transcriptPath: path.path)
        }
    }

    @Test func aTranscriptReadConfirmsAClaudeCodeMark() async {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "session.jsonl")
        let line = "{\"type\":\"user\",\"uuid\":\"u1\",\"isSidechain\":false,\"message\":{\"role\":\"user\",\"content\":\"Hi\"}}\n"
        try? line.write(to: path, atomically: true, encoding: .utf8)
        let transcripts = TranscriptStore(debounce: .milliseconds(10))
        let kept = chatTab()
        let stale = chatTab()
        await read(transcripts, tab: kept.id, path: path)
        kept.unreadMessageID = transcripts.transcript(forTab: kept.id)?.messages.last?.id
        stale.unreadMessageID = "an earlier message"
        transcripts.stopWatching(tabID: kept.id)
        let tabs = [kept.id: kept, stale.id: stale]
        let store = UnreadStore()
        let persistence = UnreadPersistence(unread: store, transcripts: transcripts, codexItems: CodexItemStore(), codexCache: nil)
        persistence.install { tabs[$0] }

        persistence.restore([kept, stale])
        await read(transcripts, tab: kept.id, path: path)
        await read(transcripts, tab: stale.id, path: path)

        #expect(kept.unreadMessageID != nil)
        #expect(store.isUnread(tabID: kept.id))
        #expect(!store.isUnread(tabID: stale.id))
        #expect(stale.unreadMessageID == nil)
    }
}
