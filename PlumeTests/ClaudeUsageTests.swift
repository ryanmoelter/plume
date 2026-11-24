import Foundation
import Synchronization
import Testing
@testable import Plume

/// The Fable window and usage-credit spend (PLUME-240): read from the stream
/// and Claude Code's `get_usage` request, merged into `QuotaStore` with the newer Fable
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

    // MARK: get_usage

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

    /// The whole reply line as Claude Code 2.1.328 sends it, with invented
    /// values and most of the unread keys left out.
    private let usageReply = #"""
    {"type":"control_response","response":{"subtype":"success","request_id":"usage","response":{"subscription_type":"team","rate_limits_available":true,"behaviors":null,"session":{"total_cost_usd":0,"model_usage":{}},"rate_limits":{"five_hour":{"utilization":37,"resets_at":"2026-11-18T23:30:00Z","limit_dollars":null},"seven_day":{"utilization":64,"resets_at":"2026-11-22T03:00:00Z"},"seven_day_opus":null,"extra_usage":{"is_enabled":true,"monthly_limit":20000,"used_credits":4321,"utilization":21.6,"currency":"USD","decimal_places":2,"disabled_reason":null},"limits":[{"kind":"session","group":"session","percent":37,"resets_at":"2026-11-18T23:30:00Z","scope":null,"is_active":true},{"kind":"weekly_scoped","group":"weekly","percent":45,"resets_at":"2026-11-22T03:00:00Z","scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":false}],"spend":{"used":{"amount_minor":4321,"currency":"USD","exponent":2},"limit":{"amount_minor":20000,"currency":"USD","exponent":2},"percent":22,"enabled":true,"balance":null},"model_scoped":[{"display_name":"Fable","utilization":45,"resets_at":"2026-11-22T03:00:00Z"}]}}}}
    """#

    @Test func readsTheGetUsageReply() throws {
        guard case .reading(let reading) = ClaudeUsageRequest.result(forLine: usageReply) else {
            Issue.record("not a reading"); return
        }
        #expect(reading.fiveHour?.utilization == 0.37)
        #expect(reading.sevenDay?.utilization == 0.64)
        #expect(reading.fable?.utilization == 0.45)
        #expect(reading.fable?.resetsAt == ISO8601DateFormatter().date(from: "2026-11-22T03:00:00Z"))
        #expect(reading.credit == UsageCredit(usedCents: 4321, limitCents: 20000, isEnabled: true, currency: "USD"))
    }

    @Test func readsFableFromModelScopedWithoutALimitsRow() throws {
        let reading = try #require(ClaudeUsageParser.parse(Data(#"{"model_scoped":[{"display_name":"Sonnet","utilization":10},{"display_name":"Fable","utilization":30,"resets_at":null}]}"#.utf8)))
        #expect(reading.fable?.utilization == 0.3)
    }

    @Test func aLoginWithoutTheProfileScopeIsUnavailable() {
        let line = #"{"type":"control_response","response":{"subtype":"success","request_id":"usage","response":{"subscription_type":null,"rate_limits_available":false,"rate_limits":null,"session":{}}}}"#
        #expect(ClaudeUsageRequest.result(forLine: line) == .unavailable)
    }

    @Test func onlyAnExplicitNoSaysUsageIsUnavailable() {
        let reply = { (body: String) in
            #"{"type":"control_response","response":{"subtype":"success","request_id":"usage""# + body + "}}"
        }
        #expect(ClaudeUsageRequest.result(forLine: reply(#","response":{"rate_limits_available":false}"#)) == .unavailable)
        #expect(ClaudeUsageRequest.result(forLine: reply(#","response":{"rate_limits_available":false,"rate_limits":{}}"#)) == .unavailable)
        #expect(ClaudeUsageRequest.result(forLine: reply("")) == .failed, "no inner response")
        #expect(ClaudeUsageRequest.result(forLine: reply(#","response":{"rate_limits_available":true}"#)) == .failed, "no rate_limits")
        #expect(ClaudeUsageRequest.result(forLine: reply(#","response":{"rate_limits":null}"#)) == .failed, "null without saying unavailable")
        #expect(ClaudeUsageRequest.result(forLine: reply(#","response":{"rate_limits":[]}"#)) == .failed)
    }

    @Test func aReplyWithNoRecognisedFieldFails() {
        let line = #"{"type":"control_response","response":{"subtype":"success","request_id":"usage","response":{"rate_limits":{"something_new":[{"x":1}]}}}}"#
        #expect(ClaudeUsageRequest.result(forLine: line) == .failed)
    }

    @Test func anErrorReplyFails() {
        let line = #"{"type":"control_response","response":{"subtype":"error","request_id":"usage","error":"Unknown request subtype"}}"#
        #expect(ClaudeUsageRequest.result(forLine: line) == .failed)
    }

    @Test func otherLinesAreNotTheReply() {
        #expect(ClaudeUsageRequest.result(forLine: #"{"type":"control_response","response":{"subtype":"success","request_id":"initialize","response":{}}}"#) == nil)
        #expect(ClaudeUsageRequest.result(forLine: #"{"type":"system","subtype":"hook_started"}"#) == nil)
        #expect(ClaudeUsageRequest.result(forLine: "control_response, not JSON") == nil)
    }

    @Test func theRequestAsksForUsageByItsOwnID() throws {
        let request = try JSONDecoder().decode([String: JSONValue].self, from: Data(ClaudeUsageRequest.lines[1].utf8))
        #expect(request["request_id"]?.stringValue == ClaudeUsageRequest.requestID)
        #expect(request["request"]?.objectValue?["subtype"]?.stringValue == "get_usage")
        #expect(ClaudeUsageRequest.arguments.contains("--no-session-persistence"))
        #expect(ClaudeUsageRequest.arguments.first == "claude")
        #expect(ClaudeUsageRequest.droppedEnvironmentKeys == ["CLAUDECODE", "CLAUDE_CODE_CHILD_SESSION"])
        let environment = LoginShellCommand.childEnvironment(overrides: [:], removing: ["PATH"])
        #expect(environment["PATH"] == nil)
    }

    @Test func readingUsageIsOnByDefaultWhateverTheOptInStored() async throws {
        let suite = "ClaudeUsageTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "readsClaudeUsage")
        let settings = AppSettings(defaults: defaults, domainName: suite)
        #expect(settings.readsClaudeUsage)
        let calls = Mutex(0)
        let poller = ClaudeUsagePoller(store: QuotaStore(), settings: settings, fetch: { _ in
            calls.withLock { $0 += 1 }
            return .unavailable
        })
        await poller.pollIfDue()
        #expect(calls.withLock { $0 } == 1)

        poller.setEnabled(false)
        #expect(!AppSettings(defaults: defaults, domainName: suite).readsClaudeUsage)
        await poller.pollIfDue()
        #expect(calls.withLock { $0 } == 1)
    }

    @Test func withoutClaudeCodeNothingIsFetched() async throws {
        let (settings, cleanup) = try scratchSettings()
        defer { cleanup() }
        settings.alwaysShowsCreditAndFableQuota = true
        let calls = Mutex(0)
        let poller = ClaudeUsagePoller(
            store: QuotaStore(),
            settings: settings,
            fetch: { _ in
                calls.withLock { $0 += 1 }
                return .unavailable
            },
            isClaudeAvailable: { false }
        )
        poller.setEnabled(true)
        await poller.pollIfDue()
        #expect(calls.withLock { $0 } == 0)
        guard case .failed = poller.status else {
            Issue.record("expected a failure, got \(poller.status)"); return
        }
        await poller.pollIfDue()
        #expect(calls.withLock { $0 } == 0, "the next check waits for the regular interval")
    }

    @Test func aProbeFinishedBeforeBeginAnswersAtOnce() async {
        let probe = UsageProbe()
        probe.finish(.reading(ClaudeUsageReading(fiveHour: window(0.1))))
        let result = await withCheckedContinuation { probe.begin($0) }
        #expect(result == .failed)
    }

    @Test func anUnavailableReplyForgetsEndpointReadings() async throws {
        let (settings, cleanup) = try scratchSettings()
        defer { cleanup() }
        let store = QuotaStore()
        store.record(ClaudeUsageReading(fable: window(0.3), credit: UsageCredit(usedCents: 1240)), at: start)
        let poller = ClaudeUsagePoller(store: store, settings: settings, fetch: { _ in .unavailable })
        await poller.pollIfDue()
        #expect(store.snapshot?.credit == nil)
        #expect(store.snapshot?.rateLimit.fable == nil)
    }

    @Test func aPollStartedByStartSurfacesCheckingThenFailure() async throws {
        let (settings, cleanup) = try scratchSettings()
        defer { cleanup() }
        settings.alwaysShowsCreditAndFableQuota = true
        let gate = FetchGate()
        let poller = ClaudeUsagePoller(
            store: QuotaStore(), settings: settings, fetch: { _ in await gate.fetch() }, canPoll: true
        )
        poller.start()
        #expect(poller.status == .checking)
        await gate.waitForRequest()
        gate.resume(.failed)
        for _ in 0..<200 where poller.status == .checking { try await Task.sleep(for: .milliseconds(10)) }
        poller.stop()
        guard case .failed = poller.status else {
            Issue.record("expected a failure, got \(poller.status)"); return
        }
    }

    @Test func aLoginThatDoesNotReportUsageShowsNoFailure() async throws {
        let (settings, cleanup) = try scratchSettings()
        defer { cleanup() }
        settings.alwaysShowsCreditAndFableQuota = true
        let gate = FetchGate()
        let poller = ClaudeUsagePoller(
            store: QuotaStore(), settings: settings, fetch: { _ in await gate.fetch() }, canPoll: true
        )
        poller.start()
        #expect(poller.status == .checking)
        await gate.waitForRequest()
        gate.resume(.unavailable)
        for _ in 0..<200 where poller.status == .checking { try await Task.sleep(for: .milliseconds(10)) }
        poller.stop()
        #expect(poller.status == .idle)
    }

    @Test func checkingShowsOnlyWhereTheReplyWouldShow() {
        let none = QuotaSnapshot.empty(at: start)
        #expect(ClaudeUsageStatus.beforeFirstReply(alwaysShows: false, snapshot: nil, now: start) == .idle)
        #expect(ClaudeUsageStatus.beforeFirstReply(alwaysShows: false, snapshot: none, now: start) == .idle)
        #expect(ClaudeUsageStatus.beforeFirstReply(alwaysShows: true, snapshot: nil, now: start) == .checking)

        var noLimit = none
        noLimit.credit = UsageCredit(usedCents: 1240, limitCents: nil)
        #expect(ClaudeUsageStatus.beforeFirstReply(alwaysShows: false, snapshot: noLimit, now: start) == .idle)

        var spent = none
        spent.credit = UsageCredit(usedCents: 1240, limitCents: 5000)
        #expect(ClaudeUsageStatus.beforeFirstReply(alwaysShows: false, snapshot: spent, now: start) == .checking)
        let fable = none.with(fable: window(0.3), receivedAt: start)
        #expect(ClaudeUsageStatus.beforeFirstReply(alwaysShows: false, snapshot: fable, now: start) == .checking)
    }

    @Test func anAccountWithNothingShowableSurfacesNoFailure() async throws {
        let (settings, cleanup) = try scratchSettings()
        defer { cleanup() }
        let store = QuotaStore()
        store.record(streamInfo(fable: nil), at: start)
        let gate = FetchGate()
        let poller = ClaudeUsagePoller(store: store, settings: settings, fetch: { _ in await gate.fetch() }, canPoll: true)
        poller.start()
        #expect(poller.status == .idle)
        await gate.waitForRequest()
        gate.resume(.failed)
        for _ in 0..<50 { await Task.yield() }
        poller.stop()
        #expect(poller.status == .idle)
    }

    @Test func turningReadingBackOnMidFetchPollsAsSoonAsTheOldFetchEnds() async throws {
        let (settings, cleanup) = try scratchSettings()
        defer { cleanup() }
        let gate = FetchGate()
        let poller = ClaudeUsagePoller(store: QuotaStore(), settings: settings, fetch: { _ in await gate.fetch() }, canPoll: true)
        poller.start()
        await gate.waitForRequest()
        poller.setEnabled(false)
        poller.setEnabled(true)
        // Let the new loop's first poll find the old request in flight.
        for _ in 0..<50 { await Task.yield() }
        #expect(gate.requests == 1)
        gate.resume(.failed)
        for _ in 0..<200 where gate.requests < 2 { try await Task.sleep(for: .milliseconds(10)) }
        poller.stop()
        #expect(gate.requests == 2)
        await gate.waitForRequest()
        gate.resume(.failed)
    }

    @Test func turningReadingOffWhileLookingForClaudeCodeFetchesNothing() async throws {
        let (settings, cleanup) = try scratchSettings()
        defer { cleanup() }
        let availability = AvailabilityGate()
        let calls = Mutex(0)
        let poller = ClaudeUsagePoller(
            store: QuotaStore(),
            settings: settings,
            fetch: { _ in
                calls.withLock { $0 += 1 }
                return .failed
            },
            isClaudeAvailable: { await availability.check() }
        )
        poller.setEnabled(true)
        let poll = Task { await poller.pollIfDue() }
        await availability.waitForCheck()
        poller.setEnabled(false)
        availability.resume(true)
        await poll.value
        #expect(calls.withLock { $0 } == 0)
        #expect(poller.status == .idle)
    }

#if DEBUG
    @Test func anInjectionWhileLookingForClaudeCodeKeepsItsState() async throws {
        let (settings, cleanup) = try scratchSettings()
        defer { cleanup() }
        settings.alwaysShowsCreditAndFableQuota = true
        let availability = AvailabilityGate()
        let poller = ClaudeUsagePoller(
            store: QuotaStore(),
            settings: settings,
            fetch: { _ in .failed },
            isClaudeAvailable: { await availability.check() }
        )
        poller.setEnabled(true)
        let poll = Task { await poller.pollIfDue() }
        await availability.waitForCheck()
        poller.isSuspended = true
        availability.resume(false)
        await poll.value
        #expect(poller.status == .checking, "a suspended poll surfaces nothing")
    }
#endif

    @Test func aFinishedProbeReleasesItsProcess() async throws {
        weak var weakProbe: UsageProbe?
        weak var weakProcess: AgentProcess?
        let result = await withCheckedContinuation { (outer: CheckedContinuation<ClaudeUsageFetchResult, Never>) in
            let probe = UsageProbe()
            weakProbe = probe
            probe.begin(outer)
            let process = AgentProcess(
                label: "usage probe test",
                onLine: { line in
                    if let result = ClaudeUsageRequest.result(forLine: line) { probe.finish(result) }
                },
                onExit: { status, errorLine in probe.finish(.failed, exit: (status, errorLine)) }
            )
            weakProcess = process
            do {
                try process.start(arguments: ["cat"], workingDirectory: nil, environment: [:])
            } catch {
                probe.finish(.failed)
                return
            }
            probe.adopt(process)
            process.send(line: #"{"type":"control_response","response":{"subtype":"success","request_id":"usage","response":{"rate_limits":{"five_hour":{"utilization":10}}}}}"#)
        }
        #expect(result == .reading(ClaudeUsageReading(fiveHour: window(0.1))))
        for _ in 0..<200 where weakProbe != nil || weakProcess != nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(weakProbe == nil)
        #expect(weakProcess == nil)
    }

    @Test func aTurnEndPollsOnlyWhileOverALimit() async throws {
        let (settings, cleanup) = try scratchSettings()
        defer { cleanup() }
        let store = QuotaStore()
        let calls = Mutex(0)
        let poller = ClaudeUsagePoller(store: store, settings: settings, fetch: { _ in
            calls.withLock { $0 += 1 }
            return .reading(ClaudeUsageReading())
        })
        await poller.pollIfDue()
        store.record(RateLimitInfo(fiveHour: window(0.5), sevenDay: window(0.5), isUsingOverage: false), at: Date())
        await poller.pollAtTurnEnd()
        #expect(calls.withLock { $0 } == 1, "under the limits a turn end adds no poll")
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

    @Test func forgettingEndpointReadingsDuringAnInjectionKeepsThemOffDisk() throws {
        let suite = "ClaudeUsageTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = QuotaStore(defaults: defaults)
        store.record(streamInfo(fable: nil), at: start)
        store.record(ClaudeUsageReading(fable: window(0.1), credit: UsageCredit(usedCents: 100, limitCents: 500)), at: start)
        store.inject(fable: window(0.9), credit: UsageCredit(usedCents: 9999, limitCents: 10000), isUsingOverage: nil)

        store.forgetEndpointReadings()
        let saved = try #require(defaults.data(forKey: QuotaStore.defaultsKey))
        let persisted = try JSONDecoder().decode(QuotaSnapshot.self, from: saved)
        #expect(persisted.credit == nil)
        #expect(persisted.rateLimit.fable == nil)

        store.endInjection()
        #expect(store.snapshot?.credit == nil)
        #expect(store.snapshot?.rateLimit.fable == nil)
        #expect(store.snapshot?.rateLimit.fiveHour?.utilization == 0.1)
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

    @Test func aHugeAmountParsesAsUnknown() throws {
        let body = #"{"extra_usage":{"is_enabled":true,"monthly_limit":1e20,"used_credits":1240},"five_hour":{"utilization":1e20}}"#
        let reading = try #require(ClaudeUsageParser.parse(Data(body.utf8)))
        #expect(reading.credit?.limitCents == nil)
        #expect(reading.credit?.usedCents == 1240)
        #expect(SidebarQuotaSummary.percent(reading.fiveHour!.utilization) == "999%")
        #expect(SidebarQuotaSummary.percent(.nan) == "—")
        #expect(SidebarQuotaSummary.percent(0.214) == "21%")
    }

    @Test func amountsHonorTheReplysExponent() throws {
        let spend = #"{"spend":{"used":{"amount_minor":124000,"currency":"USD","exponent":4},"limit":{"amount_minor":50,"currency":"USD","exponent":0}}}"#
        let spendCredit = try #require(ClaudeUsageParser.parse(Data(spend.utf8))?.credit)
        #expect(spendCredit.usedCents == 1240)
        #expect(spendCredit.limitCents == 5000)

        let extra = #"{"extra_usage":{"is_enabled":true,"monthly_limit":500,"used_credits":124,"currency":"USD","decimal_places":1}}"#
        let extraCredit = try #require(ClaudeUsageParser.parse(Data(extra.utf8))?.credit)
        #expect(extraCredit.usedCents == 1240)
        #expect(extraCredit.limitCents == 5000)
        #expect(UsageCreditFormat.amount(minorUnits: extraCredit.usedCents!, currency: extraCredit.currency, locale: Locale(identifier: "en_US")) == "$12.40")
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
        snapshot.credit = UsageCredit(usedCents: 0, limitCents: 5000)

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
        snapshot.credit = UsageCredit(usedCents: 0, limitCents: 5000)
        let maxAge = ClaudeUsagePollSchedule.overLimitReadingMaxAge

        #expect(SidebarQuotaExtras(snapshot: snapshot, alwaysShows: false, now: start.addingTimeInterval(maxAge)).showsCredit)
        #expect(!SidebarQuotaExtras(snapshot: snapshot, alwaysShows: false, now: start.addingTimeInterval(maxAge + 1)).showsCredit)
    }

    @Test func creditGlyphFillsTowardTheLimit() {
        let locale = Locale(identifier: "en_US")
        #expect(UsageCreditFormat.fraction(UsageCredit(usedCents: 1240, limitCents: 5000)) == 0.248)
        #expect(UsageCreditFormat.fraction(UsageCredit(usedCents: 9000, limitCents: 5000)) == 1)
        #expect(UsageCreditFormat.fraction(UsageCredit(usedCents: 1240)) == nil)
        #expect(UsageCreditFormat.fraction(UsageCredit(usedCents: 1240, limitCents: 0)) == nil)
        #expect(UsageCreditFormat.detailLines(UsageCredit(usedCents: 1240, limitCents: 5000), locale: locale)
            == ["$12.40 used this month", "Monthly limit: $50.00", "$37.60 left"])
        #expect(UsageCreditFormat.detailLines(nil) == ["No reading yet"])
    }

    @Test func creditPacingFollowsTheBillingMonth() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(identifier: "UTC"))
        let resetsAt = try #require(utc.date(from: DateComponents(year: 2026, month: 12, day: 1)))
        // November has 30 days, so the 16th at midnight is half way through.
        let midMonth = try #require(utc.date(from: DateComponents(year: 2026, month: 11, day: 16)))
        let limited = UsageCredit(usedCents: 1240, limitCents: 5000, resetsAt: resetsAt)

        #expect(UsageCreditFormat.pacing(limited, now: midMonth, calendar: utc) == 0.5)
        #expect(UsageCreditFormat.pacing(UsageCredit(usedCents: 1240, resetsAt: resetsAt), now: midMonth, calendar: utc) == nil)
        #expect(UsageCreditFormat.pacing(UsageCredit(usedCents: 1240, limitCents: 5000), now: midMonth, calendar: utc) == nil)
        #expect(UsageCreditFormat.pacing(limited, now: resetsAt.addingTimeInterval(60), calendar: utc) == nil)
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

    @Test func turningReadingOnEndsAnInjectionSoTheRealPollReplacesIt() async throws {
        let (settings, cleanup) = try scratchSettings()
        defer { cleanup() }
        settings.alwaysShowsCreditAndFableQuota = true
        settings.readsClaudeUsage = false
        let store = QuotaStore()
        store.record(streamInfo(fable: nil), at: start)
        let gate = FetchGate()
        let poller = ClaudeUsagePoller(store: store, settings: settings, fetch: { _ in await gate.fetch() })
        poller.isSuspended = true
        store.inject(fable: window(0.42), credit: UsageCredit(usedCents: 1240, limitCents: 5000), isUsingOverage: nil, clearsWindows: true)

        poller.setEnabled(true)
        #expect(!poller.isSuspended)
        #expect(store.snapshot?.rateLimit.fable == nil)
        #expect(store.snapshot?.credit == nil)
        #expect(store.snapshot?.rateLimit.fiveHour?.utilization == 0.1)
        #expect(poller.status == .checking)

        let poll = Task { await poller.pollIfDue() }
        await gate.waitForRequest()
        gate.resume(.reading(ClaudeUsageReading(fable: window(0.3), credit: UsageCredit(usedCents: 700, limitCents: 5000))))
        await poll.value
        #expect(store.snapshot?.rateLimit.fable?.utilization == 0.3)
        #expect(store.snapshot?.credit?.usedCents == 700)
        #expect(poller.status == .idle)
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

    @Test func turningReadingOnChecksUntilTheFirstReplyAndSurfacesItsFailure() async throws {
        let (settings, cleanup) = try scratchSettings()
        defer { cleanup() }
        settings.alwaysShowsCreditAndFableQuota = true
        let gate = FetchGate()
        let poller = ClaudeUsagePoller(store: QuotaStore(), settings: settings, fetch: { _ in await gate.fetch() })
        #expect(poller.status == .idle)

        poller.setEnabled(true)
        #expect(poller.status == .checking)
        var poll = Task { await poller.pollIfDue() }
        await gate.waitForRequest()
        gate.resume(.failed)
        await poll.value
        guard case .failed(let reason) = poller.status else {
            Issue.record("expected a failure, got \(poller.status)"); return
        }
        #expect(reason.contains("couldn't read usage"))

        poller.setEnabled(true)
        poll = Task { await poller.pollIfDue() }
        await gate.waitForRequest()
        gate.resume(.reading(ClaudeUsageReading(fable: window(0.3))))
        await poll.value
        #expect(poller.status == .idle)

        poller.setEnabled(true)
        poller.setEnabled(false)
        #expect(poller.status == .idle)
    }

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
        #expect(!SidebarQuotaExtras(snapshot: credit, alwaysShows: false, now: start).showsCredit)
        #expect(!SidebarQuotaExtras(snapshot: credit, alwaysShows: true, now: start).showsCredit)
        credit.credit = UsageCredit(usedCents: 1240, limitCents: 5000)
        #expect(SidebarQuotaExtras(snapshot: credit, alwaysShows: false, now: start).showsCredit)

        var overage = QuotaSnapshot(
            rateLimit: RateLimitInfo(fiveHour: window(1), sevenDay: nil, isUsingOverage: true),
            receivedAt: start
        )
        #expect(!SidebarQuotaExtras(snapshot: overage, alwaysShows: false, now: start).showsCredit)
        overage.credit = UsageCredit(usedCents: 0, limitCents: 5000)
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
        #expect(ClaudeUsagePollSchedule.delay(after: .success, consecutiveFailures: 0) == 20 * 60)
        #expect(ClaudeUsagePollSchedule.delay(after: .skipped, consecutiveFailures: 0) == 20 * 60)
        #expect(ClaudeUsagePollSchedule.isDue(now: start, lastAttempt: nil, outcome: .success, consecutiveFailures: 0))
        #expect(!ClaudeUsagePollSchedule.isDue(now: start.addingTimeInterval(19 * 60), lastAttempt: start, outcome: .success, consecutiveFailures: 0))
        #expect(ClaudeUsagePollSchedule.isDue(now: start.addingTimeInterval(20 * 60), lastAttempt: start, outcome: .success, consecutiveFailures: 0))
    }

    @Test func aLoginWithoutUsageIsAskedAgainOnlyHourly() {
        #expect(ClaudeUsagePollSchedule.delay(after: .unavailable, consecutiveFailures: 0) == 60 * 60)
        #expect(!ClaudeUsagePollSchedule.isDue(
            now: start.addingTimeInterval(59 * 60), lastAttempt: start, outcome: .unavailable, consecutiveFailures: 0
        ))
        #expect(ClaudeUsagePollSchedule.isDue(
            now: start.addingTimeInterval(60 * 60), lastAttempt: start, outcome: .unavailable, consecutiveFailures: 0
        ))
        #expect(!ClaudeUsagePollSchedule.isDueAtTurnEnd(
            now: start.addingTimeInterval(3 * 3600), isOverLimit: true, lastAttempt: start, consecutiveFailures: 0, lastOutcome: .unavailable
        ))
    }

    @Test func failuresBackOffToTheCap() {
        let delays = [1, 2, 3, 50].map { ClaudeUsagePollSchedule.delay(after: .failed, consecutiveFailures: $0) }
        #expect(delays == [20, 40, 60, 60].map { $0 * 60.0 })
    }

    @Test func aTurnEndWhileOverALimitPollsAtMostEveryTwoMinutes() {
        let isDue = { (elapsed: TimeInterval, failures: Int) in
            ClaudeUsagePollSchedule.isDueAtTurnEnd(
                now: start.addingTimeInterval(elapsed), isOverLimit: true, lastAttempt: start, consecutiveFailures: failures
            )
        }
        #expect(ClaudeUsagePollSchedule.isDueAtTurnEnd(now: start, isOverLimit: true, lastAttempt: nil, consecutiveFailures: 0))
        #expect(!isDue(119, 0))
        #expect(isDue(120, 0))
        #expect(!isDue(120, 2), "a failing fetch keeps its backoff")
        #expect(isDue(40 * 60, 2))
    }

    @Test func anAccountWithoutUsageDataIsNotPolledAtTurnEnd() {
        #expect(!ClaudeUsagePollSchedule.isDueAtTurnEnd(
            now: start.addingTimeInterval(3600), isOverLimit: true, lastAttempt: start, consecutiveFailures: 0, lastOutcome: .skipped
        ))
        #expect(ClaudeUsagePollSchedule.isDueAtTurnEnd(
            now: start.addingTimeInterval(3600), isOverLimit: true, lastAttempt: start, consecutiveFailures: 0, lastOutcome: .success
        ))
    }

    @Test func aTurnEndUnderTheLimitsAddsNoPoll() {
        #expect(!ClaudeUsagePollSchedule.isDueAtTurnEnd(now: start, isOverLimit: false, lastAttempt: nil, consecutiveFailures: 0))
        #expect(!ClaudeUsagePollSchedule.isDueAtTurnEnd(
            now: start.addingTimeInterval(3600), isOverLimit: false, lastAttempt: start, consecutiveFailures: 0
        ))
    }

    @Test func overALimitMeansAFullWindowOrOverage() {
        let over = QuotaSnapshot(rateLimit: RateLimitInfo(fiveHour: window(1), sevenDay: window(0.5), isUsingOverage: false), receivedAt: start)
        let under = QuotaSnapshot(rateLimit: RateLimitInfo(fiveHour: window(0.99), sevenDay: window(0.5), isUsingOverage: false), receivedAt: start)
        let overage = QuotaSnapshot(rateLimit: RateLimitInfo(fiveHour: nil, sevenDay: nil, isUsingOverage: true), receivedAt: start)
        #expect(ClaudeUsagePollSchedule.isOverLimit(over, now: start))
        #expect(!ClaudeUsagePollSchedule.isOverLimit(under, now: start))
        #expect(ClaudeUsagePollSchedule.isOverLimit(overage, now: start))
        #expect(!ClaudeUsagePollSchedule.isOverLimit(nil, now: start))
    }

    @Test func aWindowPastItsResetIsNoLongerOverTheLimit() {
        let full = RateLimitInfo.Window(utilization: 1, resetsAt: start.addingTimeInterval(600))
        let snapshot = QuotaSnapshot(rateLimit: RateLimitInfo(fiveHour: full, sevenDay: nil, isUsingOverage: false), receivedAt: start)

        #expect(ClaudeUsagePollSchedule.isOverLimit(snapshot, now: start.addingTimeInterval(599)))
        #expect(!ClaudeUsagePollSchedule.isOverLimit(snapshot, now: start.addingTimeInterval(600)))
    }

    @Test func anOldReadingIsNoLongerOverTheLimit() {
        let snapshot = QuotaSnapshot(rateLimit: RateLimitInfo(fiveHour: nil, sevenDay: window(1), isUsingOverage: true), receivedAt: start)
        let maxAge = ClaudeUsagePollSchedule.overLimitReadingMaxAge

        #expect(ClaudeUsagePollSchedule.isOverLimit(snapshot, now: start.addingTimeInterval(maxAge)))
        #expect(!ClaudeUsagePollSchedule.isOverLimit(snapshot, now: start.addingTimeInterval(maxAge + 1)))
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

private nonisolated final class AvailabilityGate: Sendable {
    private let pending = Mutex<[CheckedContinuation<Bool, Never>]>([])

    func check() async -> Bool {
        await withCheckedContinuation { continuation in
            pending.withLock { $0.append(continuation) }
        }
    }

    func waitForCheck() async {
        while pending.withLock({ $0.isEmpty }) { await Task.yield() }
    }

    func resume(_ isAvailable: Bool) {
        pending.withLock { $0.removeFirst() }.resume(returning: isAvailable)
    }
}
