import Foundation

/// What a file looked like when it was last read. A different fingerprint
/// means the file changed; a different `fileNumber` means it was replaced.
nonisolated struct FileFingerprint: Equatable, Sendable {
    let size: UInt64
    let modifiedAt: Date?
    let fileNumber: UInt64

    init?(path: String) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        modifiedAt = attributes[.modificationDate] as? Date
        fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    }
}

/// Each subagent transcript's parse, kept between reads so a write to one
/// subagent re-parses only that subagent's file, and a file that only grew
/// decodes only its new lines.
nonisolated struct SubagentTranscriptCache {
    /// How one read reached each file's transcript.
    struct Stats: Equatable, Sendable {
        var reused = 0
        var appended = 0
        var fullParses = 0
    }

    private struct Entry {
        let fingerprint: FileFingerprint
        let transcript: Transcript
        /// Decoded lines up to `consumed`, held only while the file is still
        /// being written. A finished subagent stops writing, and holding its
        /// lines would double its memory for nothing.
        var lines: [TranscriptEntry]?
        /// Bytes through the last newline. Anything after it is a line still
        /// being written, decoded again on the next read.
        let consumed: UInt64
        /// The bytes just before `consumed`, compared on the next read to
        /// tell an append from a rewrite of the same file.
        let seam: Data
    }

    /// How long after its last write a file keeps its decoded lines.
    static let lineRetention: TimeInterval = 300
    private static let seamLength = 64

    private var entries: [String: Entry] = [:]
    private(set) var stats = Stats()

    init() {}

    /// Starts a read: drops files no longer listed and resets `stats`.
    mutating func beginRead(paths: [String]) {
        let listed = Set(paths)
        entries = entries.filter { listed.contains($0.key) }
        stats = Stats()
    }

    /// The transcript at `path`, re-parsed only as far as it changed since the
    /// last call. Nil when the file cannot be read.
    mutating func transcript(atPath path: String, now: Date = Date()) -> (transcript: Transcript, modifiedAt: Date?)? {
        guard let fingerprint = FileFingerprint(path: path) else {
            entries[path] = nil
            return nil
        }
        let keepsLines = fingerprint.modifiedAt.map { now.timeIntervalSince($0) < Self.lineRetention } ?? false

        if var cached = entries[path], cached.fingerprint == fingerprint {
            stats.reused += 1
            if !keepsLines, cached.lines != nil {
                cached.lines = nil
                entries[path] = cached
            }
            return (cached.transcript, fingerprint.modifiedAt)
        }

        if let cached = entries[path], let lines = cached.lines,
           cached.fingerprint.fileNumber == fingerprint.fileNumber,
           fingerprint.size >= cached.consumed,
           let appended = Self.bytes(atPath: path, after: cached.consumed, seam: cached.seam) {
            stats.appended += 1
            return store(
                path: path,
                fingerprint: fingerprint,
                lines: lines,
                consumed: cached.consumed,
                seamSource: cached.seam,
                newBytes: appended,
                keepsLines: keepsLines
            )
        }

        guard let data = FileManager.default.contents(atPath: path) else {
            entries[path] = nil
            return nil
        }
        stats.fullParses += 1
        return store(
            path: path,
            fingerprint: fingerprint,
            lines: [],
            consumed: 0,
            seamSource: Data(),
            newBytes: data,
            keepsLines: keepsLines
        )
    }

    private mutating func store(
        path: String,
        fingerprint: FileFingerprint,
        lines previousLines: [TranscriptEntry],
        consumed previousConsumed: UInt64,
        seamSource: Data,
        newBytes: Data,
        keepsLines: Bool
    ) -> (transcript: Transcript, modifiedAt: Date?) {
        let completeLength = (newBytes.lastIndex(of: UInt8(ascii: "\n")).map { $0 + 1 } ?? newBytes.startIndex)
            - newBytes.startIndex
        let complete = newBytes.prefix(completeLength)
        let unfinished = newBytes.dropFirst(completeLength)

        var lines = previousLines
        lines.append(contentsOf: TranscriptParser.decodedEntries(in: Data(complete)))
        // A last line with no newline yet still counts if it decodes, as it
        // does for a whole-file parse.
        let transcript = unfinished.isEmpty
            ? TranscriptParser.parse(entries: lines, includeSidechain: true)
            : TranscriptParser.parse(
                entries: lines + Array(TranscriptParser.decodedEntries(in: Data(unfinished))),
                includeSidechain: true
            )
        let seam = (seamSource + complete).suffix(Self.seamLength)
        entries[path] = Entry(
            fingerprint: fingerprint,
            transcript: transcript,
            lines: keepsLines ? lines : nil,
            consumed: previousConsumed + UInt64(completeLength),
            seam: Data(seam)
        )
        return (transcript, fingerprint.modifiedAt)
    }

    /// The bytes after `offset`, or nil when the bytes before it no longer
    /// match `seam` — the file was rewritten rather than appended to.
    private static func bytes(atPath path: String, after offset: UInt64, seam: Data) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let seamStart = offset - UInt64(seam.count)
        guard (try? handle.seek(toOffset: seamStart)) != nil,
              let data = try? handle.readToEnd() ?? Data(),
              data.count >= seam.count,
              data.prefix(seam.count) == seam
        else { return nil }
        return Data(data.dropFirst(seam.count))
    }
}
