import Foundation
import Testing

@testable import Plume

/// Every quota tooltip and popover reads a title naming the provider and
/// timeframe, then percent used, the share of the window elapsed, how long
/// ago the reading arrived (once that reading is stale), then the absolute
/// reset time — leaving out whatever the server did not report.
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

    @Test func fullSummaryListsTitleUsageElapsedLastHeardAndReset() {
        let resetsAt = now.addingTimeInterval(3600)
        // Older than the 30-minute stale threshold, so the last-heard line shows.
        let receivedAt = now.addingTimeInterval(-45 * 60)
        let summary = QuotaDescription.summary(
            provider: "Claude", timeframe: "5h", utilization: 0.454, resetsAt: resetsAt,
            windowLength: QuotaWindowLength.fiveHour, receivedAt: receivedAt, now: now
        )
        // 1h left of 5h is 80% elapsed.
        #expect(summary.lines == [
            "Claude 5h quota",
            "45% used",
            "80% of time elapsed",
            lastHeardLine(secondsAgo: 45 * 60),
            "Resets \(QuotaFreshness.absoluteResetLabel(resetsAt: resetsAt, now: now))",
        ])
    }

    @Test func freshReadingOmitsLastHeard() {
        let receivedAt = now.addingTimeInterval(-5 * 60)
        let summary = QuotaDescription.summary(
            provider: "Claude", timeframe: "7d", utilization: 0.81, resetsAt: nil,
            windowLength: QuotaWindowLength.sevenDay, receivedAt: receivedAt, now: now
        )
        #expect(summary.lastHeard == nil)
    }

    @Test func readingExactlyAtTheStaleThresholdStillOmitsLastHeard() {
        let receivedAt = now.addingTimeInterval(-QuotaFreshness.staleAfter)
        let summary = QuotaDescription.summary(
            provider: "Claude", timeframe: "7d", utilization: 0.81, resetsAt: nil,
            windowLength: QuotaWindowLength.sevenDay, receivedAt: receivedAt, now: now
        )
        #expect(summary.lastHeard == nil)
    }

    @Test func missingResetOmitsElapsedAndResetLines() {
        let receivedAt = now.addingTimeInterval(-45 * 60)
        let summary = QuotaDescription.summary(
            provider: "Claude", timeframe: "7d", utilization: 0.81, resetsAt: nil,
            windowLength: QuotaWindowLength.sevenDay, receivedAt: receivedAt, now: now
        )
        #expect(summary.lines == ["Claude 7d quota", "81% used", lastHeardLine(secondsAgo: 45 * 60)])
    }

    @Test func unknownTimeframeAndNoReceivedAt() {
        let summary = QuotaDescription.summary(
            provider: "Codex", timeframe: nil, utilization: 0.1, resetsAt: nil,
            windowLength: nil, receivedAt: nil, now: now
        )
        #expect(summary.text == "Codex quota\n10% used")
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
        let a = QuotaWindowSummary(title: "Claude 5h quota", usagePercent: 3, elapsedPercent: nil, lastHeard: nil, reset: "at 3:45 PM")
        let b = QuotaWindowSummary(title: "Claude 7d quota", usagePercent: 9, elapsedPercent: nil, lastHeard: nil, reset: nil)
        #expect(QuotaDescription.tooltip([a, b]) == "Claude 5h quota\n3% used\nResets at 3:45 PM\nClaude 7d quota\n9% used")
    }
}
