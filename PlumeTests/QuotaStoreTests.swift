import Foundation
import Testing
@testable import Plume

/// Quota is shared across chats, kept at its last known reading past the reset
/// cutoff, and dimmed once it is old — the three behaviors PLUME-117 adds.
@MainActor
struct QuotaStoreTests {
    private func info(fiveHour: Double?, sevenDay: Double? = nil, resetsAt: Date? = nil) -> RateLimitInfo {
        RateLimitInfo(
            fiveHour: fiveHour.map { .init(utilization: $0, resetsAt: resetsAt) },
            sevenDay: sevenDay.map { .init(utilization: $0, resetsAt: resetsAt) },
            isUsingOverage: false
        )
    }

    @Test func recordsTheLatestReading() {
        let store = QuotaStore()
        let now = Date()
        store.record(info(fiveHour: 0.2), at: now)
        store.record(info(fiveHour: 0.45), at: now.addingTimeInterval(60))

        #expect(store.snapshot?.rateLimit.fiveHour?.utilization == 0.45)
        #expect(store.snapshot?.receivedAt == now.addingTimeInterval(60))
    }

    @Test func keepsTheLastReadingWhenAPayloadCarriesNoWindows() {
        let store = QuotaStore()
        store.record(info(fiveHour: 0.45))
        store.record(info(fiveHour: nil))

        #expect(store.snapshot?.rateLimit.fiveHour?.utilization == 0.45)
    }

    @Test func staleOnlyPastTheThreshold() {
        let received = Date()
        #expect(!QuotaFreshness.isStale(receivedAt: received, now: received.addingTimeInterval(29 * 60)))
        #expect(QuotaFreshness.isStale(receivedAt: received, now: received.addingTimeInterval(31 * 60)))
    }

    @Test func countdownBottomsOutRatherThanZeroingTheQuota() {
        let now = Date()
        let label = QuotaFreshness.resetLabel(
            resetsAt: now.addingTimeInterval(-600),
            now: now,
            fallback: "5h"
        )

        #expect(label == "0m")
    }

    @Test func countdownUnits() {
        let now = Date()
        #expect(QuotaFreshness.resetLabel(resetsAt: now.addingTimeInterval(45 * 60), now: now, fallback: "5h") == "45m")
        #expect(QuotaFreshness.resetLabel(resetsAt: now.addingTimeInterval(2 * 3600), now: now, fallback: "5h") == "2h")
        #expect(QuotaFreshness.resetLabel(resetsAt: now.addingTimeInterval(3 * 86400), now: now, fallback: "7d") == "3d")
        #expect(QuotaFreshness.resetLabel(resetsAt: nil, now: now, fallback: "7d") == "7d")
    }

    /// The tooltip says when the window resets, so a same-day reset needs no
    /// date and a later one does.
    @Test func absoluteLabelAddsADateOnlyWhenItIsNotToday() {
        var components = DateComponents()
        components.year = 2026
        components.month = 3
        components.day = 4
        components.hour = 9
        let calendar = Calendar.current
        let now = calendar.date(from: components)!
        let sameDay = now.addingTimeInterval(4 * 3600)
        let nextDay = now.addingTimeInterval(30 * 3600)

        let sameDayLabel = QuotaFreshness.absoluteResetLabel(resetsAt: sameDay, now: now)
        let nextDayLabel = QuotaFreshness.absoluteResetLabel(resetsAt: nextDay, now: now)

        #expect(!sameDayLabel.contains("/"))
        #expect(nextDayLabel.count > sameDayLabel.count)
    }

    /// The decoder's own quota path is what feeds the store, so a wire line
    /// round-trips into it at the 0–1 scale the stream uses.
    @Test func decodedRateLimitReachesTheStoreUnscaled() throws {
        let line = """
        {"type":"rate_limit_event","rate_limit_info":{"isUsingOverage":false,\
        "unifiedWindows":{"five_hour":{"utilization":0.28,"resetsAt":1788341400},\
        "seven_day":{"utilization":0.1,"resetsAt":1788663600}}}}
        """
        let message = try #require(StreamJSONDecoder.decode(line: line))
        guard case .rateLimit(let info) = message else {
            Issue.record("expected a rate limit message")
            return
        }

        let store = QuotaStore()
        store.record(info)

        #expect(store.snapshot?.rateLimit.fiveHour?.utilization == 0.28)
        #expect(store.snapshot?.rateLimit.sevenDay?.utilization == 0.1)
    }
}
