import Testing
import Foundation
@testable import Plume

/// The cache re-parses a subagent file only as far as it changed, and every
/// transcript it returns equals a whole-file parse of the same bytes.
struct SubagentTranscriptCacheTests {
    private let directory: URL
    private let path: String

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        path = directory.appending(path: "agent-a.jsonl").path
    }

    private func write(_ text: String) throws {
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func append(_ text: String) throws {
        let handle = try #require(FileHandle(forWritingAtPath: path))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private func wholeFileParse() throws -> Transcript {
        TranscriptParser.parse(try #require(FileManager.default.contents(atPath: path)), includeSidechain: true)
    }

    private func line(_ text: String, uuid: String = UUID().uuidString, parent: String? = nil) -> String {
        let parentField = parent.map { "\"\($0)\"" } ?? "null"
        return "{\"type\":\"user\",\"uuid\":\"\(uuid)\",\"parentUuid\":\(parentField),\"isSidechain\":true,\"message\":{\"role\":\"user\",\"content\":\"\(text)\"}}\n"
    }

    @Test func anUnchangedFileIsReused() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(line("one"))
        var cache = SubagentTranscriptCache()

        cache.beginRead(paths: [path])
        let first = cache.transcript(atPath: path)?.transcript
        cache.beginRead(paths: [path])
        let second = cache.transcript(atPath: path)?.transcript

        #expect(cache.stats == .init(reused: 1, appended: 0, fullParses: 0))
        #expect(first == second)
    }

    @Test func anAppendDecodesOnlyTheNewLines() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(line("one", uuid: "u1"))
        var cache = SubagentTranscriptCache()
        cache.beginRead(paths: [path])
        _ = cache.transcript(atPath: path)

        try append(line("two", uuid: "u2", parent: "u1"))
        cache.beginRead(paths: [path])
        let transcript = cache.transcript(atPath: path)?.transcript

        #expect(cache.stats == .init(reused: 0, appended: 1, fullParses: 0))
        #expect(transcript?.messages.count == 2)
        #expect(transcript == (try wholeFileParse()))
    }

    @Test func aLineStillBeingWrittenIsReadOnceItCompletes() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let second = line("two", uuid: "u2", parent: "u1")
        let cut = second.index(second.startIndex, offsetBy: 30)
        try write(line("one", uuid: "u1") + second[..<cut])
        var cache = SubagentTranscriptCache()
        cache.beginRead(paths: [path])
        #expect(cache.transcript(atPath: path)?.transcript == (try wholeFileParse()))

        try append(String(second[cut...]))
        cache.beginRead(paths: [path])
        let transcript = cache.transcript(atPath: path)?.transcript

        #expect(cache.stats.appended == 1)
        #expect(transcript?.messages.count == 2)
        #expect(transcript == (try wholeFileParse()))
    }

    @Test func aShrunkFileIsParsedWhole() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(line("one") + line("two"))
        var cache = SubagentTranscriptCache()
        cache.beginRead(paths: [path])
        _ = cache.transcript(atPath: path)

        try write(line("three"))
        cache.beginRead(paths: [path])
        let transcript = cache.transcript(atPath: path)?.transcript

        #expect(cache.stats.fullParses == 1)
        #expect(transcript?.messages.count == 1)
        #expect(transcript == (try wholeFileParse()))
    }

    /// Truncated and rewritten in place, so the file keeps its inode and grows
    /// past the old length. Only the bytes before the old end tell it apart
    /// from an append.
    @Test func aFileRewrittenInPlaceIsParsedWhole() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(line("one", uuid: "u1"))
        var cache = SubagentTranscriptCache()
        cache.beginRead(paths: [path])
        _ = cache.transcript(atPath: path)

        let handle = try #require(FileHandle(forWritingAtPath: path))
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data((line("uno", uuid: "x1") + line("dos", uuid: "x2", parent: "x1")).utf8))
        try handle.close()
        cache.beginRead(paths: [path])
        let transcript = cache.transcript(atPath: path)?.transcript

        #expect(cache.stats.fullParses == 1)
        #expect(transcript?.messages.map(\.id) == ["x1", "x2"])
        #expect(transcript == (try wholeFileParse()))
    }

    /// A finished subagent drops its decoded lines, so growing again later
    /// costs one whole parse rather than being wrong.
    @Test func aFileQuietPastTheRetentionIsParsedWholeWhenItGrows() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(line("one", uuid: "u1"))
        let later = Date().addingTimeInterval(SubagentTranscriptCache.lineRetention + 60)
        var cache = SubagentTranscriptCache()
        cache.beginRead(paths: [path])
        _ = cache.transcript(atPath: path, now: later)

        try append(line("two", uuid: "u2", parent: "u1"))
        cache.beginRead(paths: [path])
        let transcript = cache.transcript(atPath: path)?.transcript

        #expect(cache.stats.fullParses == 1)
        #expect(transcript == (try wholeFileParse()))
    }

    @Test func aMissingFileReadsAsNil() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(line("one"))
        var cache = SubagentTranscriptCache()
        cache.beginRead(paths: [path])
        _ = cache.transcript(atPath: path)

        try FileManager.default.removeItem(atPath: path)
        cache.beginRead(paths: [path])
        #expect(cache.transcript(atPath: path) == nil)
    }
}
