import Foundation
#if DEBUG
import QuartzCore
#endif

/// The main transcript's parse and its scans, fed the file's bytes as
/// they arrive, so a transcript that only grew decodes only what it gained.
/// Each line is decoded once and shared by all of them.
nonisolated struct TranscriptFold: Sendable {
    struct Snapshot: Sendable {
        let transcript: Transcript
        let backgroundTasks: [BackgroundTaskTracker.Entry]
        let spawnResults: SubagentSpawnResults
        let spawnDescriptors: [String: SubagentDescriptor]
        /// Milliseconds per stage, measured only in a Debug build.
        let timings: Timings
    }

    struct Timings: Sendable {
        var decode = 0.0
        var parse = 0.0
        var backgroundTasks = 0.0
        var spawnResults = 0.0
    }

    private var parser = TranscriptParser.State()
    private var backgroundTasks = BackgroundTaskScanner.State()
    private var spawnResults = SubagentSpawnResults()
    private var spawns = SubagentSpawnScanner.State()
    private(set) var cursor = AppendCursor()

    var consumed: UInt64 { cursor.consumed }

    init() {}

    /// Folds `bytes`, which continue the file from `consumed`. A last line
    /// with no newline yet counts toward the snapshot, as it does for a
    /// whole-file parse, but stays out of the fold.
    mutating func append(_ bytes: Data, now: Date = Date()) -> Snapshot {
        var timings = Timings()
        let decoder = JSONDecoder()
        let (complete, unfinished) = cursor.advance(over: bytes)
        for line in complete.split(separator: Self.newline) {
            guard let entry = Self.decode(line, decoder, &timings) else { continue }
            consume(entry, now: now, timings: &timings)
        }

        // Usually half a line, which decodes as nothing, so the copy is never
        // written to and never pays for duplicating the fold's state.
        var withUnfinished = self
        if let entry = Self.decode(unfinished, decoder, &timings) {
            withUnfinished.consume(entry, now: now, timings: &timings)
        }
        let transcript = Self.measure(&timings.parse) { withUnfinished.parser.finished() }
        let backgroundTasks = Self.measure(&timings.backgroundTasks) { withUnfinished.backgroundTasks.inFlight }
        return Snapshot(
            transcript: transcript,
            backgroundTasks: backgroundTasks,
            spawnResults: withUnfinished.spawnResults,
            spawnDescriptors: withUnfinished.spawns.descriptors,
            timings: timings
        )
    }

    private static let newline = UInt8(ascii: "\n")

    private static func decode(_ line: Data, _ decoder: JSONDecoder, _ timings: inout Timings) -> TranscriptEntry? {
        guard !line.isEmpty else { return nil }
        return measure(&timings.decode) { try? decoder.decode(TranscriptEntry.self, from: Data(line)) }
    }

    private mutating func consume(_ entry: TranscriptEntry, now: Date, timings: inout Timings) {
        Self.measure(&timings.parse) { parser.consume(entry) }
        Self.measure(&timings.backgroundTasks) { backgroundTasks.consume(entry, now: now) }
        Self.measure(&timings.spawnResults) {
            spawnResults.consume(entry)
            spawns.consume(entry)
        }
    }

    private static func measure<T>(_ slot: inout Double, _ body: () -> T) -> T {
        #if DEBUG
        let began = CACurrentMediaTime()
        defer { slot += (CACurrentMediaTime() - began) * 1000 }
        #endif
        return body()
    }
}
