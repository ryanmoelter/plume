import Foundation
#if DEBUG
import QuartzCore
#endif

/// The main transcript's parse and its two scans, fed the file's bytes as
/// they arrive, so a transcript that only grew decodes only what it gained.
/// Each line is decoded once and shared by all three.
nonisolated struct TranscriptFold: Sendable {
    struct Snapshot: Sendable {
        let transcript: Transcript
        let backgroundTasks: [BackgroundTaskTracker.Entry]
        let spawnResults: SubagentSpawnResults
        /// Milliseconds per stage, measured only in a Debug build.
        let timings: Timings
    }

    struct Timings: Sendable {
        var decode = 0.0
        var parse = 0.0
        var backgroundTasks = 0.0
        var spawnResults = 0.0
    }

    static let seamLength = 64

    private var parser = TranscriptParser.State()
    private var backgroundTasks = BackgroundTaskScanner.State()
    private var spawnResults = SubagentSpawnResults()
    /// Bytes through the last newline folded. Anything after it is a line
    /// still being written, read again whole on the next append.
    private(set) var consumed: UInt64 = 0
    /// The bytes just before `consumed`, compared on the next read to tell
    /// an append from a rewrite of the same file.
    private(set) var seam = Data()

    init() {}

    /// Folds `bytes`, which continue the file from `consumed`. A last line
    /// with no newline yet counts toward the snapshot, as it does for a
    /// whole-file parse, but stays out of the fold.
    mutating func append(_ bytes: Data, now: Date = Date()) -> Snapshot {
        var timings = Timings()
        let completeLength = bytes.lastIndex(of: Self.newline).map { $0 + 1 - bytes.startIndex } ?? 0
        let complete = bytes.prefix(completeLength)
        let unfinished = bytes.dropFirst(completeLength)

        fold(complete, now: now, timings: &timings)
        consumed += UInt64(completeLength)
        seam = complete.count >= Self.seamLength
            ? Data(complete.suffix(Self.seamLength))
            : Data((seam + complete).suffix(Self.seamLength))

        var withUnfinished = self
        if !unfinished.isEmpty {
            withUnfinished.fold(unfinished, now: now, timings: &timings)
        }
        let transcript = Self.measure(&timings.parse) { withUnfinished.parser.finished() }
        let backgroundTasks = Self.measure(&timings.backgroundTasks) { withUnfinished.backgroundTasks.inFlight }
        return Snapshot(
            transcript: transcript,
            backgroundTasks: backgroundTasks,
            spawnResults: withUnfinished.spawnResults,
            timings: timings
        )
    }

    private static let newline = UInt8(ascii: "\n")

    private mutating func fold(_ bytes: Data, now: Date, timings: inout Timings) {
        let decoder = JSONDecoder()
        for line in bytes.split(separator: Self.newline) {
            guard let entry = Self.measure(&timings.decode, {
                try? decoder.decode(TranscriptEntry.self, from: Data(line))
            }) else { continue }
            Self.measure(&timings.parse) { parser.consume(entry) }
            Self.measure(&timings.backgroundTasks) { backgroundTasks.consume(entry, now: now) }
            Self.measure(&timings.spawnResults) { spawnResults.consume(entry) }
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
