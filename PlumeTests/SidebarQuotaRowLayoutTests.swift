import AppKit
import SwiftUI
import Testing
@testable import Plume

/// At the sidebar's default 240 pt width, full 5h and 7d meters leave no room
/// beside them, so the Fable reading, the credit reading and the "Show
/// credit" offer each wrap onto a second line rather than disappearing.
@MainActor
struct SidebarQuotaRowLayoutTests {
    private let defaultSidebarWidth: CGFloat = 240

    enum Extra: Sendable { case none, offer, fable, credit }

    private func size(_ view: some View, width: CGFloat?) -> CGSize {
        NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: width ?? 10_000, height: 10_000))
    }

    private func row(_ extra: Extra) throws -> (SidebarQuotaRow, () -> Void) {
        let suite = "SidebarQuotaRowLayoutTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let settings = AppSettings(defaults: defaults, domainName: suite)
        settings.dismissedClaudeUsageOffer = extra != .offer
        let now = Date()
        let quota = QuotaStore(now: now)
        // The widest readings a meter shows: a day-scale countdown and 100%.
        quota.record(
            RateLimitInfo(
                fiveHour: .init(utilization: 1, resetsAt: now.addingTimeInterval(4.5 * 3600)),
                sevenDay: .init(utilization: 1, resetsAt: now.addingTimeInterval(6.5 * 86400)),
                isUsingOverage: false
            ),
            at: now
        )
        switch extra {
        case .fable:
            quota.record(ClaudeUsageReading(fable: .init(utilization: 1, resetsAt: now.addingTimeInterval(6.5 * 86400))), at: now)
        case .credit:
            quota.record(ClaudeUsageReading(credit: UsageCredit(usedCents: 123_456, limitCents: 500_000)), at: now)
        case .none, .offer:
            break
        }
        return (SidebarQuotaRow(quota: quota, settings: settings), { defaults.removePersistentDomain(forName: suite) })
    }

    @Test(arguments: [Extra.offer, .fable, .credit])
    func theExtraWrapsBelowTheMetersAtTheDefaultWidth(_ extra: Extra) throws {
        let (metersOnly, cleanMeters) = try row(.none)
        defer { cleanMeters() }
        let (withExtra, cleanExtra) = try row(extra)
        defer { cleanExtra() }

        let oneLine = size(metersOnly, width: defaultSidebarWidth)
        let unbounded = size(withExtra, width: nil)
        let wrapped = size(withExtra, width: defaultSidebarWidth)

        #expect(oneLine.width <= defaultSidebarWidth)
        #expect(unbounded.height == oneLine.height, "unbounded, the extra sits on the first line")
        #expect(unbounded.width > defaultSidebarWidth, "the extra must not fit beside the meters, or this measures nothing")
        #expect(wrapped.width <= defaultSidebarWidth)
        #expect(wrapped.height > oneLine.height, "the extra moves onto a second line")
    }
}
