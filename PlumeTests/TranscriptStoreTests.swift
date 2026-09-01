import Testing
import Foundation
@testable import Plume

@MainActor
struct TranscriptStoreTests {
    private func makeTempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, to url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func append(_ text: String, to url: URL) {
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(text.data(using: .utf8) ?? Data())
    }

    private func userLine(_ text: String) -> String {
        "{\"type\":\"user\",\"uuid\":\"\(UUID().uuidString)\",\"isSidechain\":false,\"message\":{\"role\":\"user\",\"content\":\"\(text)\"}}\n"
    }

    /// Bounded poll instead of a fixed sleep, so the check isn't flaky on a
    /// loaded machine but also doesn't wait the full timeout when it's fast.
    private func waitUntil(timeout: Duration = .seconds(2), _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func watchingAFileReadsItsParsedTranscript() async {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appending(path: "session.jsonl")
        write(userLine("Hello there"), to: path)

        let store = TranscriptStore(debounce: .milliseconds(10))
        let tab = UUID()
        store.watch(tabID: tab, transcriptPath: path.path)

        #expect(store.transcript(forTab: tab)?.messages.count == 1)
    }

    @Test func appendingALineUpdatesTheTranscriptAfterTheDebounce() async {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appending(path: "session.jsonl")
        write(userLine("First"), to: path)

        let store = TranscriptStore(debounce: .milliseconds(10))
        let tab = UUID()
        store.watch(tabID: tab, transcriptPath: path.path)
        #expect(store.transcript(forTab: tab)?.messages.count == 1)

        append(userLine("Second"), to: path)

        await waitUntil { store.transcript(forTab: tab)?.messages.count == 2 }
        #expect(store.transcript(forTab: tab)?.messages.count == 2)
    }

    @Test func rePointingATabReplacesTheWatch() async {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let firstPath = dir.appending(path: "first.jsonl")
        let secondPath = dir.appending(path: "second.jsonl")
        write(userLine("From first"), to: firstPath)
        write(userLine("From second") + userLine("Also second"), to: secondPath)

        let store = TranscriptStore(debounce: .milliseconds(10))
        let tab = UUID()
        store.watch(tabID: tab, transcriptPath: firstPath.path)
        #expect(store.transcript(forTab: tab)?.messages.count == 1)

        store.watch(tabID: tab, transcriptPath: secondPath.path)
        #expect(store.transcript(forTab: tab)?.messages.count == 2)

        // The old file changing must not resurrect the old watch.
        append(userLine("Ignored"), to: firstPath)
        await waitUntil(timeout: .milliseconds(200)) { false }
        #expect(store.transcript(forTab: tab)?.messages.count == 2)
    }

    @Test func stopWatchingDropsTheTranscript() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appending(path: "session.jsonl")
        write(userLine("Hello"), to: path)

        let store = TranscriptStore(debounce: .milliseconds(10))
        let tab = UUID()
        store.watch(tabID: tab, transcriptPath: path.path)
        #expect(store.transcript(forTab: tab) != nil)

        store.stopWatching(tabID: tab)
        #expect(store.transcript(forTab: tab) == nil)
    }

    @Test func anUnwatchedTabReturnsNil() {
        let store = TranscriptStore(debounce: .milliseconds(10))
        #expect(store.transcript(forTab: UUID()) == nil)
    }

    @Test func subagentsAreEnumeratedFromTheSubagentsDirectory() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appending(path: "session.jsonl")
        write(userLine("Main session"), to: path)

        let subagentsDir = dir.appending(path: "session/subagents")
        let firstSubagent = subagentsDir.appending(path: "agent-abc123.jsonl")
        let secondSubagent = subagentsDir.appending(path: "agent-def456.jsonl")
        write(userLine("Subagent one"), to: firstSubagent)
        write(userLine("Subagent two") + userLine("More"), to: secondSubagent)

        let store = TranscriptStore(debounce: .milliseconds(10))
        let tab = UUID()
        store.watch(tabID: tab, transcriptPath: path.path)

        let subagents = store.subagents(forTab: tab)
        #expect(subagents.count == 2)
        #expect(Set(subagents.map(\.id)) == ["abc123", "def456"])

        let second = subagents.first { $0.id == "def456" }
        #expect(second?.transcript.messages.count == 2)
        #expect(subagents.allSatisfy { $0.modifiedAt != nil })
    }

    @Test func aTabWithNoTranscriptHasNoSubagents() {
        let store = TranscriptStore(debounce: .milliseconds(10))
        #expect(store.subagents(forTab: UUID()).isEmpty)
    }

    /// Reading subagents must not touch the disk: a SwiftUI view asks for them
    /// from `body`, which re-evaluates on every scroll frame. A subagent file
    /// appearing after the last transcript read is therefore invisible until
    /// the transcript changes again.
    @Test func subagentsComeFromTheCacheRatherThanTheDisk() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appending(path: "session.jsonl")
        write(userLine("Main session"), to: path)

        let store = TranscriptStore(debounce: .milliseconds(10))
        let tab = UUID()
        store.watch(tabID: tab, transcriptPath: path.path)
        #expect(store.subagents(forTab: tab).isEmpty)

        write(userLine("Late subagent"), to: dir.appending(path: "session/subagents/agent-late.jsonl"))
        #expect(store.subagents(forTab: tab).isEmpty)
    }
}
