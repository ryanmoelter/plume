import Foundation
import Testing
@testable import Plume

/// A `rate_limit_event` from a headless Claude Code session lands in the
/// account-wide `QuotaStore` the statusline and sidebar read.
@MainActor
struct HeadlessSessionQuotaTests {
    /// Captured from `claude -p --output-format stream-json` on Claude Code 2.1.280.
    private let capturedLine = #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1790387400,"rateLimitType":"five_hour","overageStatus":"rejected","overageDisabledReason":"org_level_disabled_until","isUsingOverage":false,"unifiedWindows":{"five_hour":{"utilization":0.02,"resetsAt":1790387400},"seven_day":{"utilization":0.2,"resetsAt":1790564400}}},"uuid":"59a7d833-7e88-4f0e-88d1-693daf6054f4","session_id":"ef6991ec-b324-40c8-ac80-cf2d8982ebf7"}"#

    @Test func decodesTheCapturedEvent() throws {
        let message = try #require(StreamJSONDecoder.decode(line: capturedLine))
        guard case .rateLimit(let info) = message else {
            Issue.record("Expected .rateLimit, got \(message)")
            return
        }
        #expect(info.fiveHour == .init(utilization: 0.02, resetsAt: Date(timeIntervalSince1970: 1790387400)))
        #expect(info.sevenDay == .init(utilization: 0.2, resetsAt: Date(timeIntervalSince1970: 1790564400)))
        #expect(!info.isUsingOverage)
    }

    @Test func sessionRecordsTheEventInTheQuotaStore() throws {
        let store = QuotaStore()
        let session = HeadlessSession(tabID: UUID(), taskID: UUID(), quotaStore: store)
        let message = try #require(StreamJSONDecoder.decode(line: capturedLine))

        session.handle(message)

        #expect(store.snapshot?.rateLimit.fiveHour?.utilization == 0.02)
        #expect(store.snapshot?.rateLimit.sevenDay?.utilization == 0.2)
    }
}
