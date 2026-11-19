import Foundation
import Testing

@testable import Plume

/// `selectTask`'s summaries: nearest-rank p90, a median that averages the
/// middle pair, timed-out switches kept as samples but left out of every
/// summary, and task queries that prefer an id, then an exact title, then a
/// unique substring.
struct SwitchLatencyReportTests {
    @Test func summaryOfOddAndEvenCounts() throws {
        let odd = try #require(LatencySummary([5, 1, 3]))
        #expect(odd.median == 3)
        #expect(odd.p90 == 5)
        #expect(odd.min == 1)
        #expect(odd.max == 5)

        let even = try #require(LatencySummary([4, 1, 3, 2]))
        #expect(even.median == 2.5)
        #expect(even.count == 4)
    }

    @Test func p90IsNearestRank() throws {
        let tens = try #require(LatencySummary((1...10).map(Double.init)))
        #expect(tens.p90 == 9)
        let elevens = try #require(LatencySummary((1...11).map(Double.init)))
        // ceil(0.9 × 11) = 10th smallest.
        #expect(elevens.p90 == 10)
    }

    @Test func emptySummaryIsNil() {
        #expect(LatencySummary([]) == nil)
    }

    @Test func reportSkipsTimedOutSamplesAndSummarizesSpans() throws {
        let samples = [
            measurement(visible: 100, rows: 90, spans: [span("layoutPass", 40, count: 2)]),
            measurement(visible: 300, rows: 280, spans: [span("layoutPass", 60, count: 4), span("realizeMeasure", 10, count: 1)]),
            measurement(visible: 2000, rows: nil, timedOut: true, spans: [span("layoutPass", 999, count: 9)]),
        ]
        let report = SwitchLatencyReport(samples: samples)

        #expect(report.samples.count == 3)
        #expect(report.timedOut == 1)
        #expect(report.visibleMs?.median == 200)
        #expect(report.rowsPlacedMs?.max == 280)
        #expect(report.spans.map(\.name) == ["layoutPass", "realizeMeasure"])
        let layout = try #require(report.spans.first)
        #expect(layout.ms.median == 50)
        #expect(layout.medianCount == 3)
        #expect(report.spans.last?.ms.count == 1)
    }

    @Test func taskQueryPrefersIDThenExactTitleThenSubstring() throws {
        let a = UUID(), b = UUID(), c = UUID()
        let tasks = [(id: a, title: "Long chat"), (id: b, title: "Long chat 2"), (id: c, title: "Tiny")]
        #expect(try TaskQuery.match(b.uuidString, in: tasks) == b)
        #expect(try TaskQuery.match("long CHAT", in: tasks) == a)
        #expect(try TaskQuery.match("tin", in: tasks) == c)
        #expect(throws: ControlError.self) { try TaskQuery.match("long", in: tasks) }
        #expect(throws: ControlError.self) { try TaskQuery.match("missing", in: tasks) }
    }

    private func span(_ name: String, _ ms: Double, count: Int) -> SwitchLatencySpan {
        SwitchLatencySpan(name: name, count: count, ms: ms)
    }

    private func measurement(
        visible: Double, rows: Double?, timedOut: Bool = false, spans: [SwitchLatencySpan]
    ) -> SwitchLatencyMeasurement {
        SwitchLatencyMeasurement(
            label: "t", firstTurnMs: 10, rowsPlacedMs: rows, visibleMs: visible, turns: 2,
            expectsRows: true, timedOut: timedOut, spans: spans
        )
    }
}
