import SwiftUI

/// The stacked statusline's click-through: the context window and every
/// quota window together, each in the same shape as a single quota's popover.
struct StatuslineUsagePopover: View, ThemedView {
    @Environment(\.theme) var theme

    let contextUsedTokens: Int?
    let contextMaxTokens: Int?
    let quotaSummaries: [QuotaWindowSummary]
    /// Asked for a fresh breakdown each time the popover opens.
    let headlessSession: HeadlessSession?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if hasContext {
                ContextUsageSection(
                    usedTokens: contextUsedTokens,
                    maxTokens: contextMaxTokens,
                    breakdown: headlessSession?.contextBreakdown
                )
            }
            ForEach(Array(quotaSummaries.enumerated()), id: \.offset) { index, summary in
                if index > 0 || hasContext { Divider() }
                QuotaSummarySection(summary: summary)
            }
        }
        .usagePopoverStyle(typography: typography)
        .plumeID(AccessibilityID.statuslineUsagePopover)
        .onAppear { headlessSession?.requestContextUsage() }
    }

    private var hasContext: Bool { contextUsedTokens != nil || contextMaxTokens != nil }
}

/// The context bar's click-through in the wide layout: the context section
/// alone.
struct ContextDetailsPopover: View, ThemedView {
    @Environment(\.theme) var theme

    let contextUsedTokens: Int?
    let contextMaxTokens: Int?
    /// Asked for a fresh breakdown each time the popover opens.
    let headlessSession: HeadlessSession?

    var body: some View {
        ContextUsageSection(
            usedTokens: contextUsedTokens,
            maxTokens: contextMaxTokens,
            breakdown: headlessSession?.contextBreakdown
        )
        .usagePopoverStyle(typography: typography)
        .onAppear { headlessSession?.requestContextUsage() }
    }
}

/// The context window's section of a usage popover, with what fills it when
/// the session can say.
struct ContextUsageSection: View, ThemedView {
    @Environment(\.theme) var theme

    let usedTokens: Int?
    let maxTokens: Int?
    let breakdown: ContextUsageBreakdown?

    private var percent: Double? {
        guard let usedTokens, let maxTokens, maxTokens > 0 else { return nil }
        return Double(usedTokens) / Double(maxTokens) * 100
    }

    var body: some View {
        let attention = StatuslineAttention.attention(contextTokens: usedTokens, percent: percent)
        VStack(alignment: .leading, spacing: 2) {
            Text("Context window").font(.headline)
            MeterView(
                fraction: StatuslineMeterMath.fraction(percent: percent),
                color: StatuslineColors.meter(for: attention, colors: colors),
                attention: attention,
                height: PacingMark.barHeight * 2
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            if let percent {
                Text("\(Int(percent.rounded()))%").bold() + Text(" used")
            }
            Text(usedTokens.map(TokenCount.formatted) ?? "0").bold()
                + Text(" of \(maxTokens.map(TokenCount.formatted) ?? "—") tokens")
            if let categories = breakdown?.displayedCategories, !categories.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                    ForEach(Array(categories.enumerated()), id: \.offset) { _, category in
                        let level: Emphasis = category.kind == "buffer" ? .subtle : .secondary
                        GridRow {
                            Text(category.name)
                            Text(TokenCount.formatted(category.tokens))
                                .monospacedDigit()
                                .gridColumnAlignment(.trailing)
                        }
                        .foregroundStyle(colors.foreground.opacity(colors.emphasis[level]))
                    }
                }
                .padding(.top, 4)
            }
        }
    }
}
