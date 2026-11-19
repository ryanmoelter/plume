import SwiftUI

/// The Fable window and the usage credit as circle glyphs, each opening its
/// own detail popover. The sidebar's quota row and the chat statusline both
/// draw them, under their own IDs.
struct ClaudeQuotaGlyphs: View, ThemedView {
    struct IDs {
        let fable: String
        let fablePopover: String
        let credit: String
        let creditPopover: String

        static let sidebar = IDs(
            fable: AccessibilityID.sidebarQuotaFable,
            fablePopover: AccessibilityID.sidebarQuotaFablePopover,
            credit: AccessibilityID.sidebarQuotaCredit,
            creditPopover: AccessibilityID.sidebarQuotaCreditPopover
        )
        static let statusline = IDs(
            fable: AccessibilityID.statuslineFable,
            fablePopover: AccessibilityID.statuslineFablePopover,
            credit: AccessibilityID.statuslineCredit,
            creditPopover: AccessibilityID.statuslineCreditPopover
        )
    }

    @Environment(\.theme) var theme

    let snapshot: QuotaSnapshot?
    let extras: SidebarQuotaExtras
    let now: Date
    let isChecking: Bool
    let ids: IDs

    var body: some View {
        if extras.showsFable {
            fableReading
                .transition(.opacity)
        }
        if extras.showsCredit {
            creditReading
                .transition(.opacity)
        }
    }

    private var fableReading: some View {
        let fable = snapshot?.rateLimit.fable
        let isStale = snapshot.map { QuotaFreshness.isStale(receivedAt: $0.fableHeardAt, now: now) } ?? false
        let summary = fable.map {
            QuotaDescription.summary(
                provider: "Claude",
                timeframe: "Fable",
                utilization: $0.utilization,
                resetsAt: $0.resetsAt,
                windowLength: QuotaWindowLength.sevenDay,
                receivedAt: snapshot?.fableHeardAt,
                now: now
            )
        }
        let percent = (fable?.utilization ?? 0) * 100
        return SidebarQuotaGlyph(
            symbol: "f.circle",
            fraction: StatuslineMeterMath.fraction(percent: percent),
            fill: glyphFill(percent: percent),
            isStale: isStale,
            isPulsing: isChecking,
            help: summary?.text ?? "Fable weekly quota: no reading yet",
            accessibilityLabel: "Fable weekly quota",
            id: ids.fable,
            value: fable.map { SidebarQuotaSummary.percent($0.utilization) } ?? "none",
            popoverID: ids.fablePopover,
            popoverValue: summary?.lines.joined(separator: "; ") ?? "none"
        ) {
            if let summary {
                QuotaDetailsPopover(summaries: [summary])
            } else {
                Text("Fable weekly quota: no reading yet").usagePopoverStyle(typography: typography)
            }
        }
    }

    private var creditReading: some View {
        let credit = snapshot?.credit
        let used = credit?.usedCents.map { UsageCreditFormat.amount(minorUnits: $0, currency: credit?.currency) }
        let isStale = credit != nil && QuotaFreshness.isCreditStale(receivedAt: snapshot?.creditReceivedAt, now: now)
        let fraction = UsageCreditFormat.fraction(credit)
        return SidebarQuotaGlyph(
            symbol: "dollarsign.circle",
            fraction: fraction ?? 0,
            fill: glyphFill(percent: (fraction ?? 0) * 100),
            isStale: isStale,
            isPulsing: isChecking,
            help: UsageCreditFormat.tooltip(credit),
            accessibilityLabel: "Usage credits",
            id: ids.credit,
            value: used.map { isStale ? "\($0) stale" : $0 } ?? "none",
            popoverID: ids.creditPopover,
            popoverValue: UsageCreditFormat.detailLines(credit).joined(separator: "; ")
        ) {
            UsageCreditPopover(credit: credit, fraction: fraction)
        }
    }

    /// Full foreground rather than the meters' secondary, so the drawn arc
    /// stands clear of the track at a glance.
    private func glyphFill(percent: Double) -> Color {
        switch StatuslineAttention.attention(percent: percent) {
        case .neutral: colors.foreground
        case let attention: StatuslineColors.meter(for: attention, colors: colors)
        }
    }
}
