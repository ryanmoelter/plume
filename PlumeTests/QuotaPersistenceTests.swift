import Foundation
import Testing
@testable import Plume

/// Both quota stores restore their last reading at launch, and a window that
/// has reset since it was saved reads 0% with no reset time.
@MainActor
struct QuotaPersistenceTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func scratchDefaults() -> UserDefaults {
        UserDefaults(suiteName: "QuotaPersistenceTests.\(UUID().uuidString)")!
    }

    // MARK: - Claude

    @Test func claudeReadingSurvivesARelaunch() {
        let defaults = scratchDefaults()
        let reading = RateLimitInfo(
            fiveHour: .init(utilization: 0.4, resetsAt: start.addingTimeInterval(3600)),
            sevenDay: .init(utilization: 0.2, resetsAt: start.addingTimeInterval(86400)),
            isUsingOverage: false
        )
        QuotaStore(defaults: defaults, now: start).record(reading, at: start)

        let relaunched = QuotaStore(defaults: defaults, now: start.addingTimeInterval(60))
        #expect(relaunched.snapshot == QuotaSnapshot(rateLimit: reading, receivedAt: start))
    }

    @Test func claudeStoreWithoutDefaultsStartsEmpty() {
        QuotaStore().record(RateLimitInfo(fiveHour: .init(utilization: 0.4, resetsAt: nil), sevenDay: nil, isUsingOverage: false))
        #expect(QuotaStore().snapshot == nil)
    }

    @Test func claudeWindowPastItsResetZeroesOnRestore() {
        let snapshot = QuotaSnapshot(
            rateLimit: RateLimitInfo(
                fiveHour: .init(utilization: 0.9, resetsAt: start.addingTimeInterval(3600)),
                sevenDay: .init(utilization: 0.5, resetsAt: start.addingTimeInterval(86400)),
                isUsingOverage: false
            ),
            receivedAt: start
        )
        let restored = snapshot.restored(now: start.addingTimeInterval(7200))

        #expect(restored.rateLimit.fiveHour == .init(utilization: 0, resetsAt: nil))
        #expect(restored.rateLimit.sevenDay == snapshot.rateLimit.sevenDay)
        #expect(restored.receivedAt == start)
    }

    @Test func claudeWindowWithoutResetTimeExpiresByItsLength() {
        let snapshot = QuotaSnapshot(
            rateLimit: RateLimitInfo(
                fiveHour: .init(utilization: 0.9, resetsAt: nil),
                sevenDay: .init(utilization: 0.5, resetsAt: nil),
                isUsingOverage: false
            ),
            receivedAt: start
        )

        let early = snapshot.restored(now: start.addingTimeInterval(QuotaWindowLength.fiveHour - 1))
        #expect(early == snapshot)

        let late = snapshot.restored(now: start.addingTimeInterval(QuotaWindowLength.fiveHour))
        #expect(late.rateLimit.fiveHour?.utilization == 0)
        #expect(late.rateLimit.sevenDay?.utilization == 0.5)
    }

    @Test func liveReadingPastItsResetIsNotZeroed() {
        let store = QuotaStore()
        store.record(RateLimitInfo(
            fiveHour: .init(utilization: 0.9, resetsAt: start.addingTimeInterval(-60)),
            sevenDay: nil,
            isUsingOverage: false
        ), at: start)
        #expect(store.snapshot?.rateLimit.fiveHour?.utilization == 0.9)
    }

    // MARK: - Codex

    private func window(_ percent: Int, minutes: Int? = 300, resetsAt: Date?) -> JSONValue {
        var object: [String: JSONValue] = ["usedPercent": .number(Double(percent))]
        if let minutes { object["windowDurationMins"] = .number(Double(minutes)) }
        if let resetsAt { object["resetsAt"] = .number(resetsAt.timeIntervalSince1970) }
        return .object(object)
    }

    @Test func codexReadingSurvivesARelaunch() throws {
        let defaults = scratchDefaults()
        let store = CodexQuotaStore(defaults: defaults, now: start)
        store.record(.object(["rateLimitsByLimitId": .object([
            "codex": .object([
                "limitName": .string("Codex"),
                "primary": window(40, resetsAt: start.addingTimeInterval(3600)),
                "secondary": window(10, minutes: 10_080, resetsAt: start.addingTimeInterval(86400)),
            ]),
            "spark": .object(["primary": window(5, resetsAt: start.addingTimeInterval(3600))]),
        ])]), at: start)

        let now = start.addingTimeInterval(QuotaFreshness.staleAfter + 1)
        let relaunched = CodexQuotaStore(defaults: defaults, now: now)
        #expect(relaunched.windows == store.windows)
        let first = try #require(relaunched.windows.first)
        #expect(relaunched.isStale(first, now: now))
    }

    @Test func restoredCodexSnapshotStillTakesSparseUpdates() {
        let defaults = scratchDefaults()
        CodexQuotaStore(defaults: defaults, now: start).record(.object(["rateLimitsByLimitId": .object([
            "codex": .object(["primary": window(40, resetsAt: start.addingTimeInterval(3600))]),
        ])]), at: start)

        let relaunched = CodexQuotaStore(defaults: defaults, now: start)
        relaunched.record(.object(["rateLimits": .object([
            "primary": window(55, resetsAt: start.addingTimeInterval(3600)),
        ])]), at: start.addingTimeInterval(10))
        #expect(relaunched.windows.map(\.usedPercent) == [55])
        #expect(relaunched.windows.first?.bucketID == "codex")
    }

    @Test func codexWindowsZeroOnRestoreByResetTimeOrDuration() {
        func codexWindow(_ slot: CodexQuotaWindow.Slot, bucket: String, minutes: Int?, resetsAt: Date?) -> CodexQuotaWindow {
            CodexQuotaWindow(bucketID: bucket, bucketName: nil, slot: slot, usedPercent: 70, durationMinutes: minutes, resetsAt: resetsAt)
        }
        let pastReset = codexWindow(.primary, bucket: "a", minutes: 300, resetsAt: start.addingTimeInterval(3600))
        let futureReset = codexWindow(.secondary, bucket: "a", minutes: 10_080, resetsAt: start.addingTimeInterval(86400))
        let durationOnly = codexWindow(.primary, bucket: "b", minutes: 60, resetsAt: nil)
        let neither = codexWindow(.secondary, bucket: "b", minutes: nil, resetsAt: nil)
        let windows = [pastReset, futureReset, durationOnly, neither]
        let snapshot = CodexQuotaSnapshot(
            windows: windows,
            receivedAt: Dictionary(uniqueKeysWithValues: windows.map { ($0.id, start) })
        )

        let restored = snapshot.restored(now: start.addingTimeInterval(7200))

        #expect(restored.windows.map(\.usedPercent) == [0, 70, 0, 70])
        #expect(restored.windows[0].resetsAt == nil)
        #expect(restored.windows[0].durationMinutes == 300)
        #expect(restored.windows[1] == futureReset)
        #expect(restored.windows[3] == neither)
        #expect(restored.receivedAt == snapshot.receivedAt)
    }
}
