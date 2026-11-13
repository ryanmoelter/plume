#if DEBUG
import AppKit
import OSLog

/// Times a task switch from the selection change to the frame that shows the
/// new chat's rows, for `SmokeHarness`'s selection cycling and the control
/// server's `selectTask`.
///
/// A run-loop observer ordered after Core Animation's commit marks the end of
/// each main-thread turn, so "visible" is the end of the first turn in which
/// the chat list placed realized rows. A switch to a tab with no rows to show
/// ends with its first turn.
@MainActor
enum SwitchLatencyProbe {
    private struct Run {
        var label: String
        var start: CFTimeInterval
        var tabID: UUID?
        var expectsRows: Bool
        var timeout: TimeInterval
        var completion: ((SwitchLatencyMeasurement) -> Void)?
        var turns = 0
        var firstTurnEnd: CFTimeInterval?
        var rowsPlaced: CFTimeInterval?
        var spans: [String: SwitchLatencySpan] = [:]
    }

    private static var run: Run?
    private static var observer: CFRunLoopObserver?

    /// Rows count only when `tabID` places them, when given: the list
    /// controller of the tab being left can lay out in the same turn.
    static func begin(
        _ label: String,
        tabID: UUID? = nil,
        expectsRows: Bool = true,
        timeout: TimeInterval = 2,
        completion: ((SwitchLatencyMeasurement) -> Void)? = nil
    ) {
        if run != nil { finish(at: CACurrentMediaTime(), timedOut: true) }
        run = Run(
            label: label, start: CACurrentMediaTime(), tabID: tabID,
            expectsRows: expectsRows, timeout: timeout, completion: completion
        )
        installObserver()
        // A main thread with nothing to do never ends a turn, so wake it.
        let started = run?.start
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout + 0.05) {
            MainActor.assumeIsolated {
                guard run?.start == started else { return }
                turnEnded()
            }
        }
    }

    static func time<T>(_ name: String, _ body: () -> T) -> T {
        guard run != nil else { return body() }
        let began = CACurrentMediaTime()
        defer {
            let elapsed = (CACurrentMediaTime() - began) * 1000
            run?.spans[name, default: SwitchLatencySpan(name: name)].add(ms: elapsed)
        }
        return body()
    }

    static func note(_ name: String) {
        guard run != nil else { return }
        run?.spans[name, default: SwitchLatencySpan(name: name)].count += 1
    }

    static func noteRowsPlaced(tabID: UUID?) {
        guard let current = run, current.rowsPlaced == nil else { return }
        if let expected = current.tabID, expected != tabID { return }
        run?.rowsPlaced = CACurrentMediaTime()
    }

    private static func installObserver() {
        guard observer == nil else { return }
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, Int.max) { _, _ in
            MainActor.assumeIsolated { turnEnded() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }

    private static func turnEnded() {
        guard var current = run else { return }
        let now = CACurrentMediaTime()
        current.turns += 1
        if current.firstTurnEnd == nil { current.firstTurnEnd = now }
        run = current
        if current.rowsPlaced != nil || !current.expectsRows {
            finish(at: now, timedOut: false)
        } else if now - current.start > current.timeout {
            finish(at: now, timedOut: true)
        }
    }

    private static func finish(at now: CFTimeInterval, timedOut: Bool) {
        guard let current = run else { return }
        run = nil
        let ms = { (t: CFTimeInterval) in (t - current.start) * 1000 }
        let measurement = SwitchLatencyMeasurement(
            label: current.label,
            firstTurnMs: ms(current.firstTurnEnd ?? now),
            rowsPlacedMs: current.rowsPlaced.map(ms),
            visibleMs: ms(now),
            turns: current.turns,
            expectsRows: current.expectsRows,
            timedOut: timedOut,
            spans: current.spans.values.sorted { $0.name < $1.name }
        )
        Log.app.info("switch-latency \(measurement.logLine, privacy: .public)")
        current.completion?(measurement)
    }
}

nonisolated struct SwitchLatencySpan: Codable, Equatable {
    var name: String
    var count = 0
    var ms = 0.0

    mutating func add(ms elapsed: Double) {
        count += 1
        ms += elapsed
    }
}

/// One switch, in milliseconds from the selection change.
nonisolated struct SwitchLatencyMeasurement: Codable, Equatable {
    var label: String
    /// The end of the first main-thread turn after the selection changed.
    var firstTurnMs: Double
    /// When the target tab's chat list first placed rows; nil when it placed none.
    var rowsPlacedMs: Double?
    /// The end of the turn whose commit showed those rows, or of the first
    /// turn when the tab has no rows to show.
    var visibleMs: Double
    var turns: Int
    var expectsRows: Bool
    /// The tab placed no rows within the timeout, or another switch began first.
    var timedOut: Bool
    var spans: [SwitchLatencySpan]

    var logLine: String {
        let round = { (value: Double) in Int(value.rounded()) }
        var parts = [label, "firstTurn=\(round(firstTurnMs))ms"]
        if let rowsPlacedMs { parts.append("rowsPlaced=\(round(rowsPlacedMs))ms") }
        parts.append(timedOut ? "timedOut" : "visible=\(round(visibleMs))ms")
        parts.append("turns=\(turns)")
        parts += spans.map { "\($0.name)=\(round($0.ms))ms/\($0.count)" }
        return parts.joined(separator: " ")
    }
}

nonisolated struct LatencySummary: Codable, Equatable {
    var count: Int
    var median: Double
    /// Nearest rank: the smallest sample at least 90% of samples are at or below.
    var p90: Double
    var min: Double
    var max: Double

    init?(_ samples: [Double]) {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let n = sorted.count
        count = n
        median = n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
        p90 = sorted[Int((0.9 * Double(n)).rounded(.up)) - 1]
        min = sorted[0]
        max = sorted[n - 1]
    }
}

/// Every measured switch into one task, and their summaries. Timed-out
/// samples stay in `samples` but are left out of the summaries.
nonisolated struct SwitchLatencyReport: Codable, Equatable {
    nonisolated struct SpanSummary: Codable, Equatable {
        var name: String
        /// Summarized over the samples that recorded the span at all.
        var ms: LatencySummary
        var medianCount: Double
    }

    var samples: [SwitchLatencyMeasurement]
    var timedOut: Int
    var visibleMs: LatencySummary?
    var firstTurnMs: LatencySummary?
    var rowsPlacedMs: LatencySummary?
    var spans: [SpanSummary]

    init(samples: [SwitchLatencyMeasurement]) {
        self.samples = samples
        let complete = samples.filter { !$0.timedOut }
        timedOut = samples.count - complete.count
        visibleMs = LatencySummary(complete.map(\.visibleMs))
        firstTurnMs = LatencySummary(complete.map(\.firstTurnMs))
        rowsPlacedMs = LatencySummary(complete.compactMap(\.rowsPlacedMs))
        let names = Set(complete.flatMap { $0.spans.map(\.name) }).sorted()
        spans = names.compactMap { name in
            let recorded = complete.compactMap { $0.spans.first { $0.name == name } }
            guard let ms = LatencySummary(recorded.map(\.ms)),
                  let counts = LatencySummary(recorded.map { Double($0.count) })
            else { return nil }
            return SpanSummary(name: name, ms: ms, medianCount: counts.median)
        }
    }
}
#endif
