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

        await waitUntil { store.transcript(forTab: tab)?.messages.count == 1 }
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
        await waitUntil { store.transcript(forTab: tab)?.messages.count == 1 }
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
        await waitUntil { store.transcript(forTab: tab)?.messages.count == 1 }
        #expect(store.transcript(forTab: tab)?.messages.count == 1)

        store.watch(tabID: tab, transcriptPath: secondPath.path)
        await waitUntil { store.transcript(forTab: tab)?.messages.count == 2 }
        #expect(store.transcript(forTab: tab)?.messages.count == 2)

        // The old file changing must not resurrect the old watch.
        append(userLine("Ignored"), to: firstPath)
        await waitUntil(timeout: .milliseconds(200)) { false }
        #expect(store.transcript(forTab: tab)?.messages.count == 2)
    }

    /// `watch` is called again on every hook event for a tab. Re-reading on
    /// those calls bypassed the debounce and kept a core busy re-parsing a
    /// file nothing had written to.
    @Test func rewatchingTheSamePathDoesNotReparse() async {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "session.jsonl")
        write(userLine("first"), to: url)

        let store = TranscriptStore(debounce: .milliseconds(50))
        let tab = UUID()
        store.watch(tabID: tab, transcriptPath: url.path)
        await waitUntil { store.transcript(forTab: tab)?.messages.count == 1 }
        #expect(store.transcript(forTab: tab)?.messages.count == 1)

        // Change the file behind the store's back, then re-watch the same
        // path. A re-parse here would pick the new line up immediately.
        write(userLine("first") + "\n" + userLine("second"), to: url)
        for _ in 0..<20 {
            store.watch(tabID: tab, transcriptPath: url.path)
        }
        #expect(
            store.transcript(forTab: tab)?.messages.count == 1,
            "re-watching the same path re-parsed instead of leaving it to the watcher"
        )

        // The watcher still delivers it, on the debounce.
        await waitUntil { store.transcript(forTab: tab)?.messages.count == 2 }
        #expect(store.transcript(forTab: tab)?.messages.count == 2)
    }

    @Test func stopWatchingDropsTheTranscript() async {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appending(path: "session.jsonl")
        write(userLine("Hello"), to: path)

        let store = TranscriptStore(debounce: .milliseconds(10))
        let tab = UUID()
        store.watch(tabID: tab, transcriptPath: path.path)
        await waitUntil { store.transcript(forTab: tab) != nil }
        #expect(store.transcript(forTab: tab) != nil)

        store.stopWatching(tabID: tab)
        #expect(store.transcript(forTab: tab) == nil)
    }

    @Test func anUnwatchedTabReturnsNil() {
        let store = TranscriptStore(debounce: .milliseconds(10))
        #expect(store.transcript(forTab: UUID()) == nil)
    }

    @Test func subagentsAreEnumeratedFromTheSubagentsDirectory() async {
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
        await waitUntil { store.subagents(forTab: tab).count == 2 }

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

    /// The subagent transcript is all sidechain lines, so this also covers the
    /// store parsing them with `includeSidechain`.
    @Test func aSubagentIsDescribedAndScoredFromItsSidecar() async {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appending(path: "session.jsonl")
        write(userLine("Main session"), to: path)

        let subagentsDir = dir.appending(path: "session/subagents")
        write(
            "{\"type\":\"assistant\",\"uuid\":\"a1\",\"isSidechain\":true,\"message\":{\"role\":\"assistant\",\"stop_reason\":\"end_turn\",\"content\":[{\"type\":\"text\",\"text\":\"Here is the report.\"}]}}\n",
            to: subagentsDir.appending(path: "agent-abc123.jsonl")
        )
        write(
            "{\"agentType\":\"Explore\",\"description\":\"Find the leak\",\"toolUseId\":\"toolu_1\"}",
            to: subagentsDir.appending(path: "agent-abc123.meta.json")
        )

        let store = TranscriptStore(debounce: .milliseconds(10))
        let tab = UUID()
        store.watch(tabID: tab, transcriptPath: path.path)
        await waitUntil { store.subagents(forTab: tab).count == 1 }

        let subagent = store.subagents(forTab: tab).first
        #expect(subagent?.title == "Explore: Find the leak")
        #expect(subagent?.status == .done)
        #expect(subagent?.transcript.messages.count == 1)
    }

    /// A subagent writes only its own file, so without a watcher per subagent
    /// the list would go stale until the main transcript happened to change.
    @Test func aSubagentsOwnWriteRefreshesTheList() async {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appending(path: "session.jsonl")
        write(userLine("Main session"), to: path)

        let subagentPath = dir.appending(path: "session/subagents/agent-abc123.jsonl")
        let working = "{\"type\":\"assistant\",\"uuid\":\"a1\",\"isSidechain\":true,\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"Bash\",\"input\":{}}]}}\n"
        write(working, to: subagentPath)

        let store = TranscriptStore(debounce: .milliseconds(10))
        let tab = UUID()
        store.watch(tabID: tab, transcriptPath: path.path)
        await waitUntil { store.subagents(forTab: tab).first?.status == .working }
        #expect(store.subagents(forTab: tab).first?.status == .working)

        // Only the subagent's file changes — the main transcript is untouched.
        append(
            "{\"type\":\"assistant\",\"uuid\":\"a2\",\"isSidechain\":true,\"message\":{\"role\":\"assistant\",\"stop_reason\":\"end_turn\",\"content\":[{\"type\":\"text\",\"text\":\"Report.\"}]}}\n",
            to: subagentPath
        )

        await waitUntil { store.subagents(forTab: tab).first?.status == .done }
        #expect(
            store.subagents(forTab: tab).first?.status == .done,
            "a subagent's own write did not refresh the list"
        )
    }

    /// Without a sidecar the description comes from the parent's spawning
    /// tool call, matched to the agent id its result reports.
    @Test func aSubagentWithNoSidecarIsDescribedFromTheParent() async {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appending(path: "session.jsonl")
        let spawn = "{\"type\":\"assistant\",\"uuid\":\"a1\",\"isSidechain\":false,\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"Task\",\"input\":{\"description\":\"Check the parser\",\"subagent_type\":\"Explore\"}}]}}\n"
        let launched = "{\"type\":\"user\",\"uuid\":\"u1\",\"isSidechain\":false,\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"toolu_1\",\"content\":\"Async agent launched successfully.\\nagentId: abc123\"}]}}\n"
        write(spawn + launched, to: path)

        write(
            "{\"type\":\"assistant\",\"uuid\":\"s1\",\"isSidechain\":true,\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"Bash\",\"input\":{}}]}}\n",
            to: dir.appending(path: "session/subagents/agent-abc123.jsonl")
        )

        let store = TranscriptStore(debounce: .milliseconds(10))
        let tab = UUID()
        store.watch(tabID: tab, transcriptPath: path.path)
        await waitUntil { store.subagents(forTab: tab).count == 1 }

        let subagent = store.subagents(forTab: tab).first
        #expect(subagent?.title == "Explore: Check the parser")
        // The launch acknowledgement is not completion.
        #expect(subagent?.status == .working)
    }

    /// Reading subagents must not touch the disk: a SwiftUI view asks for them
    /// from `body`, which re-evaluates on every scroll frame. A subagent file
    /// appearing after the last transcript read is therefore invisible until
    /// the transcript changes again.
    @Test func subagentsComeFromTheCacheRatherThanTheDisk() async {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appending(path: "session.jsonl")
        write(userLine("Main session"), to: path)

        let store = TranscriptStore(debounce: .milliseconds(10))
        let tab = UUID()
        store.watch(tabID: tab, transcriptPath: path.path)
        await waitUntil { store.transcript(forTab: tab) != nil }
        #expect(store.subagents(forTab: tab).isEmpty)

        write(userLine("Late subagent"), to: dir.appending(path: "session/subagents/agent-late.jsonl"))
        #expect(store.subagents(forTab: tab).isEmpty)
    }

    /// A subagent the user killed is not running, so the tab it belongs to
    /// settles instead of reading working forever.
    @Test func anInterruptedSubagentReleasesItsTab() async {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appending(path: "session.jsonl")
        write(userLine("Main session"), to: path)
        write(
            "{\"type\":\"assistant\",\"uuid\":\"a1\",\"isSidechain\":true,\"message\":{\"role\":\"assistant\",\"stop_reason\":\"tool_use\",\"content\":[{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"Bash\",\"input\":{}}]}}\n"
                + "{\"type\":\"user\",\"uuid\":\"u1\",\"isSidechain\":true,\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"[Request interrupted by user]\"}]}}\n",
            to: dir.appending(path: "session/subagents/agent-abc123.jsonl")
        )

        let engine = StatusEngine()
        let (task, tab) = (UUID(), UUID())
        engine.register(tabID: tab, taskID: task)
        engine.setStatus(.awaitingReply, taskID: task, tabID: tab)

        let store = TranscriptStore(debounce: .milliseconds(10), statusEngine: engine)
        store.watch(tabID: tab, transcriptPath: path.path)
        await waitUntil { store.subagents(forTab: tab).count == 1 }

        #expect(store.subagents(forTab: tab).first?.status == .interrupted)
        #expect(engine.status(forTab: tab) == .awaitingReply)
    }
}

/// The linger that hides a finished subagent is driven by the store, not by a
/// mounted view — a subagent that finishes while the user is looking at
/// another task still disappears on its own.
@MainActor
struct SubagentLingerIsDrivenByTheStoreTests {
    private func waitUntil(timeout: Duration = .seconds(2), _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func readingATranscriptObservesItsSubagents() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let path = dir.appending(path: "session.jsonl")
        try FileManager.default.createDirectory(
            at: dir.appending(path: "session/subagents"),
            withIntermediateDirectories: true
        )
        try Data().write(to: path)
        try Data(
            "{\"type\":\"assistant\",\"uuid\":\"a1\",\"isSidechain\":true,\"message\":{\"role\":\"assistant\",\"stop_reason\":\"end_turn\",\"content\":[{\"type\":\"text\",\"text\":\"Report.\"}]}}\n".utf8
        ).write(to: dir.appending(path: "session/subagents/agent-abc123.jsonl"))

        let tracker = SubagentCompletionTracker(linger: .zero)
        let store = TranscriptStore(debounce: .milliseconds(10), completionTracker: tracker)
        let tab = UUID()
        store.watch(tabID: tab, transcriptPath: path.path)
        await waitUntil { !store.subagents(forTab: tab).isEmpty }

        let subagent = try #require(store.subagents(forTab: tab).first)
        #expect(subagent.status == .done)
        // No view was ever mounted, so only the store can have observed this.
        #expect(tracker.hasSettled(subagent, tabID: tab))
    }
}
