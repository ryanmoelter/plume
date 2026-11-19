import SwiftUI

/// One section of the stacked popover, below the context window.
enum UsagePopoverSection: Equatable {
    case quota(QuotaWindowSummary)
    case credit

    /// The credit is spent on the Claude account, so it closes Claude's
    /// sections, ahead of Codex's.
    static func ordered(
        claude: [QuotaWindowSummary],
        fable: QuotaWindowSummary?,
        showsCredit: Bool,
        codex: [QuotaWindowSummary]
    ) -> [UsagePopoverSection] {
        (claude + [fable].compactMap { $0 }).map(Self.quota)
            + (showsCredit ? [.credit] : [])
            + codex.map(Self.quota)
    }
}

/// The stacked statusline's click-through: the context window and every
/// quota window together, each in the same shape as a single quota's popover.
struct StatuslineUsagePopover: View, ThemedView {
    @Environment(\.theme) var theme

    let contextUsedTokens: Int?
    let contextMaxTokens: Int?
    let sections: [UsagePopoverSection]
    var credit: UsageCredit?
    var isCreditStale = false
    /// Asked for a fresh breakdown each time the popover opens.
    let headlessSession: HeadlessSession?
    var compact: CompactAction?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if hasContext {
                ContextUsageSection(
                    usedTokens: contextUsedTokens,
                    maxTokens: contextMaxTokens,
                    breakdown: headlessSession?.contextBreakdown,
                    compact: compact
                )
            }
            ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                if index > 0 || hasContext { Divider() }
                switch section {
                case .quota(let summary):
                    QuotaSummarySection(summary: summary)
                case .credit:
                    UsageCreditSection(credit: credit, isStale: isCreditStale)
                        .plumeID(
                            AccessibilityID.statuslineUsageCredit,
                            value: UsageCreditFormat.controlValue(credit, isStale: isCreditStale)
                        )
                }
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
    var compact: CompactAction?

    var body: some View {
        ContextUsageSection(
            usedTokens: contextUsedTokens,
            maxTokens: contextMaxTokens,
            breakdown: headlessSession?.contextBreakdown,
            compact: compact
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
    var compact: CompactAction?

    @Environment(\.dismiss) private var dismiss

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
            if let compact { compactButton(compact) }
        }
    }

    private func compactButton(_ compact: CompactAction) -> some View {
        var reason: String?
        if case .unavailable(let why) = compact.availability { reason = why }
        return Button("Compact") {
            dismiss()
            compact.run()
        }
        .plumeID(AccessibilityID.statuslineCompactButton)
        .disabled(reason != nil)
        .help(reason ?? "Summarize the conversation to free up context")
        .padding(.top, 6)
    }
}
