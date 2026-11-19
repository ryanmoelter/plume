import AppKit
import SwiftUI
import Testing
@testable import Plume

/// At the sidebar's default 240 pt width, the Fable and credit glyphs fit
/// beside full 5h and 7d meters, alone or together, and so does a credit
/// glyph with a two-digit amount. The "Show credit" offer has no room there
/// and wraps onto a second line rather than disappearing.
@MainActor
struct SidebarQuotaRowLayoutTests {
    private let defaultSidebarWidth: CGFloat = 240

    enum Extra: Sendable { case none, offer, fable, credit, fableAndCredit, creditWithoutLimit }

    /// A nil width measures the ideal: everything on one line.
    private func size(_ view: some View, width: CGFloat?) -> CGSize {
        let bounds = CGSize(width: width ?? 10_000, height: 10_000)
        return width == nil
            ? NSHostingController(rootView: view.fixedSize()).sizeThatFits(in: bounds)
            : NSHostingController(rootView: view).sizeThatFits(in: bounds)
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
        let fable = RateLimitInfo.Window(utilization: 1, resetsAt: now.addingTimeInterval(6.5 * 86400))
        let credit = UsageCredit(usedCents: 123_456, limitCents: 500_000)
        switch extra {
        case .fable:
            quota.record(ClaudeUsageReading(fable: fable), at: now)
        case .credit:
            quota.record(ClaudeUsageReading(credit: credit), at: now)
        case .fableAndCredit:
            quota.record(ClaudeUsageReading(fable: fable, credit: credit), at: now)
        case .creditWithoutLimit:
            quota.record(ClaudeUsageReading(credit: UsageCredit(usedCents: 1240)), at: now)
        case .none, .offer:
            break
        }
        return (SidebarQuotaRow(quota: quota, settings: settings), { defaults.removePersistentDomain(forName: suite) })
    }

    @Test(arguments: [Extra.fable, .credit, .fableAndCredit, .creditWithoutLimit])
    func theGlyphsFitBesideTheMetersAtTheDefaultWidth(_ extra: Extra) throws {
        let (metersOnly, cleanMeters) = try row(.none)
        defer { cleanMeters() }
        let (withExtra, cleanExtra) = try row(extra)
        defer { cleanExtra() }

        let meters = size(metersOnly, width: nil)
        let unbounded = size(withExtra, width: nil)
        let fitted = size(withExtra, width: defaultSidebarWidth)

        #expect(unbounded.width > meters.width, "the glyph must add width, or this measures nothing")
        #expect(unbounded.width <= defaultSidebarWidth, "row with the glyph is \(unbounded.width) pt")
        #expect(fitted.height == meters.height)
    }

    @Test func theOfferWrapsBelowTheMetersAtTheDefaultWidth() throws {
        let (metersOnly, cleanMeters) = try row(.none)
        defer { cleanMeters() }
        let (withOffer, cleanOffer) = try row(.offer)
        defer { cleanOffer() }

        let oneLine = size(metersOnly, width: defaultSidebarWidth)
        let unbounded = size(withOffer, width: nil)
        let wrapped = size(withOffer, width: defaultSidebarWidth)

        #expect(oneLine.width <= defaultSidebarWidth)
        #expect(unbounded.height == oneLine.height, "unbounded, the offer sits on the first line")
        #expect(unbounded.width > defaultSidebarWidth, "the offer must not fit beside the meters, or this measures nothing")
        #expect(wrapped.width <= defaultSidebarWidth)
        #expect(wrapped.height > oneLine.height, "the offer moves onto a second line")
    }
}
