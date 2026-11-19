import Foundation
import Security
import Synchronization
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

    @Test func aStreamReadingThatArrivesMidRequestBeatsTheReply() {
        let store = QuotaStore()
        let sentAt = start
        store.record(streamInfo(fable: 0.4), at: sentAt.addingTimeInterval(2))
        store.record(ClaudeUsageReading(fable: window(0.3)), at: sentAt)

        #expect(store.snapshot?.rateLimit.fable?.utilization == 0.4)
    }

    @Test func injectedReadingsNeverReachDisk() throws {
        let suite = "ClaudeUsageTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = QuotaStore(defaults: defaults)
        let realCredit = UsageCredit(usedCents: 100, limitCents: 500)
        store.record(ClaudeUsageReading(fable: window(0.1), credit: realCredit), at: start)

        store.inject(fable: window(0.9), credit: UsageCredit(usedCents: 9999, limitCents: 10000), isUsingOverage: true)
        store.record(streamInfo(fable: nil), at: start.addingTimeInterval(60))
        #expect(store.snapshot?.credit?.usedCents == 9999)

        let saved = try #require(defaults.data(forKey: QuotaStore.defaultsKey))
        let persisted = try JSONDecoder().decode(QuotaSnapshot.self, from: saved)
        #expect(persisted.rateLimit.fable?.utilization == 0.1)
        #expect(persisted.credit == realCredit)
        #expect(persisted.rateLimit.isUsingOverage == false)
        #expect(persisted.rateLimit.sevenDay?.utilization == 0.5)
    }

    @Test func creditDimsAfterTwoMissedPolls() {
        let limit = QuotaFreshness.creditStaleAfter
        #expect(limit == 40 * 60)
        #expect(!QuotaFreshness.isCreditStale(receivedAt: start, now: start.addingTimeInterval(limit)))
        #expect(QuotaFreshness.isCreditStale(receivedAt: start, now: start.addingTimeInterval(limit + 1)))
    }

    @Test func endpointRecordsWhenCreditWasHeard() {
        let store = QuotaStore()
        store.record(ClaudeUsageReading(credit: UsageCredit(usedCents: 1, limitCents: 2)), at: start)
        store.record(streamInfo(fable: nil), at: start.addingTimeInterval(60))

        #expect(store.snapshot?.creditReceivedAt == start)
    }

    @Test func creditFromAnEndedBillingPeriodIsDroppedOnRestore() {
        var snapshot = QuotaSnapshot.empty(at: start)
        snapshot.credit = UsageCredit(usedCents: 1, limitCents: 2, resetsAt: start.addingTimeInterval(3600))
        snapshot.creditReceivedAt = start

        #expect(snapshot.restored(now: start.addingTimeInterval(60)).credit != nil)
        let restored = snapshot.restored(now: start.addingTimeInterval(3600))
        #expect(restored.credit == nil)
        #expect(restored.creditReceivedAt == nil)
    }

    @Test func parsesTheBillingPeriodResetFromTheActiveSpendRow() throws {
        let body = #"""
        {"extra_usage":{"is_enabled":true,"monthly_limit":5000,"used_credits":100},
         "limits":[{"kind":"spend","group":"daily","percent":1,"resets_at":"2026-11-19T00:00:00Z","is_active":false},
                   {"kind":"spend","group":"monthly","percent":2,"resets_at":"2026-12-01T00:00:00Z","is_active":true}]}
        """#
        let reading = try #require(ClaudeUsageParser.parse(Data(body.utf8)))
        #expect(reading.credit?.resetsAt == ISO8601DateFormatter().date(from: "2026-12-01T00:00:00Z"))
    }

    @Test func aPollOnlyRowIsAsFreshAsItsNewestReading() {
        var snapshot = QuotaSnapshot.empty(at: start)
        #expect(snapshot.lastHeardAt == start)
        snapshot.credit = UsageCredit(usedCents: 1)
        snapshot.creditReceivedAt = start.addingTimeInterval(3600)
        snapshot = snapshot.with(fable: window(0.1), receivedAt: start.addingTimeInterval(1800))
        #expect(snapshot.lastHeardAt == start.addingTimeInterval(3600))
    }

    @Test func declinedKeychainAccessStopsThePoll() async {
        #expect(ClaudeCredentials.read(status: errSecUserCanceled, data: nil) == .cancelled)
        #expect(ClaudeCredentials.read(status: errSecAuthFailed, data: nil) == .denied)
        #expect(ClaudeCredentials.read(status: errSecItemNotFound, data: nil) == .missing)
        #expect(ClaudeCredentials.read(status: errSecInteractionNotAllowed, data: nil) == .missing)
        let client = ClaudeUsageClient(readCredentials: { .denied })
        #expect(await client.fetch() == .credentialsDenied)
        let cancelling = ClaudeUsageClient(readCredentials: { .cancelled })
        #expect(await cancelling.fetch() == .credentialsCancelled)
    }

    @Test func declinedKeychainAccessTurnsTheSettingOff() async throws {
        let suite = "ClaudeUsageTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, domainName: suite)
        #expect(!settings.readsClaudeUsage)
        settings.readsClaudeUsage = true
        let poller = ClaudeUsagePoller(store: QuotaStore(), settings: settings, fetch: { _ in .credentialsDenied })

        await poller.pollIfDue()
        #expect(!settings.readsClaudeUsage)
        #expect(!AppSettings(defaults: defaults, domainName: suite).readsClaudeUsage)

        poller.setEnabled(true)
        #expect(settings.readsClaudeUsage)
    }

    @Test func keychainServiceFollowsTheConfigDirectory() {
        #expect(ClaudeCredentials.configuredServiceName(environment: [:]) == nil)
        #expect(ClaudeCredentials.configuredServiceName(environment: ["CLAUDE_CONFIG_DIR": ""]) == nil)
        // sha256("/Users/me/.claude-work") begins 1e91dd84.
        let work = "Claude Code-credentials-1e91dd84"
        #expect(ClaudeCredentials.configuredServiceName(environment: ["CLAUDE_CONFIG_DIR": "/Users/me/.claude-work"]) == work)
        #expect(ClaudeCredentials.configuredServiceName(environment: [
            "CLAUDE_CONFIG_DIR": "/elsewhere", "CLAUDE_SECURESTORAGE_CONFIG_DIR": "/Users/me/.claude-work",
        ]) == work)
        #expect(ClaudeCredentials.configuredServiceName(environment: [
            "CLAUDE_CONFIG_DIR": "/elsewhere", "CLAUDE_SECURESTORAGE_CONFIG_DIR": "",
        ]) == "Claude Code-credentials")
        #expect(ClaudeCredentials.accountName(environment: ["USER": "ryan"]) == "ryan")
        #expect(ClaudeCredentials.accountName(environment: ["USER": "r y"]) == "claude-code-user")
    }

    @Test func picksTheKeychainItemThisConfigUses() {
        typealias Item = ClaudeCredentials.Item
        let plain = Item(service: "Claude Code-credentials", account: "ryan", modifiedAt: start)
        let work = Item(service: "Claude Code-credentials-1e91dd84", account: "ryan", modifiedAt: start.addingTimeInterval(60))
        let other = Item(service: "Claude Code-credentials-0badf00d", account: "ryan", modifiedAt: start.addingTimeInterval(120))
        let stranger = Item(service: "Claude Code-credentials", account: "someone", modifiedAt: start.addingTimeInterval(180))
        let staging = Item(service: "Claude Code-local-oauth-credentials", account: "ryan", modifiedAt: start.addingTimeInterval(240))
        let all = [stranger, staging, other, plain, work]

        #expect(ClaudeCredentials.choose(from: all, configuredService: work.service, account: "ryan") == work)
        #expect(ClaudeCredentials.choose(from: all, configuredService: plain.service, account: "ryan") == plain)
        // Nothing configured, or a configured item that doesn't exist: the
        // newest write wins, plain item or not.
        #expect(ClaudeCredentials.choose(from: all, configuredService: nil, account: "ryan") == other)
        #expect(ClaudeCredentials.choose(from: all, configuredService: "Claude Code-credentials-ffffffff", account: "ryan") == other)
        #expect(ClaudeCredentials.choose(from: [plain, work], configuredService: nil, account: "ryan") == work)
        #expect(ClaudeCredentials.choose(from: [stranger, staging], configuredService: nil, account: "ryan") == nil)
    }

    @Test func aHugeAmountParsesAsUnknown() throws {
        let body = #"{"extra_usage":{"is_enabled":true,"monthly_limit":1e20,"used_credits":1240},"five_hour":{"utilization":1e20}}"#
        let reading = try #require(ClaudeUsageParser.parse(Data(body.utf8)))
        #expect(reading.credit?.limitCents == nil)
        #expect(reading.credit?.usedCents == 1240)
        #expect(SidebarQuotaSummary.percent(reading.fiveHour!.utilization) == "999%")
        #expect(SidebarQuotaSummary.percent(.nan) == "—")
        #expect(SidebarQuotaSummary.percent(0.214) == "21%")
    }

    @Test func theLoggedShapeCarriesNoValues() throws {
        let body = #"{"seven_day":{"utilization":21.0,"resets_at":"2026-11-20T00:00:00Z"},"extra_usage":{"used_credits":1240,"currency":"USD","disabled_reason":null},"limits":[{"kind":"spend","is_active":true},{"kind":"weekly_scoped","is_active":false}]}"#
        let root = try JSONDecoder().decode(JSONValue.self, from: Data(body.utf8))
        let shape = ClaudeUsageClient.shape(of: root)

        #expect(shape == "{extra_usage:{currency:string,disabled_reason:null,used_credits:number},limits:[{is_active:bool,kind:string}],seven_day:{resets_at:string,utilization:number}}")
        for value in ["1240", "USD", "spend", "21", "2026"] {
            #expect(!shape.contains(value))
        }
    }

    @Test func overageEndsWhenTheFullWindowRefills() {
        let full = RateLimitInfo.Window(utilization: 1, resetsAt: start.addingTimeInterval(600))
        var snapshot = QuotaSnapshot(
            rateLimit: RateLimitInfo(fiveHour: full, sevenDay: window(0.5), isUsingOverage: true),
            receivedAt: start
        )
        snapshot.credit = UsageCredit(usedCents: 0)

        #expect(snapshot.restored(now: start.addingTimeInterval(300)).rateLimit.isUsingOverage)
        let refilled = snapshot.restored(now: start.addingTimeInterval(600))
        #expect(!refilled.rateLimit.isUsingOverage)
        #expect(!SidebarQuotaExtras(snapshot: refilled, alwaysShows: false, now: start.addingTimeInterval(600)).showsCredit)

        let stillFull = QuotaSnapshot(
            rateLimit: RateLimitInfo(fiveHour: full, sevenDay: window(1), isUsingOverage: true),
            receivedAt: start
        )
        #expect(stillFull.restored(now: start.addingTimeInterval(600)).rateLimit.isUsingOverage)
    }

    @Test func overageStopsShowingCreditOnceTheReadingIsOld() {
        var snapshot = QuotaSnapshot(
            rateLimit: RateLimitInfo(fiveHour: window(1), sevenDay: nil, isUsingOverage: true),
            receivedAt: start
        )
        snapshot.credit = UsageCredit(usedCents: 0)
        let maxAge = ClaudeUsagePollSchedule.overLimitReadingMaxAge

        #expect(SidebarQuotaExtras(snapshot: snapshot, alwaysShows: false, now: start.addingTimeInterval(maxAge)).showsCredit)
        #expect(!SidebarQuotaExtras(snapshot: snapshot, alwaysShows: false, now: start.addingTimeInterval(maxAge + 1)).showsCredit)
    }

    @Test func creditGlyphFillsTowardTheLimitAndOtherwiseShowsWholeUnits() {
        let locale = Locale(identifier: "en_US")
        #expect(UsageCreditFormat.fraction(UsageCredit(usedCents: 1240, limitCents: 5000)) == 0.248)
        #expect(UsageCreditFormat.fraction(UsageCredit(usedCents: 9000, limitCents: 5000)) == 1)
        #expect(UsageCreditFormat.fraction(UsageCredit(usedCents: 1240)) == nil)
        #expect(UsageCreditFormat.fraction(UsageCredit(usedCents: 1240, limitCents: 0)) == nil)
        #expect(UsageCreditFormat.wholeAmount(minorUnits: 1299, currency: "USD", locale: locale) == "$12")
        #expect(UsageCreditFormat.detailLines(UsageCredit(usedCents: 1240, limitCents: 5000), locale: locale)
            == ["$12.40 used this month", "Monthly limit: $50.00", "$37.60 left"])
        #expect(UsageCreditFormat.detailLines(nil) == ["No reading yet"])
    }

    @Test func placeholdersAreNotAReading() {
        #expect(!QuotaSnapshot.empty(at: start).hasReading)
        var credit = QuotaSnapshot.empty(at: start)
        credit.credit = UsageCredit(isEnabled: true)
        #expect(!credit.hasReading)
        credit.credit = UsageCredit(usedCents: 0)
        #expect(credit.hasReading)
        #expect(QuotaSnapshot.empty(at: start).with(fable: window(0), receivedAt: start).hasReading)
    }

#if DEBUG
    @Test func clearedWindowsAreInjectedOnly() throws {
        let suite = "ClaudeUsageTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = QuotaStore(defaults: defaults)
        store.record(streamInfo(fable: nil), at: start)

        store.inject(fable: window(0.3), credit: UsageCredit(usedCents: 1240), isUsingOverage: nil, clearsWindows: true)
        #expect(store.snapshot?.rateLimit.fiveHour == nil)
        #expect(store.snapshot?.rateLimit.sevenDay == nil)
        store.forgetEndpointReadings()

        let saved = try #require(defaults.data(forKey: QuotaStore.defaultsKey))
        let persisted = try JSONDecoder().decode(QuotaSnapshot.self, from: saved)
        #expect(persisted.rateLimit.fiveHour?.utilization == 0.1)
        #expect(persisted.rateLimit.sevenDay?.utilization == 0.5)
        #expect(persisted.receivedAt == start)
    }

    @Test func scrollToDecodesATargetOrAnEdge() throws {
        let decode = { (json: String) in try JSONDecoder().decode(ControlServerRequest.self, from: Data(json.utf8)).command }
        guard case .scrollTo(let byTarget) = try decode(#"{"id":"1","command":"scrollTo","target":{"id":"x"}}"#) else {
            Issue.record("not scrollTo"); return
        }
        #expect(byTarget.target == .control(id: "x", index: nil, label: nil))
        guard case .scrollTo(let byEdge) = try decode(#"{"id":"2","command":"scrollTo","edge":"bottom"}"#) else {
            Issue.record("not scrollTo"); return
        }
        #expect(byEdge.edge == "bottom")
    }

    @Test func injectUsageRejectsOutOfRangeParams() throws {
        #expect(throws: ControlError.self) { try InjectUsageParams(fable: 1.5).validate() }
        #expect(throws: ControlError.self) { try InjectUsageParams(fable: -0.1).validate() }
        #expect(throws: ControlError.self) { try InjectUsageParams(fableResetsInHours: 3).validate() }
        try InjectUsageParams(fable: 1, fableResetsInHours: 3).validate()
        #expect(InjectUsageParams.cents(1e20) == nil)
        #expect(InjectUsageParams.cents(12.4) == 1240)
    }
#endif

    @Test func aReplyFromBeforePollingWasTurnedOffIsDropped() async throws {
        let (settings, cleanup) = try scratchSettings()
        defer { cleanup() }
        let store = QuotaStore()
        let gate = FetchGate()
        let poller = ClaudeUsagePoller(store: store, settings: settings, fetch: { _ in await gate.fetch() })

        let poll = Task { await poller.pollIfDue() }
        await gate.waitForRequest()
        poller.setEnabled(false)
        gate.resume(.reading(ClaudeUsageReading(fable: window(0.3), credit: UsageCredit(usedCents: 1240))))
        await poll.value

        #expect(store.snapshot == nil)
    }

    @Test func aStaleDenialCannotTurnPollingBackOff() async throws {
        let (settings, cleanup) = try scratchSettings()
        defer { cleanup() }
        let gate = FetchGate()
        let poller = ClaudeUsagePoller(store: QuotaStore(), settings: settings, fetch: { _ in await gate.fetch() })

        let poll = Task { await poller.pollIfDue() }
        await gate.waitForRequest()
        poller.setEnabled(false)
        poller.setEnabled(true)
        await poller.pollIfDue()
        #expect(gate.requests == 1)

        gate.resume(.credentialsDenied)
        await poll.value
        #expect(settings.readsClaudeUsage)
    }

    @Test func turningPollingOffForgetsOnlyTheEndpointsReadings() throws {
        let suite = "ClaudeUsageTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = QuotaStore(defaults: defaults)
        store.record(ClaudeUsageReading(fable: window(0.3), credit: UsageCredit(usedCents: 1240)), at: start)
        store.forgetEndpointReadings()
        #expect(store.snapshot?.rateLimit.fable == nil)
        #expect(store.snapshot?.credit == nil)

        store.record(streamInfo(fable: 0.4), at: start.addingTimeInterval(60))
        store.record(ClaudeUsageReading(fable: nil, credit: UsageCredit(usedCents: 1240)), at: start)
        store.forgetEndpointReadings()
        #expect(store.snapshot?.rateLimit.fable?.utilization == 0.4)
        #expect(store.snapshot?.credit == nil)

        let saved = try #require(defaults.data(forKey: QuotaStore.defaultsKey))
        let persisted = try JSONDecoder().decode(QuotaSnapshot.self, from: saved)
        #expect(persisted.credit == nil)
        #expect(persisted.rateLimit.fable?.utilization == 0.4)
    }

    @Test func aReplyWithoutCreditOrFableClearsThem() {
        let store = QuotaStore()
        store.record(ClaudeUsageReading(fable: window(0.3), credit: UsageCredit(usedCents: 1240)), at: start)

        store.record(ClaudeUsageReading(fable: window(0.3), credit: UsageCredit(usedCents: 1240, isEnabled: false)), at: start.addingTimeInterval(60))
        #expect(store.snapshot?.credit == nil)
        #expect(store.snapshot?.creditReceivedAt == nil)

        store.record(ClaudeUsageReading(credit: UsageCredit(usedCents: 1240)), at: start.addingTimeInterval(120))
        #expect(store.snapshot?.rateLimit.fable == nil)
        #expect(store.snapshot?.credit?.usedCents == 1240)

        store.record(ClaudeUsageReading(), at: start.addingTimeInterval(180))
        #expect(store.snapshot?.credit == nil)
    }

    @Test func aReplyWithoutFableKeepsANewerStreamReading() {
        let store = QuotaStore()
        store.record(streamInfo(fable: 0.4), at: start.addingTimeInterval(10))
        store.record(ClaudeUsageReading(), at: start)
        #expect(store.snapshot?.rateLimit.fable?.utilization == 0.4)
    }

    @Test func aDismissedPromptPausesThisLaunchAndASecondTurnsPollingOff() async throws {
        let (settings, cleanup) = try scratchSettings()
        defer { cleanup() }
        let calls = Mutex(0)
        func launch() -> ClaudeUsagePoller {
            ClaudeUsagePoller(store: QuotaStore(), settings: settings, fetch: { _ in
                calls.withLock { $0 += 1 }
                return .credentialsCancelled
            })
        }

        let first = launch()
        await first.pollIfDue()
        #expect(settings.claudeUsageKeychainCancels == 1)
        #expect(settings.readsClaudeUsage)
        await first.pollIfDue()
        #expect(calls.withLock { $0 } == 1)

        await launch().pollIfDue()
        #expect(settings.claudeUsageKeychainCancels == 2)
        #expect(!settings.readsClaudeUsage)
    }

    @Test func aReadOrAnOptInClearsTheDismissedPrompts() async throws {
        let (settings, cleanup) = try scratchSettings()
        defer { cleanup() }
        let results = Mutex<[ClaudeUsageFetchResult]>([.credentialsCancelled, .reading(ClaudeUsageReading())])
        let poller = ClaudeUsagePoller(store: QuotaStore(), settings: settings, fetch: { _ in
            results.withLock { $0.removeFirst() }
        })

        await poller.pollIfDue()
        #expect(settings.claudeUsageKeychainCancels == 1)
        poller.setEnabled(true)
        #expect(settings.claudeUsageKeychainCancels == 0)

        settings.claudeUsageKeychainCancels = 1
        await poller.pollIfDue()
        #expect(settings.claudeUsageKeychainCancels == 0)
        #expect(settings.readsClaudeUsage)
    }

    @Test func readingUsageIsOffUntilTheUserOptsIn() async throws {
        let suite = "ClaudeUsageTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, domainName: suite)
        #expect(!settings.readsClaudeUsage)
        let calls = Mutex(0)
        let poller = ClaudeUsagePoller(store: QuotaStore(), settings: settings, fetch: { _ in
            calls.withLock { $0 += 1 }
            return .unauthorized
        })

        await poller.pollIfDue()
        #expect(calls.withLock { $0 } == 0)
        poller.setEnabled(true)
        await poller.pollIfDue()
        #expect(calls.withLock { $0 } == 1)
    }

    private func scratchSettings() throws -> (AppSettings, () -> Void) {
        let suite = "ClaudeUsageTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let settings = AppSettings(defaults: defaults, domainName: suite)
        settings.readsClaudeUsage = true
        return (settings, { defaults.removePersistentDomain(forName: suite) })
    }

    // MARK: Sidebar

    @Test func extrasShowOnlyOnceTheyApply() {
        let none = QuotaSnapshot.empty(at: start)
        #expect(!SidebarQuotaExtras(snapshot: none, alwaysShows: false, now: start).showsAny)
        let forced = SidebarQuotaExtras(snapshot: nil, alwaysShows: true, now: start)
        #expect(forced.showsFable && forced.showsCredit)

        let idleFable = none.with(fable: window(0), receivedAt: start)
        #expect(!SidebarQuotaExtras(snapshot: idleFable, alwaysShows: false, now: start).showsFable)
        let usedFable = none.with(fable: window(0.01), receivedAt: start)
        #expect(SidebarQuotaExtras(snapshot: usedFable, alwaysShows: false, now: start).showsFable)

        var credit = none
        credit.credit = UsageCredit(usedCents: 0, limitCents: 5000)
        #expect(!SidebarQuotaExtras(snapshot: credit, alwaysShows: false, now: start).showsCredit)
        credit.credit = UsageCredit(usedCents: 1240, limitCents: nil)
        #expect(SidebarQuotaExtras(snapshot: credit, alwaysShows: false, now: start).showsCredit)
        credit.credit = UsageCredit(usedCents: 1240, limitCents: 5000)
        #expect(SidebarQuotaExtras(snapshot: credit, alwaysShows: false, now: start).showsCredit)

        var overage = QuotaSnapshot(
            rateLimit: RateLimitInfo(fiveHour: window(1), sevenDay: nil, isUsingOverage: true),
            receivedAt: start
        )
        #expect(!SidebarQuotaExtras(snapshot: overage, alwaysShows: false, now: start).showsCredit)
        overage.credit = UsageCredit(usedCents: 0, limitCents: nil)
        #expect(SidebarQuotaExtras(snapshot: overage, alwaysShows: false, now: start).showsCredit)
    }

    @Test func creditFormatsAsCurrency() {
        let locale = Locale(identifier: "en_US")
        #expect(UsageCreditFormat.amount(minorUnits: 1240, currency: "USD", locale: locale) == "$12.40")
        #expect(UsageCreditFormat.amount(minorUnits: 1240, currency: nil, locale: locale) == "$12.40")
        #expect(UsageCreditFormat.amount(minorUnits: 1240, currency: "JPY", locale: locale) == "¥1,240")
        #expect(UsageCreditFormat.formatter(currency: "usd", locale: locale) === UsageCreditFormat.formatter(currency: "USD", locale: locale))
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
        #expect(ClaudeUsagePollSchedule.isOverLimit(over, now: start))
        #expect(!ClaudeUsagePollSchedule.isOverLimit(under, now: start))
        #expect(ClaudeUsagePollSchedule.isOverLimit(overage, now: start))
        #expect(!ClaudeUsagePollSchedule.isOverLimit(nil, now: start))
    }

    @Test func aWindowPastItsResetNoLongerShortensThePoll() {
        let full = RateLimitInfo.Window(utilization: 1, resetsAt: start.addingTimeInterval(600))
        let snapshot = QuotaSnapshot(rateLimit: RateLimitInfo(fiveHour: full, sevenDay: nil, isUsingOverage: false), receivedAt: start)

        #expect(ClaudeUsagePollSchedule.isOverLimit(snapshot, now: start.addingTimeInterval(599)))
        #expect(!ClaudeUsagePollSchedule.isOverLimit(snapshot, now: start.addingTimeInterval(600)))
    }

    @Test func anOldReadingNoLongerShortensThePoll() {
        let snapshot = QuotaSnapshot(rateLimit: RateLimitInfo(fiveHour: nil, sevenDay: window(1), isUsingOverage: true), receivedAt: start)
        let maxAge = ClaudeUsagePollSchedule.overLimitReadingMaxAge

        #expect(ClaudeUsagePollSchedule.isOverLimit(snapshot, now: start.addingTimeInterval(maxAge)))
        #expect(!ClaudeUsagePollSchedule.isOverLimit(snapshot, now: start.addingTimeInterval(maxAge + 1)))
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

/// A usage fetch the test answers by hand, so a reply can land after the
/// poller's state has moved on.
private nonisolated final class FetchGate: Sendable {
    private let state = Mutex<(requests: Int, pending: [CheckedContinuation<ClaudeUsageFetchResult, Never>])>((0, []))

    var requests: Int { state.withLock { $0.requests } }

    func fetch() async -> ClaudeUsageFetchResult {
        await withCheckedContinuation { continuation in
            state.withLock {
                $0.requests += 1
                $0.pending.append(continuation)
            }
        }
    }

    func waitForRequest() async {
        while state.withLock({ $0.pending.isEmpty }) { await Task.yield() }
    }

    func resume(_ result: ClaudeUsageFetchResult) {
        state.withLock { $0.pending.removeFirst() }.resume(returning: result)
    }
}
