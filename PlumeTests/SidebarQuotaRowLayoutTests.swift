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

    /// A nil width measures the ideal: everything on one line. A width pins
    /// the row to it, the way the sidebar does.
    private func size(_ view: some View, width: CGFloat?) -> CGSize {
        let bounds = CGSize(width: width ?? 10_000, height: 10_000)
        return if let width {
            NSHostingController(rootView: view.frame(width: width)).sizeThatFits(in: bounds)
        } else {
            NSHostingController(rootView: view.fixedSize()).sizeThatFits(in: bounds)
        }
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

    /// The flow gets the row's width less 16 pt of padding each side, the
    /// Keep Awake chevron's trailing inset, and the icon with its spacing.
    @Test func theFlowGetsTheRowsFullWidth() throws {
        let (withGlyphs, clean) = try row(.fableAndCredit)
        defer { clean() }
        let unbounded = size(withGlyphs, width: nil)
        let flowAtDefault = defaultSidebarWidth - 2 * (12 + SidebarFooterMetrics.inset) - 16 - 8
        #expect(flowAtDefault == 184)
        #expect(unbounded.width - (2 * (12 + SidebarFooterMetrics.inset) + 16 + 8) < flowAtDefault, "meters, Fable and credit need less than the flow's width")
    }

    @Test func wrappedGlyphsSitBelowTheMetersWithLineSpacing() throws {
        let narrow: CGFloat = 200
        let (metersOnly, cleanMeters) = try row(.none)
        defer { cleanMeters() }
        let (withGlyphs, cleanGlyphs) = try row(.fableAndCredit)
        defer { cleanGlyphs() }
        let meters = size(metersOnly, width: narrow)
        let wrapped = size(withGlyphs, width: narrow)
        #expect(meters.height == size(metersOnly, width: nil).height, "the meters must fit on one line, or this measures nothing")
        #expect(wrapped.height >= meters.height + SidebarQuotaFlow.wrappedLineSpacing + 10, "meters \(meters.height), wrapped \(wrapped.height)")
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

    @Test func everyWrappedLineGetsTheSameSpacingAboveIt() {
        let spacing = SidebarQuotaFlow.wrappedLineSpacing
        let flow = SidebarQuotaFlow(horizontalSpacing: 8) {
            Color.clear.frame(width: 100, height: 10)
            Color.clear.frame(width: 100, height: 20)
            Color.clear.frame(width: 100, height: 16)
        }
        let oneLine = NSHostingController(rootView: flow.frame(width: 400)).sizeThatFits(in: CGSize(width: 400, height: 1000))
        let wrapped = NSHostingController(rootView: flow.frame(width: 150)).sizeThatFits(in: CGSize(width: 150, height: 1000))
        #expect(spacing >= 8, "a bordered button needs room below the meters")
        #expect(oneLine.height == 20)
        #expect(wrapped.height == 10 + 20 + 16 + 2 * spacing)
    }

    @Test func aBodyGlyphCentresOnTheMeterBlock() {
        let typography = Typography(bodySize: CGFloat(AppSettings.defaultChatFontSize))
        let frames = Frames()
        let flow = SidebarQuotaFlow(horizontalSpacing: 8) {
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
