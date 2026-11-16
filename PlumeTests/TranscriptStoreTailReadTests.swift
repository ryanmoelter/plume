import Foundation
import Testing

@testable import Plume

/// A main transcript that only grew is read from where the last read
/// stopped; any other change is read whole. Either way the published
/// transcript equals a parse of the file from scratch.
@MainActor
struct TranscriptStoreTailReadTests {
    private final class Recorder {
        var paths: [TranscriptStore.ParentReadPath] = []
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

    /// Same file, new bytes.
    private func rewriteInPlace(_ text: String, at url: URL) {
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        try? handle.truncate(atOffset: 0)
        handle.write(Data(text.utf8))
    }

    private func line(_ uuid: String, parent: String?, _ text: String) -> String {
        let parentField = parent.map { #""parentUuid":"\#($0)","# } ?? ""
        return #"{"type":"user","uuid":"\#(uuid)",\#(parentField)"message":{"role":"user","content":"\#(text)"}}"#
            + "\n"
    }

    private func reply(_ uuid: String, parent: String, id: String, _ text: String) -> String {
        #"{"type":"assistant","uuid":"\#(uuid)","parentUuid":"\#(parent)","message":{"id":"\#(id)","role":"assistant","content":[{"type":"text","text":"\#(text)"}]}}"#
            + "\n"
    }

    private func fullParse(_ url: URL) -> Transcript {
        TranscriptParser.parse((try? Data(contentsOf: url)) ?? Data())
    }

    private func watching(_ url: URL) -> (TranscriptStore, UUID, Recorder) {
        let store = TranscriptStore(debounce: .milliseconds(10))
        let recorder = Recorder()
        store.didReadParent = { _, path in recorder.paths.append(path) }
        let tab = UUID()
        store.watch(tabID: tab, transcriptPath: url.path)
        return (store, tab, recorder)
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

    @Test func anAppendIsReadFromWhereTheLastReadStopped() async throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "session.jsonl")
        try Data((line("u1", parent: nil, "start") + reply("a1", parent: "u1", id: "m1", "one")).utf8).write(to: url)

        let (store, tab, recorder) = watching(url)
        await waitUntil(store) { store.transcript(forTab: tab)?.messages.count == 2 }
        #expect(recorder.paths == [.full])

        // A fork off `u1` whose live branch is only known once the last row lands.
        append(line("u2", parent: "a1", "abandoned") + line("u3", parent: "a1", "kept"), to: url)
        append(reply("a2", parent: "u3", id: "m2", "two"), to: url)
        let expected = fullParse(url)
        await waitUntil(store) { store.transcript(forTab: tab) == expected }

        #expect(store.transcript(forTab: tab) == expected)
        #expect(expected.forkPoints == ["a1"])
        #expect(recorder.paths.contains(.appended))
        #expect(!recorder.paths.dropFirst().contains(.full))
    }

    @Test func aRewriteInPlaceIsReadWhole() async throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "session.jsonl")
        try Data((line("u1", parent: nil, "first") + line("u2", parent: "u1", "second")).utf8).write(to: url)

        let (store, tab, recorder) = watching(url)
        await waitUntil(store) { store.transcript(forTab: tab)?.messages.count == 2 }

        // Longer than before, so only the bytes before the old end show it changed.
        rewriteInPlace(line("x1", parent: nil, "other") + line("x2", parent: "x1", "rewritten") + line("x3", parent: "x2", "and more"), at: url)
        let expected = fullParse(url)
        await waitUntil(store) { store.transcript(forTab: tab) == expected }

        #expect(store.transcript(forTab: tab)?.messages.map(\.id) == ["x1", "x2", "x3"])
        #expect(recorder.paths.dropFirst().contains(.full))
        #expect(!recorder.paths.contains(.appended))
    }

    @Test func aTruncationIsReadWhole() async throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "session.jsonl")
        try Data((line("u1", parent: nil, "first") + line("u2", parent: "u1", "second")).utf8).write(to: url)

        let (store, tab, recorder) = watching(url)
        await waitUntil(store) { store.transcript(forTab: tab)?.messages.count == 2 }

        rewriteInPlace(line("u1", parent: nil, "first"), at: url)
        let expected = fullParse(url)
        await waitUntil(store) { store.transcript(forTab: tab) == expected }

        #expect(store.transcript(forTab: tab)?.messages.map(\.id) == ["u1"])
        #expect(recorder.paths.dropFirst().contains(.full))
        #expect(!recorder.paths.contains(.appended))
    }

    /// The replacement starts with the old bytes, so only the new inode
    /// tells it apart from an append.
    @Test func aReplacedFileIsReadWhole() async throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "session.jsonl")
        let original = line("u1", parent: nil, "first")
        try Data(original.utf8).write(to: url)

        let (store, tab, recorder) = watching(url)
        await waitUntil(store) { store.transcript(forTab: tab)?.messages.count == 1 }

        try Data((original + line("u2", parent: "u1", "second")).utf8).write(to: url, options: .atomic)
        let expected = fullParse(url)
        await waitUntil(store) { store.transcript(forTab: tab) == expected }

        #expect(store.transcript(forTab: tab)?.messages.map(\.id) == ["u1", "u2"])
        #expect(recorder.paths.dropFirst().contains(.full))
        #expect(!recorder.paths.contains(.appended))
    }

    @Test func aLineWrittenInTwoPartsCountsOnceWhole() async throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "session.jsonl")
        try Data(line("u1", parent: nil, "start").utf8).write(to: url)

        let (store, tab, recorder) = watching(url)
        await waitUntil(store) { store.transcript(forTab: tab)?.messages.count == 1 }

        // A whole line with no newline yet counts, as it does for a full parse.
        let pending = reply("a1", parent: "u1", id: "m1", "partial").dropLast()
        append(String(pending), to: url)
        let withPending = fullParse(url)
        #expect(withPending.messages.count == 2)
        await waitUntil(store) { store.transcript(forTab: tab) == withPending }

        // Half a line decodes as nothing, so the transcript is unchanged.
        let next = line("u2", parent: "a1", "next")
        let half = next.index(next.startIndex, offsetBy: next.count / 2)
        append("\n" + next[..<half], to: url)
        let readsBefore = recorder.paths.count
        await waitUntil(store) { recorder.paths.count > readsBefore }
        #expect(store.transcript(forTab: tab) == fullParse(url))

        append(String(next[half...]) + reply("a2", parent: "u2", id: "m2", "done"), to: url)
        let expected = fullParse(url)
        #expect(expected.messages.map(\.id) == ["u1", "m1", "u2", "m2"])
        await waitUntil(store) { store.transcript(forTab: tab) == expected }

        #expect(store.transcript(forTab: tab) == expected)
        #expect(!recorder.paths.dropFirst().contains(.full))
        #expect(recorder.paths.contains(.appended))
    }
}
