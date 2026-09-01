import Testing
import Foundation
@testable import Plume

struct HookEventIngesterTests {
    private func makeFile() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "plume-events-\(UUID().uuidString).jsonl")
    }

    private func append(_ lines: [String], to url: URL) throws {
        let text = lines.map { $0 + "\n" }.joined()
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
        } else {
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func event(_ name: String, session: String = "s1") -> String {
        #"{"hook_event_name":"\#(name)","session_id":"\#(session)","cwd":"/tmp"}"#
    }

    @Test func readsEventsAppendedSinceTheLastRead() throws {
        let url = makeFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let ingester = HookEventIngester()

        try append([event("SessionStart"), event("UserPromptSubmit")], to: url)
        let first = ingester.readNewEvents(at: url)
        #expect(first.map(\.hookEventName) == ["SessionStart", "UserPromptSubmit"])

        // Nothing new yet.
        #expect(ingester.readNewEvents(at: url).isEmpty)

        try append([event("Stop")], to: url)
        #expect(ingester.readNewEvents(at: url).map(\.hookEventName) == ["Stop"])
    }

    /// The whole backlog written while Plume was closed must replay.
    @Test func replaysEverythingOnFirstRead() throws {
        let url = makeFile()
        defer { try? FileManager.default.removeItem(at: url) }

        try append([event("SessionStart"), event("Notification"), event("Stop")], to: url)

        let events = HookEventIngester().readNewEvents(at: url)
        #expect(events.count == 3)
        #expect(events.last?.kind == .stop)
    }

    @Test func skipExistingIgnoresTheBacklog() throws {
        let url = makeFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let ingester = HookEventIngester()

        try append([event("SessionStart")], to: url)
        ingester.skipExisting(at: url)
        #expect(ingester.readNewEvents(at: url).isEmpty)

        try append([event("Stop")], to: url)
        #expect(ingester.readNewEvents(at: url).map(\.hookEventName) == ["Stop"])
    }

    /// A truncated or replaced file must not be read from a stale offset.
    @Test func aShrunkFileIsReadFromTheStart() throws {
        let url = makeFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let ingester = HookEventIngester()

        try append([event("SessionStart"), event("PreToolUse")], to: url)
        _ = ingester.readNewEvents(at: url)

        try Data().write(to: url)
        try append([event("Notification")], to: url)

        #expect(ingester.readNewEvents(at: url).map(\.hookEventName) == ["Notification"])
    }

    @Test func malformedLinesAreSkipped() throws {
        let url = makeFile()
        defer { try? FileManager.default.removeItem(at: url) }

        try append([event("SessionStart"), "not json at all", "", event("Stop")], to: url)

        let events = HookEventIngester().readNewEvents(at: url)
        #expect(events.map(\.hookEventName) == ["SessionStart", "Stop"])
    }

    @Test func aMissingFileYieldsNothing() {
        #expect(HookEventIngester().readNewEvents(at: makeFile()).isEmpty)
    }

    @Test func sessionIDIsCaptured() throws {
        let url = makeFile()
        defer { try? FileManager.default.removeItem(at: url) }

        try append([event("SessionStart", session: "abc-123")], to: url)

        #expect(HookEventIngester().readNewEvents(at: url).first?.sessionID == "abc-123")
    }

    @Test func unknownFieldsDoNotBreakDecoding() throws {
        let url = makeFile()
        defer { try? FileManager.default.removeItem(at: url) }

        try append([#"{"hook_event_name":"Stop","session_id":"s","brand_new_field":{"a":1}}"#], to: url)

        #expect(HookEventIngester().readNewEvents(at: url).first?.kind == .stop)
    }

    /// Verbatim payloads Claude Code wrote during a real `/clear`.
    @Test func aClearDecodesItsSourceAndReason() throws {
        let url = makeFile()
        defer { try? FileManager.default.removeItem(at: url) }

        try append([
            #"{"session_id":"3176c2af","transcript_path":"/t/3176c2af.jsonl","cwd":"/w","prompt_id":"78c451fa","hook_event_name":"SessionEnd","reason":"clear"}"#,
            #"{"session_id":"68b117c1","transcript_path":"/t/68b117c1.jsonl","cwd":"/w","hook_event_name":"SessionStart","source":"clear"}"#,
        ], to: url)

        let events = HookEventIngester().readNewEvents(at: url)

        #expect(events.first?.reason == "clear")
        #expect(events.first?.endsClearedSession == true)
        #expect(events.last?.source == "clear")
        #expect(events.last?.sessionID == "68b117c1")
    }

    @Test func anOrdinarySessionEndIsNotAClear() throws {
        let url = makeFile()
        defer { try? FileManager.default.removeItem(at: url) }

        try append([
            #"{"hook_event_name":"SessionEnd","session_id":"s","reason":"other"}"#,
            #"{"hook_event_name":"SessionStart","session_id":"s"}"#,
        ], to: url)

        let events = HookEventIngester().readNewEvents(at: url)

        #expect(events.first?.endsClearedSession == false)
        #expect(events.last?.source == nil)
        #expect(events.last?.endsClearedSession == false)
    }

    @Test func rotationOnlyHappensAfterEverythingIsRead() throws {
        let url = makeFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let ingester = HookEventIngester()

        let padding = String(repeating: "x", count: HookEventIngester.rotationThreshold)
        try append([#"{"hook_event_name":"Stop","session_id":"s","pad":"\#(padding)"}"#], to: url)

        // Unread: rotating now would lose events.
        ingester.rotateIfNeeded(at: url)
        #expect(!ingester.readNewEvents(at: url).isEmpty)

        ingester.rotateIfNeeded(at: url)
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
        #expect(size == 0)
    }

    @Test func smallFilesAreNotRotated() throws {
        let url = makeFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let ingester = HookEventIngester()

        try append([event("Stop")], to: url)
        _ = ingester.readNewEvents(at: url)
        ingester.rotateIfNeeded(at: url)

        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
        #expect((size ?? 0) > 0)
    }

    @Test func readingResumesFromZeroAfterForgetting() throws {
        let url = makeFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let ingester = HookEventIngester()

        try append([event("SessionStart")], to: url)
        _ = ingester.readNewEvents(at: url)
        ingester.forget(url)

        #expect(ingester.readNewEvents(at: url).count == 1)
    }
}
