#if DEBUG
import Foundation

/// One frame tick of a `scrollChat` run. Everything but `offset` describes the
/// interval that ends at this tick, so a long interval's cause is in its own
/// `workMs`, `realizations` and `spans`.
nonisolated struct ScrollFrameSample: Codable, Equatable {
    var index: Int
    /// The clip's offset after this tick moved it.
    var offset: Double
    /// Since the previous tick's callback began; nil for the first tick.
    var intervalMs: Double?
    /// The main-thread turn the previous tick began, up to the end of its
    /// Core Animation commit; nil when no turn ended in between.
    var workMs: Double?
    var realizations: Int
    var spans: [SwitchLatencySpan]
}

nonisolated struct FrameTimeSummary: Codable, Equatable {
    var count: Int
    var median: Double
    /// Nearest rank, like `LatencySummary.p90`.
    var p90: Double
    var p99: Double
    var max: Double

    init?(_ samples: [Double]) {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let n = sorted.count
        count = n
        median = n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
        p90 = Self.nearestRank(0.9, in: sorted)
        p99 = Self.nearestRank(0.99, in: sorted)
        max = sorted[n - 1]
    }

    private static func nearestRank(_ quantile: Double, in sorted: [Double]) -> Double {
        sorted[Swift.max(Int((quantile * Double(sorted.count)).rounded(.up)), 1) - 1]
    }
}

nonisolated struct ScrollHitchReport: Codable, Equatable {
    var clock: String
    var periodMs: Double
    /// Frame intervals measured: every tick but the first.
    var frames: Int
    var durationMs: Double
    var startOffset: Double
    var endOffset: Double
    /// Signed, negative upward.
    var distance: Double
    /// The run hit `maxSeconds` before settling at its destination.
    var timedOut: Bool
    var realizations: Int
    var intervalMs: FrameTimeSummary?
    var workMs: FrameTimeSummary?
    var over16: Int
    var over33: Int
    var over50: Int
    var over100: Int
    /// Over every interval longer than 1.5 periods, the time past one period.
    var hitchMs: Double
    var hitchMsPerSecond: Double
    var spans: [SwitchLatencySpan]
    var worstFrames: [ScrollFrameSample]

    init(
        clock: String, periodMs: Double, startOffset: Double, endOffset: Double,
        timedOut: Bool, samples: [ScrollFrameSample], worst: Int
    ) {
        self.clock = clock
        self.periodMs = periodMs
        self.startOffset = startOffset
        self.endOffset = endOffset
        distance = endOffset - startOffset
        self.timedOut = timedOut
        let measured = samples.filter { $0.intervalMs != nil }
        let intervals = measured.compactMap(\.intervalMs)
        frames = intervals.count
        durationMs = intervals.reduce(0, +)
        realizations = measured.reduce(0) { $0 + $1.realizations }
        intervalMs = FrameTimeSummary(intervals)
        workMs = FrameTimeSummary(measured.compactMap(\.workMs))
        over16 = intervals.filter { $0 > 16 }.count
        over33 = intervals.filter { $0 > 33 }.count
        over50 = intervals.filter { $0 > 50 }.count
        over100 = intervals.filter { $0 > 100 }.count
        hitchMs = intervals.filter { $0 > 1.5 * periodMs }.reduce(0) { $0 + ($1 - periodMs) }
        hitchMsPerSecond = durationMs > 0 ? hitchMs / (durationMs / 1000) : 0
        var totals: [String: SwitchLatencySpan] = [:]
        for span in measured.flatMap(\.spans) {
            totals[span.name, default: SwitchLatencySpan(name: span.name)].count += span.count
            totals[span.name]?.ms += span.ms
        }
        spans = totals.values.sorted { $0.ms != $1.ms ? $0.ms > $1.ms : $0.name < $1.name }
        worstFrames = Array(
            measured.sorted { ($0.intervalMs ?? 0) > ($1.intervalMs ?? 0) }.prefix(Swift.max(worst, 0))
        )
    }

    var logLine: String {
        let round = { (value: Double?) in value.map { String(Int($0.rounded())) } ?? "-" }
        return [
            "clock=\(clock)", "frames=\(frames)", "median=\(round(intervalMs?.median))",
            "p99=\(round(intervalMs?.p99))", "max=\(round(intervalMs?.max))",
            "over16=\(over16)", "over33=\(over33)", "hitchMsPerSecond=\(round(hitchMsPerSecond))",
        ].joined(separator: " ")
    }
}
#endif
