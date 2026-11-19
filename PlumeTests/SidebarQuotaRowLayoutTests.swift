import AppKit
import SwiftUI
import Testing
@testable import Plume

/// At the sidebar's default 240 pt width, the body-size Fable and credit
/// glyphs fit beside full 5h and 7d meters, alone or together. The "Show
/// usage credit" offer and its dismiss button have no room there, and wrap
/// together onto a second line that holds them unclipped.
@MainActor
struct SidebarQuotaRowLayoutTests {
    private let defaultSidebarWidth: CGFloat = 240

    enum Extra: Sendable { case none, offer, fable, credit, fableAndCredit }

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
        case .none, .offer:
            break
        }
        return (SidebarQuotaRow(quota: quota, settings: settings), { defaults.removePersistentDomain(forName: suite) })
    }

    @Test(arguments: [Extra.fable, .credit, .fableAndCredit])
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
        #expect(fitted.height == unbounded.height, "at 240 pt the row stays one line")
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

        // Line 2 starts where the meters do: past the row's padding, its
        // inset and the provider icon with its spacing.
        let offer = unbounded.width - size(metersOnly, width: nil).width - 8
        let lineStart = 2 * 12 + 2 * SidebarFooterMetrics.inset + 16 + 8
        #expect(lineStart + offer <= defaultSidebarWidth, "the offer needs \(offer) pt from \(lineStart) pt")
    }
}

/// Readings of different sizes share one line by their centres: a
/// body-size glyph sits on the middle of the meter block beside it, label
/// and bar together.
@MainActor
struct SidebarQuotaFlowAlignmentTests {
    private final class Frames {
        var meter: CGRect = .zero
        var glyph: CGRect = .zero
    }

    @Test func aBodyGlyphCentresOnTheMeterBlock() {
        let typography = Typography(bodySize: CGFloat(AppSettings.defaultChatFontSize))
        let frames = Frames()
        let flow = SidebarQuotaFlow(horizontalSpacing: 8, verticalSpacing: 4) {
            StatuslineMeterSegment(
                label: "5h",
                utilization: 0,
                resetsAt: nil,
                barWidth: StatuslineMeterWidth.sidebarShortQuota,
                readingAlignment: .leading
            )
            .font(typography.caption.font)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames.meter = $0 }
            Image(systemName: "f.circle")
                .font(typography.body.semibold)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames.glyph = $0 }
        }
        let host = NSHostingView(rootView: flow.fixedSize())
        host.frame = CGRect(x: 0, y: 0, width: 300, height: 100)
        host.layoutSubtreeIfNeeded()

        #expect(frames.meter.height > frames.glyph.height, "the meter block must be the taller, or this measures nothing")
        #expect(abs(frames.glyph.midY - frames.meter.midY) <= 1, "glyph centre \(frames.glyph.midY), meter centre \(frames.meter.midY)")
    }
}
