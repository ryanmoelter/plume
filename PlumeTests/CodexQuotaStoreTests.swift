import Foundation
import Testing
@testable import Plume

@MainActor
struct CodexQuotaStoreTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)
    private func window(_ percent: Int) -> JSONValue {
        .object(["usedPercent": .number(Double(percent)), "windowDurationMins": .number(300), "resetsAt": .number(start.timeIntervalSince1970 + 18_000)])
    }

    @Test func sparseReportsFromDifferentChatsShareOneAccountSnapshot() {
        let store = CodexQuotaStore()
        store.record(.object(["rateLimitsByLimitId": .object([
            "codex": .object(["primary": window(40)]),
            "spark": .object(["primary": window(0)])
        ])]), at: start)
        store.record(.object(["rateLimits": .object([
            "limitId": .string("codex"), "primary": window(55)
        ])]), at: start.addingTimeInterval(10))
        #expect(store.windows.count == 2)
        #expect(store.windows.first { $0.bucketID == "codex" }?.usedPercent == 55)
        #expect(store.windows.filter { $0.usedPercent > 0 }.count == 1)
    }

    @Test func sparseUpdateDoesNotMakeOtherBucketsFresh() throws {
        let store = CodexQuotaStore()
        store.record(.object(["rateLimitsByLimitId": .object([
            "codex": .object(["primary": window(40)]),
            "other": .object(["primary": window(25)])
        ])]), at: start)
        let now = start.addingTimeInterval(QuotaFreshness.staleAfter + 1)
        store.record(.object(["rateLimits": .object([
            "limitId": .string("codex"), "primary": window(40)
        ])]), at: now)
        let codex = try #require(store.windows.first { $0.bucketID == "codex" })
        let other = try #require(store.windows.first { $0.bucketID == "other" })
        #expect(!store.isStale(codex, now: now))
        #expect(store.isStale(other, now: now))
    }

    @Test func missingPayloadDoesNotRefreshAndExplicitNullRemovesWindow() throws {
        let store = CodexQuotaStore()
        store.record(.object(["rateLimits": .object(["primary": window(40)])]), at: start)
        let now = start.addingTimeInterval(QuotaFreshness.staleAfter + 1)
        store.record(.object([:]), at: now)
        let window = try #require(store.windows.first)
        #expect(store.isStale(window, now: now))
        store.record(.object(["rateLimits": .object(["primary": .null])]), at: now)
        #expect(store.windows.isEmpty)
    }

    @Test func elapsedPacingUsesActualCodexDurationAndPastResetsKeepUsage() throws {
        let store = CodexQuotaStore()
        store.record(.object(["rateLimits": .object(["primary": window(60)])]), at: start)
        let value = try #require(store.windows.first)
        #expect(QuotaFreshness.pacing(resetsAt: value.resetsAt, now: start.addingTimeInterval(9000), window: Double(value.durationMinutes ?? 0) * 60) == 0.5)
        #expect(QuotaFreshness.pacing(resetsAt: value.resetsAt, now: start.addingTimeInterval(18001), window: 18000) == nil)
        #expect(store.windows.first?.usedPercent == 60)
    }
}
