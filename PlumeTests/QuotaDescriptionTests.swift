import Foundation
import Testing

@testable import Plume

/// Every quota tooltip and popover reads one line each: timeframe and percent
/// used, the share of the window elapsed, how long ago the reading arrived,
/// then the absolute reset time — leaving out whatever the server did not
/// report.
@MainActor
struct QuotaDescriptionTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    /// Mirrors `QuotaDescription`'s own formatting, so the expectation tracks
    /// whatever the current locale renders rather than a hardcoded string.
    private func lastHeardLine(secondsAgo: TimeInterval) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        let relative = formatter.localizedString(for: now.addingTimeInterval(-secondsAgo), relativeTo: now)
        return "(last heard \(relative))"
    }

    @Test func fullSummaryListsUsageElapsedLastHeardAndReset() {
        let resetsAt = now.addingTimeInterval(3600)
        let receivedAt = now.addingTimeInterval(-5 * 60)
        let summary = QuotaDescription.summary(
            timeframe: "5h", utilization: 0.454, resetsAt: resetsAt,
            windowLength: QuotaWindowLength.fiveHour, receivedAt: receivedAt, now: now
        )
        // 1h left of 5h is 80% elapsed.
        #expect(summary.lines == [
            "45% of 5h quota used",
            "80% of time elapsed",
            lastHeardLine(secondsAgo: 5 * 60),
            "Resets at \(QuotaFreshness.absoluteResetLabel(resetsAt: resetsAt, now: now))",
        ])
    }

    @Test func missingResetOmitsElapsedAndResetLines() {
        let receivedAt = now.addingTimeInterval(-5 * 60)
        let summary = QuotaDescription.summary(
            timeframe: "7d", utilization: 0.81, resetsAt: nil,
            windowLength: QuotaWindowLength.sevenDay, receivedAt: receivedAt, now: now
        )
        #expect(summary.lines == ["81% of 7d quota used", lastHeardLine(secondsAgo: 5 * 60)])
    }

    @Test func unknownTimeframeAndNoReceivedAt() {
        let summary = QuotaDescription.summary(
            timeframe: nil, utilization: 0.1, resetsAt: nil,
            windowLength: nil, receivedAt: nil, now: now
        )
        #expect(summary.text == "10% of quota used")
    }

    @Test func lastHeardReadsJustNowUnderAMinute() {
        let summary = QuotaDescription.summary(
            timeframe: "7d", utilization: 0.1, resetsAt: nil,
            windowLength: nil, receivedAt: now.addingTimeInterval(-30), now: now
        )
        #expect(summary.lastHeard == "(last heard just now)")
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
        let a = QuotaWindowSummary(usage: "a", elapsed: nil, lastHeard: nil, reset: "r")
        let b = QuotaWindowSummary(usage: "b", elapsed: nil, lastHeard: nil, reset: nil)
        #expect(QuotaDescription.tooltip([a, b]) == "a\nr\nb")
    }
}
