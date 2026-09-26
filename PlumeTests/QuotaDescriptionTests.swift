import Foundation
import Testing

@testable import Plume

/// Every quota tooltip and popover reads: timeframe and percent used, the
/// share of the window elapsed, then the absolute reset time — leaving out
/// whatever the server did not report.
@MainActor
struct QuotaDescriptionTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func fullSummaryListsUsageElapsedAndReset() {
        let resetsAt = now.addingTimeInterval(3600)
        let summary = QuotaDescription.summary(
            timeframe: "5h", utilization: 0.454, resetsAt: resetsAt,
            windowLength: QuotaWindowLength.fiveHour, isStale: false, now: now
        )
        // 1h left of 5h is 80% elapsed.
        #expect(summary.usage == "45% of 5h quota used, 80% of time elapsed")
        #expect(summary.reset == "Resetting at \(QuotaFreshness.absoluteResetLabel(resetsAt: resetsAt, now: now))")
        #expect(summary.lines.count == 2)
    }

    @Test func missingResetOmitsElapsedAndResetLines() {
        let summary = QuotaDescription.summary(
            timeframe: "7d", utilization: 0.81, resetsAt: nil,
            windowLength: QuotaWindowLength.sevenDay, isStale: false, now: now
        )
        #expect(summary.lines == ["81% of 7d quota used"])
    }

    @Test func unknownTimeframeAndStaleReading() {
        let summary = QuotaDescription.summary(
            timeframe: nil, utilization: 0.1, resetsAt: nil,
            windowLength: nil, isStale: true, now: now
        )
        #expect(summary.text == "10% of quota used (last heard over 30 minutes ago)")
    }

    @Test func timeframeUsesTheLargestWholeUnit() {
        #expect(QuotaDescription.timeframe(minutes: 300) == "5h")
        #expect(QuotaDescription.timeframe(minutes: 10_080) == "7d")
        #expect(QuotaDescription.timeframe(minutes: 90) == "90m")
    }

    @Test func codexTimeframeComesFromDurationNotSlot() {
        let weeklyInPrimary = CodexQuotaWindow(bucketID: "codex", bucketName: nil, slot: .primary, usedPercent: 45, durationMinutes: 10_080, resetsAt: nil)
        let unknown = CodexQuotaWindow(bucketID: "codex", bucketName: nil, slot: .secondary, usedPercent: 5, durationMinutes: nil, resetsAt: nil)
        let otherBucket = CodexQuotaWindow(bucketID: "spark", bucketName: nil, slot: .primary, usedPercent: 5, durationMinutes: 300, resetsAt: nil)
        #expect(weeklyInPrimary.timeframe == "7d")
        #expect(unknown.timeframe == nil)
        #expect(otherBucket.timeframe == "spark 5h")
    }

    @Test func tooltipJoinsWindowsLineByLine() {
        let a = QuotaWindowSummary(usage: "a", reset: "r")
        let b = QuotaWindowSummary(usage: "b", reset: nil)
        #expect(QuotaDescription.tooltip([a, b]) == "a\nr\nb")
    }
}
