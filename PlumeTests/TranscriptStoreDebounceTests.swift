import Foundation
import Testing

@testable import Plume

/// The first change to a transcript is read at once. Changes that follow
/// inside the debounce window wait for it to close and share one read.
@MainActor
struct TranscriptStoreDebounceTests {
    /// Holds every debounce window open until the test opens it, so a window
    /// ends when the test says rather than when a clock does.
    private actor Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
    }

    private final class Counter {
        var reads = 0
    }

    private func makeTempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func append(_ text: String, to url: URL) {
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(Data(text.utf8))
    }

    private func line(_ text: String) -> String {
        #"{"type":"user","uuid":"\#(text)","message":{"role":"user","content":"\#(text)"}}"# + "\n"
    }

    private func messageIDs(_ store: TranscriptStore, _ tab: UUID) -> [String] {
        store.transcript(forTab: tab)?.messages.map(\.id) ?? []
    }

    /// Resumes on the store's own read signal, never a clock.
    private func waitUntil(_ store: TranscriptStore, _ condition: @escaping () -> Bool) async {
        guard !condition() else { return }
        await withCheckedContinuation { continuation in
            var resumed = false
            store.didRead = { _ in
                guard !resumed, condition() else { return }
                resumed = true
                continuation.resume()
            }
        }
        store.didRead = nil
    }

    private func watching(_ url: URL, store: TranscriptStore) async -> (UUID, Counter) {
        let counter = Counter()
        store.didReadParent = { _, _ in counter.reads += 1 }
        let tab = UUID()
        store.watch(tabID: tab, transcriptPath: url.path)
        await waitUntil(store) { !self.messageIDs(store, tab).isEmpty }
        return (tab, counter)
    }

    /// Under a trailing-only debounce this would wait out the whole 60 s.
    @Test func theFirstChangeIsReadWithoutWaitingOutTheDebounce() async throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "session.jsonl")
        try Data(line("u1").utf8).write(to: url)
        let store = TranscriptStore(debounce: .seconds(60))
        let (tab, _) = await watching(url, store: store)

        append(line("u2"), to: url)
        await waitUntil(store) { self.messageIDs(store, tab) == ["u1", "u2"] }

        #expect(messageIDs(store, tab) == ["u1", "u2"])
    }

    @Test func aChangeInsideTheWindowIsReadWhenTheWindowCloses() async throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "session.jsonl")
        try Data(line("u1").utf8).write(to: url)
        let gate = Gate()
        let store = TranscriptStore(debounce: .seconds(60), sleep: { _ in await gate.wait() })
        let (tab, _) = await watching(url, store: store)

        append(line("u2"), to: url)
        await waitUntil(store) { self.messageIDs(store, tab) == ["u1", "u2"] }

        append(line("u3"), to: url)
        await withCheckedContinuation { continuation in
            store.didDeferToWindowEnd = { _ in
                store.didDeferToWindowEnd = nil
                continuation.resume()
            }
        }
        #expect(messageIDs(store, tab) == ["u1", "u2"])

        await gate.open()
        await waitUntil(store) { self.messageIDs(store, tab) == ["u1", "u2", "u3"] }
        #expect(messageIDs(store, tab) == ["u1", "u2", "u3"])
    }

    @Test func aBurstOfWritesSharesAFewReads() async throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "session.jsonl")
        try Data(line("u0").utf8).write(to: url)
        let gate = Gate()
        let store = TranscriptStore(debounce: .seconds(60), sleep: { _ in await gate.wait() })
        let (tab, counter) = await watching(url, store: store)
        let readsBefore = counter.reads

        let writes = 40
        for index in 1...writes {
            append(line("u\(index)"), to: url)
            await Task.yield()
        }
        await gate.open()
        let expected = (0...writes).map { "u\($0)" }
        await waitUntil(store) { self.messageIDs(store, tab) == expected }

        #expect(messageIDs(store, tab) == expected)
        #expect(counter.reads - readsBefore < writes / 4)
    }
}
