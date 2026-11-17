import Foundation
import Testing

@testable import Plume

/// `scrollChat`'s report: nearest-rank percentiles over frame intervals, the
/// first tick left out because it has no interval, strict over-N counts, hitch
/// time past one period on intervals longer than 1.5 periods, each interval
/// judged against its own clock's period, span totals sorted by time, and the
/// parameters' `to`/`by` validation.
struct ScrollHitchReportTests {
    @Test func percentilesAreNearestRank() throws {
        let hundred = try #require(FrameTimeSummary((1...100).map(Double.init)))
        #expect(hundred.p90 == 90)
        #expect(hundred.p99 == 99)
        #expect(hundred.max == 100)
        #expect(hundred.median == 50.5)

        let ten = try #require(FrameTimeSummary((1...10).map(Double.init)))
        // ceil(0.99 × 10) = 10th smallest.
        #expect(ten.p99 == 10)
        #expect(ten.p90 == 9)
    }

    @Test func emptySummaryIsNil() {
        #expect(FrameTimeSummary([]) == nil)
    }

    @Test func firstTickIsExcluded() {
        let report = report([nil, 8, 8], realizations: [5, 1, 0])
        #expect(report.frames == 2)
        #expect(report.durationMs == 16)
        #expect(report.intervalMs?.count == 2)
        #expect(report.realizations == 1)
        #expect(report.worstFrames.allSatisfy { $0.index != 0 })
    }

    @Test func overCountsAreStrict() {
        let report = report([nil, 20, 21, 40, 41, 50, 51, 100, 101], periodMs: 10)
        #expect(report.overTwoPeriods == 7)
        #expect(report.overFourPeriods == 5)
        #expect(report.over50 == 3)
        #expect(report.over100 == 1)
    }

    @Test func eachIntervalIsJudgedAgainstItsOwnPeriod() {
        // 20 ms is a hitch of 12 against an 8 ms period, and none against 16.
        let samples = [
            sample(0, nil, periodMs: 8), sample(1, 20, periodMs: 8),
            sample(2, 20, periodMs: 16), sample(3, 16, periodMs: 16),
        ]
        let report = ScrollHitchReport(
            clock: "mixed", startOffset: 0, endOffset: 0, distance: 0, timedOut: false, samples: samples, worst: 0
        )
        #expect(report.hitchMs == 12)
        #expect(report.overTwoPeriods == 1)
        #expect(report.periodMs == 16)
    }

    @Test func hitchTimeCountsOnlyIntervalsPastOneAndAHalfPeriods() {
        // With a 10 ms period, 15 is not a hitch, 16 adds 6 and 40 adds 30.
        let report = report([nil, 10, 15, 16, 40], periodMs: 10)
        #expect(report.hitchMs == 36)
        #expect(report.durationMs == 81)
        #expect(abs(report.hitchMsPerSecond - 36 / 0.081) < 0.001)
    }

    @Test func spansTotalAndWorstFramesSort() {
        let samples = [
            sample(0, nil, spans: [SwitchLatencySpan(name: "layoutPass", count: 1, ms: 99)]),
            sample(1, 8, spans: [SwitchLatencySpan(name: "layoutPass", count: 1, ms: 2)]),
            sample(2, 40, spans: [
                SwitchLatencySpan(name: "layoutPass", count: 2, ms: 3),
                SwitchLatencySpan(name: "realizeWindow", count: 1, ms: 30),
            ]),
            sample(3, 20, spans: []),
        ]
        let report = ScrollHitchReport(
            clock: "displayLink", startOffset: 500, endOffset: 0, distance: -480, timedOut: false,
            samples: samples, worst: 2
        )
        #expect(report.spans.map(\.name) == ["realizeWindow", "layoutPass"])
        #expect(report.spans.last == SwitchLatencySpan(name: "layoutPass", count: 3, ms: 5))
        #expect(report.worstFrames.map(\.index) == [2, 3])
        #expect(report.distance == -480)
    }

    @Test func emptyRunReportsZeroes() {
        let report = report([])
        #expect(report.frames == 0)
        #expect(report.intervalMs == nil)
        #expect(report.workMs == nil)
        #expect(report.hitchMsPerSecond == 0)
        #expect(report.worstFrames.isEmpty)
    }

    @Test func destinationTakesToOrBy() throws {
        #expect(try ScrollChatParams().destination() == .top)
        #expect(try ScrollChatParams(to: "bottom").destination() == .bottom)
        #expect(try ScrollChatParams(by: -300).destination() == .by(-300))
        #expect(throws: ControlError.self) { try ScrollChatParams(to: "top", by: 10).destination() }
        #expect(throws: ControlError.self) { try ScrollChatParams(to: "middle").destination() }
    }

    @Test func clockTakesAutoOrTimer() throws {
        #expect(try ScrollChatParams().clockChoice() == .auto)
        #expect(try ScrollChatParams(clock: "timer").clockChoice() == .timer)
        #expect(throws: ControlError.self) { try ScrollChatParams(clock: "vsync").clockChoice() }
    }

    private func report(_ intervals: [Double?], periodMs: Double = 1000.0 / 120, realizations: [Int]? = nil) -> ScrollHitchReport {
        let samples = intervals.enumerated().map { index, interval in
            var made = sample(index, interval, periodMs: periodMs)
            made.realizations = realizations?[index] ?? 0
            return made
        }
        return ScrollHitchReport(
            clock: "timer", startOffset: 0, endOffset: 0, distance: 0, timedOut: false,
            samples: samples, worst: 5
        )
    }

    private func sample(
        _ index: Int, _ interval: Double?, periodMs: Double = 8, spans: [SwitchLatencySpan] = []
    ) -> ScrollFrameSample {
        ScrollFrameSample(
            index: index, offset: Double(index), intervalMs: interval, periodMs: periodMs,
            workMs: interval.map { $0 / 2 }, realizations: 0, spans: spans
        )
    }
}
