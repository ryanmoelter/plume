import Foundation
import Testing

@testable import Plume

/// An account whose only Codex limit is weekly, in `primary`, restores and
/// updates as one 7d window: no reset time borrowed across a change of
/// duration, and no window the server has stopped reporting.
@MainActor
struct CodexQuotaRelaunchTests {
    private func decode(_ json: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    private func scratchDefaults() -> UserDefaults {
        UserDefaults(suiteName: "CodexQuotaRelaunchTests.\(UUID().uuidString)")!
    }

    /// Captured from `codex app-server` 0.153.4 `account/rateLimits/read`.
    private let accountRead = #"""
    {"rateLimits":{"limitId":"codex","limitName":null,
      "primary":{"usedPercent":68,"windowDurationMins":10080,"resetsAt":1790537778},
      "secondary":null,"credits":{"hasCredits":false,"unlimited":false,"balance":"0"},
      "individualLimit":null,"spendControlReached":false,"planType":"prolite","rateLimitReachedType":null},
     "rateLimitsByLimitId":{"codex":{"limitId":"codex","limitName":null,
      "primary":{"usedPercent":68,"windowDurationMins":10080,"resetsAt":1790537778},
      "secondary":null,"credits":{"hasCredits":false,"unlimited":false,"balance":"0"},
      "individualLimit":null,"spendControlReached":false,"planType":"prolite","rateLimitReachedType":null}}}
    """#

    /// The rolling update's shape, as the rollout records it per turn.
    private let rollingUpdate = #"""
    {"rateLimits":{"limitId":"codex","limitName":null,
      "primary":{"usedPercent":69,"windowDurationMins":10080,"resetsAt":1790537778},
      "secondary":null,"planType":"prolite"}}
    """#

    private let weeklyReset = Date(timeIntervalSince1970: 1_790_537_778)

    @Test func realAccountReadIsOneWeeklyWindow() throws {
        let store = CodexQuotaStore()
        store.record(try decode(accountRead))

        #expect(store.windows.count == 1)
        let window = try #require(store.windows.first)
        #expect(window.timeframe == "7d")
        #expect(window.usedPercent == 68)
        #expect(window.resetsAt == weeklyReset)
    }

    @Test func sparseWindowOfANewDurationDoesNotBorrowTheOldResetTime() throws {
        var limits = CodexRateLimits()
        _ = limits.receive(try decode(accountRead))
        _ = limits.receive(try decode(#"""
        {"rateLimits":{"primary":{"usedPercent":45,"windowDurationMins":300}}}
        """#))

        let window = try #require(limits.windows.first)
        #expect(window.durationMinutes == 300)
        #expect(window.resetsAt == nil)
    }

    /// The snapshot a hosted test run left in the Debug app's defaults: the
    /// test's sparse 5h/7d update merged onto the real weekly window.
    @Test func phantomWindowsFromAPollutedSnapshotClearOnTheNextLiveUpdate() throws {
        let defaults = scratchDefaults()
        let savedAt = Date(timeIntervalSinceReferenceDate: 812_074_948)
        let polluted = CodexQuotaSnapshot(
            windows: [
                CodexQuotaWindow(bucketID: "codex", bucketName: nil, slot: .primary, usedPercent: 45, durationMinutes: 300, resetsAt: weeklyReset),
                CodexQuotaWindow(bucketID: "codex", bucketName: nil, slot: .secondary, usedPercent: 81, durationMinutes: 10_080, resetsAt: nil),
            ],
            receivedAt: ["codex:primary": savedAt, "codex:secondary": savedAt]
        )
        defaults.set(try JSONEncoder().encode(polluted), forKey: CodexQuotaStore.defaultsKey)

        let relaunched = CodexQuotaStore(defaults: defaults, now: savedAt.addingTimeInterval(60))
        relaunched.record(try decode(rollingUpdate), at: savedAt.addingTimeInterval(120))

        #expect(relaunched.windows.map(\.timeframe) == ["7d"])
        #expect(relaunched.windows.map(\.usedPercent) == [69])
        #expect(relaunched.windows.first?.resetsAt == weeklyReset)
    }

    @Test func sharedStoresDoNotPersistUnderATestHost() {
        #expect(QuotaPersistence.sharedDefaults(environment: ["XCTestConfigurationFilePath": "/x"], isTestHost: false) == nil)
        #expect(QuotaPersistence.sharedDefaults(environment: [:], isTestHost: true) == nil)
        #expect(QuotaPersistence.sharedDefaults(environment: [:], isTestHost: false) === UserDefaults.standard)
        #expect(QuotaPersistence.sharedDefaults() == nil)
    }
}
