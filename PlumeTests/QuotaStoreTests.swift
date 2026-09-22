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

    /// The tooltip says when the window resets, so a same-day reset is a bare
    /// time and a later one names its weekday.
    @Test func absoluteLabelNamesTheWeekdayOnlyWhenItIsNotToday() {
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

        // 4 March 2026 is a Wednesday, so a reset 30h later lands on Thursday.
        let thursday = DateFormatter()
        thursday.locale = .current
        thursday.setLocalizedDateFormatFromTemplate("EEEE")
        let expected = thursday.string(from: nextDay)

        #expect(!sameDayLabel.contains(expected))
        #expect(nextDayLabel.contains(expected))
        #expect(!nextDayLabel.contains("/"))
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

/// How far through a quota window the clock is, which the pacing band draws.
/// The stream reports only when a window resets, so the elapsed share comes
/// from the window's own length.
@MainActor
struct QuotaPacingTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    /// An hour left of five means four are gone: 80% through.
    @Test func anHourLeftOfFiveIsEightyPercent() throws {
        let pacing = try #require(QuotaFreshness.pacing(
            resetsAt: now.addingTimeInterval(3600),
            now: now,
            window: QuotaWindowLength.fiveHour
        ))
        #expect(abs(pacing - 0.8) < 0.0001)
    }

    @Test func aFullWindowRemainingIsTheStart() throws {
        let pacing = try #require(QuotaFreshness.pacing(
            resetsAt: now.addingTimeInterval(QuotaWindowLength.fiveHour),
            now: now,
            window: QuotaWindowLength.fiveHour
        ))
        #expect(abs(pacing) < 0.0001)
    }

    /// A reset further out than the window's length would read as negative
    /// elapsed; the band clamps rather than drawing backwards.
    @Test func aResetBeyondTheWindowClampsToTheStart() throws {
        let pacing = try #require(QuotaFreshness.pacing(
            resetsAt: now.addingTimeInterval(QuotaWindowLength.fiveHour * 2),
            now: now,
            window: QuotaWindowLength.fiveHour
        ))
        #expect(pacing == 0)
    }

    /// A reset already past means the window refilled and no message has said
    /// so yet. Drawing a full band would overstate what is known.
    @Test func aPassedResetPacesNothing() {
        #expect(QuotaFreshness.pacing(
            resetsAt: now.addingTimeInterval(-60),
            now: now,
            window: QuotaWindowLength.fiveHour
        ) == nil)
    }

    @Test func noResetTimePacesNothing() {
        #expect(QuotaFreshness.pacing(
            resetsAt: nil,
            now: now,
            window: QuotaWindowLength.fiveHour
        ) == nil)
    }

    @Test func halfOfTheSevenDayWindow() throws {
        let pacing = try #require(QuotaFreshness.pacing(
            resetsAt: now.addingTimeInterval(QuotaWindowLength.sevenDay / 2),
            now: now,
            window: QuotaWindowLength.sevenDay
        ))
        #expect(abs(pacing - 0.5) < 0.0001)
    }
}

/// When the pacing mark is worth drawing at all.
@MainActor
struct PacingMarkTests {
    @Test func aWindowThatJustOpenedDrawsNoMark() {
        #expect(!PacingMark.isWorthDrawing(0))
        #expect(!PacingMark.isWorthDrawing(0.01))
    }

    @Test func pastTheThresholdItDraws() {
        #expect(PacingMark.isWorthDrawing(PacingMark.minimumPacing))
        #expect(PacingMark.isWorthDrawing(0.5))
        #expect(PacingMark.isWorthDrawing(1))
    }
}

/// A focus change re-reads the clock, but only once it has gone unread long
/// enough to be worth a redraw.
@MainActor
struct QuotaFocusRefreshTests {
    @Test func theThresholdSitsBetweenTheTickAndStaleness() {
        // The tick keeps things current under a minute, so the focus refresh
        // exists for gaps longer than that but well short of stale.
        #expect(QuotaFreshness.focusRefreshInterval > QuotaFreshness.tickInterval)
        #expect(QuotaFreshness.focusRefreshInterval < QuotaFreshness.staleAfter)
    }

    /// `record` advances the clock, so a reading that just arrived is not
    /// stale and the bars draw at full strength.
    @Test func aFreshReadingIsNotStale() {
        let store = QuotaStore()
        let now = Date()
        store.record(
            RateLimitInfo(
                fiveHour: .init(utilization: 0.5, resetsAt: now.addingTimeInterval(3600)),
                sevenDay: nil,
                isUsingOverage: false
            ),
            at: now
        )

        let snapshot = store.snapshot
        #expect(snapshot != nil)
        #expect(!QuotaFreshness.isStale(receivedAt: snapshot!.receivedAt, now: store.now))
    }

    /// Ticking the clock past the threshold makes the same reading stale
    /// without a new payload — which is what dims the fill and the text.
    @Test func timePassingAloneTurnsAReadingStale() {
        let received = Date()
        let later = received.addingTimeInterval(QuotaFreshness.staleAfter + 1)

        #expect(QuotaFreshness.isStale(receivedAt: received, now: later))
    }
}
