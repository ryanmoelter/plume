import Foundation
import Testing
@testable import Plume

/// The Fable window and usage-credit spend (PLUME-240): read from the stream
/// and the usage endpoint, merged into `QuotaStore` with the newer Fable
/// reading winning, and shown in the sidebar only once they apply.
@MainActor
struct ClaudeUsageTests {
    private let start = Date(timeIntervalSince1970: 1_795_000_000)

    // Captured from Claude Code 2.1.328 on a Fable turn.
    private let fableLine = #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1795073400,"rateLimitType":"five_hour","overageStatus":"allowed","overageResetsAt":1796083200,"isUsingOverage":false,"unifiedWindows":{"five_hour":{"utilization":0.08,"resetsAt":1795073400,"status":"allowed"},"seven_day":{"utilization":0.52,"resetsAt":1795316400,"status":"allowed"},"seven_day_overage_included":{"utilization":0.2,"resetsAt":1795316400,"status":"allowed"}}},"uuid":"307deb04-3f45-405c-ae4c-4b06dd4df03f","session_id":"08beb4fe-1c0f-4f0e-b1f9-ac837a13860d"}"#

    private func window(_ utilization: Double) -> RateLimitInfo.Window {
        .init(utilization: utilization, resetsAt: nil)
    }

    private func streamInfo(fable: Double?) -> RateLimitInfo {
        RateLimitInfo(fiveHour: window(0.1), sevenDay: window(0.5), isUsingOverage: false, fable: fable.map { window($0) })
    }

    // MARK: Stream

    @Test func decoderReadsTheFableWindow() throws {
        guard case .rateLimit(let info) = StreamJSONDecoder.decode(line: fableLine) else {
            Issue.record("not a rate limit")
            return
        }
        let fable = try #require(info.fable)
        #expect(fable.utilization == 0.2)
        #expect(fable.resetsAt == Date(timeIntervalSince1970: 1_795_316_400))
        #expect(info.sevenDay?.utilization == 0.52)
    }

    @Test func aTurnWithoutFableKeepsTheKnownFableReading() {
        let store = QuotaStore()
        store.record(streamInfo(fable: 0.2), at: start)
        store.record(streamInfo(fable: nil), at: start.addingTimeInterval(60))

        #expect(store.snapshot?.rateLimit.fable?.utilization == 0.2)
        #expect(store.snapshot?.fableReceivedAt == start)
        #expect(store.snapshot?.receivedAt == start.addingTimeInterval(60))
    }

    // MARK: Endpoint

    @Test func parsesTheCurrentEndpointShape() throws {
        let body = #"""
        {"five_hour":{"utilization":8.0,"resets_at":"2026-11-18T23:30:00.123+00:00"},
         "seven_day":{"utilization":52.0,"resets_at":"2026-11-22T02:59:59+00:00"},
         "extra_usage":{"is_enabled":true,"monthly_limit":5000,"used_credits":1240.0,"utilization":24.8,"currency":"USD"},
         "limits":[
           {"kind":"session","group":"session","percent":8,"resets_at":null,"severity":"normal","is_active":true},
           {"kind":"weekly_scoped","group":"weekly","percent":21,"resets_at":"2026-11-22T02:59:59Z",
            "scope":{"model":{"display_name":"Fable 5"}},"severity":"normal","is_active":false}
         ]}
        """#
        let reading = try #require(ClaudeUsageParser.parse(Data(body.utf8)))

        #expect(reading.fiveHour?.utilization == 0.08)
        #expect(reading.fiveHour?.resetsAt != nil)
        #expect(reading.sevenDay?.utilization == 0.52)
        #expect(reading.fable?.utilization == 0.21)
        #expect(reading.fable?.resetsAt == ISO8601DateFormatter().date(from: "2026-11-22T02:59:59Z"))
        #expect(reading.credit == UsageCredit(usedCents: 1240, limitCents: 5000, isEnabled: true, currency: "USD"))
        #expect(reading.credit?.remainingCents == 3760)
    }

    @Test func parsesTheSpendForm() throws {
        let body = #"{"spend":{"used":1240,"limit":5000,"balance":3000}}"#
        let reading = try #require(ClaudeUsageParser.parse(Data(body.utf8)))

        #expect(reading.credit == UsageCredit(usedCents: 1240, limitCents: 5000, balanceCents: 3000))
        #expect(reading.credit?.remainingCents == 3000)
    }

    @Test func missingFieldsReadAsAbsent() throws {
        let empty = try #require(ClaudeUsageParser.parse(Data("{}".utf8)))
        #expect(empty == ClaudeUsageReading())

        let partial = try #require(ClaudeUsageParser.parse(Data(#"""
        {"extra_usage":{"is_enabled":false,"monthly_limit":null,"used_credits":null},
         "limits":[{"kind":"weekly_scoped","scope":{"model":null}}]}
        """#.utf8)))
        #expect(partial.fable == nil)
        #expect(partial.credit == UsageCredit(isEnabled: false))
        #expect(partial.credit?.remainingCents == nil)

        #expect(ClaudeUsageParser.parse(Data("not json".utf8)) == nil)
    }

    @Test func credentialsReadTheAccessTokenAndItsExpiry() {
        let json = #"{"claudeAiOauth":{"accessToken":"tok","refreshToken":"r","expiresAt":1795000000000}}"#
        #expect(ClaudeCredentials.parse(Data(json.utf8)) == .token("tok", expiresAt: start))
        #expect(ClaudeCredentials.parse(Data(#"{"other":{}}"#.utf8)) == nil)
    }

    @Test func expiredTokenSkipsTheRequest() async {
        let client = ClaudeUsageClient(readCredentials: { .token("tok", expiresAt: Date(timeIntervalSince1970: 0)) })
        #expect(await client.fetch() == .unauthorized)
    }

    @Test func retryAfterReadsSecondsAndDates() {
        #expect(ClaudeUsageClient.retryAfter("120", now: start) == 120)
        #expect(ClaudeUsageClient.retryAfter(nil, now: start) == nil)
        let date = "Tue, 17 Nov 2026 06:10:00 GMT"
        let expected = DateComponents(
            calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(identifier: "GMT"),
            year: 2026, month: 11, day: 17, hour: 6, minute: 10
        ).date!
        #expect(ClaudeUsageClient.retryAfter(date, now: expected.addingTimeInterval(-90)) == 90)
    }

    // MARK: Store

    @Test func endpointRecordsCreditAndFableBeforeAnyTurn() {
        let store = QuotaStore()
        let credit = UsageCredit(usedCents: 100, limitCents: 500)
        store.record(ClaudeUsageReading(fable: window(0.3), credit: credit), at: start)

        #expect(store.snapshot?.rateLimit.fable?.utilization == 0.3)
        #expect(store.snapshot?.credit == credit)
        #expect(store.snapshot?.rateLimit.fiveHour == nil)
    }

    @Test func theNewerFableReadingWins() {
        let store = QuotaStore()
        store.record(streamInfo(fable: 0.4), at: start)
        store.record(ClaudeUsageReading(fable: window(0.3)), at: start.addingTimeInterval(-60))
        #expect(store.snapshot?.rateLimit.fable?.utilization == 0.4)

        store.record(ClaudeUsageReading(fable: window(0.5)), at: start.addingTimeInterval(60))
        #expect(store.snapshot?.rateLimit.fable?.utilization == 0.5)

        store.record(streamInfo(fable: nil), at: start.addingTimeInterval(120))
        #expect(store.snapshot?.rateLimit.fable?.utilization == 0.5)
        #expect(store.snapshot?.credit == nil)
    }

    @Test func aTurnKeepsTheCreditReading() {
        let store = QuotaStore()
        let credit = UsageCredit(usedCents: 100, limitCents: 500)
        store.record(ClaudeUsageReading(credit: credit), at: start)
        store.record(streamInfo(fable: nil), at: start.addingTimeInterval(60))

        #expect(store.snapshot?.credit == credit)
    }

    @Test func snapshotSavedBeforeFableAndCreditStillDecodes() throws {
        let legacy = #"{"rateLimit":{"fiveHour":{"utilization":0.4},"isUsingOverage":false},"receivedAt":0}"#
        let snapshot = try JSONDecoder().decode(QuotaSnapshot.self, from: Data(legacy.utf8))

        #expect(snapshot.rateLimit.fiveHour?.utilization == 0.4)
        #expect(snapshot.rateLimit.fable == nil)
        #expect(snapshot.credit == nil)
        #expect(snapshot.fableReceivedAt == nil)
    }

    @Test func snapshotRoundTripsFableAndCredit() throws {
        let snapshot = QuotaSnapshot(
            rateLimit: streamInfo(fable: 0.2), receivedAt: start,
            fableReceivedAt: start, credit: UsageCredit(usedCents: 1, limitCents: 2)
        )
        let decoded = try JSONDecoder().decode(QuotaSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded == snapshot)
    }

    @Test func fableWindowPastItsResetZeroesOnRestore() {
        let snapshot = QuotaSnapshot(
            rateLimit: RateLimitInfo(
                fiveHour: nil, sevenDay: nil, isUsingOverage: false,
                fable: .init(utilization: 0.6, resetsAt: start.addingTimeInterval(3600))
            ),
            receivedAt: start,
            fableReceivedAt: start
        )

        #expect(snapshot.restored(now: start.addingTimeInterval(60)) == snapshot)
        #expect(snapshot.restored(now: start.addingTimeInterval(7200)).rateLimit.fable == .init(utilization: 0, resetsAt: nil))
    }

    @Test func fableWithoutResetExpiresAWeekAfterItWasHeard() {
        let snapshot = QuotaSnapshot(
            rateLimit: RateLimitInfo(fiveHour: nil, sevenDay: nil, isUsingOverage: false, fable: window(0.6)),
            receivedAt: start,
            fableReceivedAt: start.addingTimeInterval(86400)
        )
        let weekAfterReceived = start.addingTimeInterval(QuotaWindowLength.sevenDay)

        #expect(snapshot.restored(now: weekAfterReceived).rateLimit.fable?.utilization == 0.6)
        #expect(snapshot.restored(now: weekAfterReceived.addingTimeInterval(86400)).rateLimit.fable?.utilization == 0)
    }

    // MARK: Sidebar

    @Test func extrasShowOnlyOnceTheyApply() {
        let none = QuotaSnapshot.empty(at: start)
        #expect(!SidebarQuotaExtras(snapshot: none, alwaysShows: false).showsAny)
        let forced = SidebarQuotaExtras(snapshot: nil, alwaysShows: true)
        #expect(forced.showsFable && forced.showsCredit)

        let idleFable = none.with(fable: window(0), receivedAt: start)
        #expect(!SidebarQuotaExtras(snapshot: idleFable, alwaysShows: false).showsFable)
        let usedFable = none.with(fable: window(0.01), receivedAt: start)
        #expect(SidebarQuotaExtras(snapshot: usedFable, alwaysShows: false).showsFable)

        var credit = none
        credit.credit = UsageCredit(usedCents: 0, limitCents: 5000)
        #expect(!SidebarQuotaExtras(snapshot: credit, alwaysShows: false).showsCredit)
        credit.credit = UsageCredit(usedCents: 1240, limitCents: nil)
        #expect(!SidebarQuotaExtras(snapshot: credit, alwaysShows: false).showsCredit)
        credit.credit = UsageCredit(usedCents: 1240, limitCents: 5000)
        #expect(SidebarQuotaExtras(snapshot: credit, alwaysShows: false).showsCredit)

        var overage = QuotaSnapshot(
            rateLimit: RateLimitInfo(fiveHour: window(1), sevenDay: nil, isUsingOverage: true),
            receivedAt: start
        )
        #expect(!SidebarQuotaExtras(snapshot: overage, alwaysShows: false).showsCredit)
        overage.credit = UsageCredit(usedCents: 0, limitCents: nil)
        #expect(SidebarQuotaExtras(snapshot: overage, alwaysShows: false).showsCredit)
    }

    @Test func creditFormatsAsCurrency() {
        let locale = Locale(identifier: "en_US")
        #expect(UsageCreditFormat.amount(cents: 1240, currency: "USD", locale: locale) == "$12.40")
        #expect(UsageCreditFormat.amount(cents: 1240, currency: nil, locale: locale) == "$12.40")
        #expect(
            UsageCreditFormat.tooltip(UsageCredit(usedCents: 1240, limitCents: 5000), locale: locale)
                == "Usage credits: $12.40 used this month\nMonthly limit: $50.00\n$37.60 left"
        )
    }

    // MARK: Schedule

    @Test func pollsEveryTwentyMinutesNormally() {
        #expect(ClaudeUsagePollSchedule.delay(after: .success, consecutiveFailures: 0, isOverLimit: false) == 20 * 60)
        #expect(ClaudeUsagePollSchedule.delay(after: .skipped, consecutiveFailures: 0, isOverLimit: false) == 20 * 60)
    }

    @Test func pollsEveryFiveMinutesWhileOverALimit() {
        #expect(ClaudeUsagePollSchedule.delay(after: .success, consecutiveFailures: 0, isOverLimit: true) == 5 * 60)

        let over = QuotaSnapshot(rateLimit: RateLimitInfo(fiveHour: window(1), sevenDay: window(0.5), isUsingOverage: false), receivedAt: start)
        let under = QuotaSnapshot(rateLimit: RateLimitInfo(fiveHour: window(0.99), sevenDay: window(0.5), isUsingOverage: false), receivedAt: start)
        let overage = QuotaSnapshot(rateLimit: RateLimitInfo(fiveHour: nil, sevenDay: nil, isUsingOverage: true), receivedAt: start)
        #expect(ClaudeUsagePollSchedule.isOverLimit(over))
        #expect(!ClaudeUsagePollSchedule.isOverLimit(under))
        #expect(ClaudeUsagePollSchedule.isOverLimit(overage))
        #expect(!ClaudeUsagePollSchedule.isOverLimit(nil))
    }

    @Test func rateLimitWithoutRetryAfterBacksOffExponentially() {
        let delays = (1...6).map {
            ClaudeUsagePollSchedule.delay(after: .rateLimited(retryAfter: nil), consecutiveFailures: $0, isOverLimit: true)
        }
        #expect(delays == [5, 10, 20, 40, 60, 60].map { $0 * 60.0 })
    }

    @Test func rateLimitHonorsRetryAfter() {
        #expect(ClaudeUsagePollSchedule.delay(after: .rateLimited(retryAfter: 30), consecutiveFailures: 1, isOverLimit: true) == 5 * 60)
        #expect(ClaudeUsagePollSchedule.delay(after: .rateLimited(retryAfter: 900), consecutiveFailures: 1, isOverLimit: true) == 900)
        #expect(ClaudeUsagePollSchedule.delay(after: .rateLimited(retryAfter: 7200), consecutiveFailures: 1, isOverLimit: false) == 7200)
    }

    @Test func failuresBackOffToTheCap() {
        #expect(ClaudeUsagePollSchedule.delay(after: .failed, consecutiveFailures: 1, isOverLimit: false) == 20 * 60)
        #expect(ClaudeUsagePollSchedule.delay(after: .failed, consecutiveFailures: 2, isOverLimit: false) == 40 * 60)
        #expect(ClaudeUsagePollSchedule.delay(after: .failed, consecutiveFailures: 3, isOverLimit: false) == 60 * 60)
        #expect(ClaudeUsagePollSchedule.delay(after: .failed, consecutiveFailures: 50, isOverLimit: false) == 60 * 60)
    }
}
