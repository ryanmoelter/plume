import Foundation

/// What a file looked like when it was last read. A different fingerprint
/// means the file changed; a different `fileNumber` means it was replaced.
nonisolated struct FileFingerprint: Equatable, Sendable {
    let size: UInt64
    let modifiedAt: Date?
    let fileNumber: UInt64

    /// `stat` rather than `attributesOfItem`, which also reads extended
    /// attributes and costs several times as much across hundreds of files.
    init?(path: String) {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        size = UInt64(info.st_size)
        modifiedAt = Date(
            timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
                + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
        )
        fileNumber = UInt64(info.st_ino)
    }
}

/// Each subagent transcript's parse, kept between reads so a write to one
/// subagent re-parses only that subagent's file, and a file that only grew
/// decodes only its new lines.
nonisolated struct SubagentTranscriptCache: Sendable {
    /// How one read reached each file's transcript.
    struct Stats: Equatable, Sendable {
        var reused = 0
        var appended = 0
        var fullParses = 0
    }

    private struct Entry: Sendable {
        let fingerprint: FileFingerprint
        let transcript: Transcript
        /// Decoded lines up to the cursor, held only while the file is still
        /// being written. A finished subagent stops writing, and holding its
        /// lines would double its memory for nothing.
        var lines: [TranscriptEntry]?
        let cursor: AppendCursor
        var evidence: (subagent: LinearSubagentRef, value: [LinearEvidence])?
    }

    private struct Sidecar: Sendable {
        let fingerprint: FileFingerprint
        let descriptor: SubagentDescriptor?
    }

    /// How long after its last write a file keeps its decoded lines.
    static let lineRetention: TimeInterval = 300
    /// How many bytes of file, newest files first, keep their decoded lines.
    /// A tab that goes idle reads no more, so the age limit alone would never
    /// release the lines of every subagent that was writing when it stopped.
    static let linesByteBudget: UInt64 = 64 << 20

    private var entries: [String: Entry] = [:]
    /// Keyed by the subagent transcript's path, like `entries`.
    private var sidecars: [String: Sidecar] = [:]
    private(set) var stats = Stats()

    init() {}

    /// Starts a read: resets `stats` and drops files no longer listed. Nil
    /// paths, a directory that could not be listed, keeps every file.
    mutating func beginRead(paths: [String]?) {
        stats = Stats()
        guard let paths else { return }
        let listed = Set(paths)
        entries = entries.filter { listed.contains($0.key) }
        sidecars = sidecars.filter { listed.contains($0.key) }
    }

    /// The `.meta.json` sidecar's descriptor, decoded again only when the
    /// sidecar changed.
    mutating func descriptor(forSubagentPath path: String) -> SubagentDescriptor? {
        guard let fingerprint = FileFingerprint(path: SubagentMetadataReader.metadataPath(forSubagentPath: path)) else {
            sidecars[path] = nil
            return nil
        }
        if let cached = sidecars[path], cached.fingerprint == fingerprint { return cached.descriptor }
        let descriptor = SubagentMetadataReader.read(forSubagentPath: path)
        sidecars[path] = Sidecar(fingerprint: fingerprint, descriptor: descriptor)
        return descriptor
    }

    /// The Linear evidence in the transcript last returned for `path`,
    /// scanned again only when that transcript or `subagent` changed.
    mutating func linearEvidence(atPath path: String, subagent: LinearSubagentRef) -> [LinearEvidence] {
        guard let entry = entries[path] else { return [] }
        if let cached = entry.evidence, cached.subagent == subagent { return cached.value }
        let evidence = LinearActivityScanner.scan(entry.transcript.messages, subagent: subagent)
        entries[path]?.evidence = (subagent, evidence)
        return evidence
    }

    /// Ends a read: only the most recently written files within
    /// `linesByteBudget` keep their lines.
    mutating func endRead(byteBudget: UInt64 = linesByteBudget) {
        let newestFirst = entries
            .filter { $0.value.lines != nil }
            .sorted { ($0.value.fingerprint.modifiedAt ?? .distantPast) > ($1.value.fingerprint.modifiedAt ?? .distantPast) }
        var kept: UInt64 = 0
        for (path, entry) in newestFirst {
            kept += entry.cursor.consumed
            if kept > byteBudget { entries[path]?.lines = nil }
        }
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
           fingerprint.size >= cached.cursor.consumed,
           let appended = cached.cursor.appendedBytes(atPath: path) {
            stats.appended += 1
            return store(
                path: path,
                fingerprint: fingerprint,
                lines: lines,
                cursor: cached.cursor,
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
            cursor: AppendCursor(),
            newBytes: data,
            keepsLines: keepsLines
        )
    }

    private mutating func store(
        path: String,
        fingerprint: FileFingerprint,
        lines previousLines: [TranscriptEntry],
        cursor previousCursor: AppendCursor,
        newBytes: Data,
        keepsLines: Bool
    ) -> (transcript: Transcript, modifiedAt: Date?) {
        var cursor = previousCursor
        let (complete, unfinished) = cursor.advance(over: newBytes)

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
        entries[path] = Entry(
            fingerprint: fingerprint,
            transcript: transcript,
            lines: keepsLines ? lines : nil,
            cursor: cursor
        )
        return (transcript, fingerprint.modifiedAt)
    }
}
