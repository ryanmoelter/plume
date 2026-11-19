import SwiftUI

/// The account's 5h and 7d quota, at the bottom of the sidebar, with the
/// Fable window and the usage-credit spend beside them once they apply.
///
/// The same reading a chat's statusline shows, in the one place that is not
/// about any single chat — the quota is the account's, so it belongs beside
/// Archive and Settings rather than inside a conversation.
///
/// Wider bars than the statusline's, since the footer has the room. Both
/// carry the pacing mark; the comparison is what makes the number actionable
/// rather than merely current.
///
/// The row holds its place before the first reading arrives, showing a dash
/// instead: the quota appears partway through a session, and a row that
/// materializes shifts every footer button under it.
struct SidebarQuotaRow: View, ThemedView {
    @Environment(\.theme) var theme
    @State private var quota: QuotaStore
    @State private var settings: AppSettings

    init(quota: QuotaStore = .shared, settings: AppSettings = .shared) {
        _quota = State(initialValue: quota)
        _settings = State(initialValue: settings)
    }

    var body: some View {
        content(quota.snapshot)
            .onAppear { quota.startTicking() }
    }

    @ViewBuilder
    private func content(_ snapshot: QuotaSnapshot?) -> some View {
        let windowsAreStale = snapshot.map {
            QuotaFreshness.isStale(receivedAt: $0.receivedAt, now: quota.now)
        } ?? false
        let rowIsStale = snapshot.map {
            QuotaFreshness.isStale(receivedAt: $0.lastHeardAt, now: quota.now)
        } ?? false
        let extras = SidebarQuotaExtras(snapshot: snapshot, alwaysShows: settings.alwaysShowsCreditAndFableQuota, now: quota.now)
        let windows = snapshot.flatMap { Self.hasWindows($0) ? $0 : nil }
        let showsOffer = !settings.readsClaudeUsage && !settings.dismissedClaudeUsageOffer

        HStack(alignment: .quotaFirstLine, spacing: 8) {
            AgentProviderIcon(provider: .claudeCode, size: 16)
                // A row with nothing to say reads as quiet as one gone stale.
                .opacity(rowIsStale || !(snapshot?.hasReading ?? false) ? colors.emphasis[.secondary] : 1)
            SidebarQuotaFlow(horizontalSpacing: 8, verticalSpacing: 4) {
                if let windows {
                    meters(windows, isStale: windowsAreStale)
                }
                extraReadings(snapshot, extras: extras)
                if windows == nil && !extras.showsAny {
                    noReading
                }
                if showsOffer { usageOffer }
            }
            Spacer(minLength: 0)
        }
        .animation(QuotaTransition.animation, value: presence(snapshot, extras: extras))
        .font(typography.caption.font)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .padding(.horizontal, SidebarFooterMetrics.inset)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Claude account quota")
        .plumeID(AccessibilityID.sidebarQuotaRow)
    }

    private var usageOffer: some View {
        Button("Show credit", action: acceptUsageOffer)
        .buttonStyle(.plain)
        .foregroundStyle(colors.foreground.opacity(colors.emphasis[.secondary]))
        .help("Show usage credit and the Fable quota here. Plume reads Claude Code's login from your Keychain to fetch them, so macOS asks once. Right-click to hide this.")
        .contextMenu {
            Button("Don't Show This", action: dismissUsageOffer)
        }
        .transition(.opacity)
        .plumeID(AccessibilityID.sidebarQuotaUsageOffer, invoke: acceptUsageOffer)
        .plumeMenuItem(AccessibilityID.sidebarQuotaUsageOfferDismiss, invoke: dismissUsageOffer)
    }

    private func acceptUsageOffer() {
        ClaudeUsagePoller.shared.setEnabled(true)
    }

    private func dismissUsageOffer() {
        settings.dismissedClaudeUsageOffer = true
    }

    private var noReading: some View {
        placeholder
            .accessibilityLabel("No quota reading yet")
            .transition(.opacity)
    }

    private static func hasWindows(_ snapshot: QuotaSnapshot) -> Bool {
        snapshot.rateLimit.fiveHour != nil || snapshot.rateLimit.sevenDay != nil
    }

    private func presence(_ snapshot: QuotaSnapshot?, extras: SidebarQuotaExtras) -> [Bool] {
        [
            snapshot != nil,
            snapshot?.rateLimit.fiveHour != nil,
            snapshot?.rateLimit.sevenDay != nil,
            extras.showsFable,
            extras.showsCredit,
            !settings.readsClaudeUsage && !settings.dismissedClaudeUsageOffer,
        ]
    }

    @ViewBuilder
    private func meters(_ snapshot: QuotaSnapshot, isStale: Bool) -> some View {
        Group {
            if let fiveHour = snapshot.rateLimit.fiveHour {
                StatuslineMeterSegment(
                    label: "5h",
                    utilization: fiveHour.utilization,
                    resetsAt: fiveHour.resetsAt,
                    now: quota.now,
                    isStale: isStale,
                    receivedAt: snapshot.receivedAt,
                    barWidth: StatuslineMeterWidth.sidebarShortQuota,
                    windowLength: QuotaWindowLength.fiveHour,
                    readingAlignment: .leading
                )
                .transition(.opacity)
            }
            if let sevenDay = snapshot.rateLimit.sevenDay {
                StatuslineMeterSegment(
                    label: "7d",
                    utilization: sevenDay.utilization,
                    resetsAt: sevenDay.resetsAt,
                    now: quota.now,
                    isStale: isStale,
                    receivedAt: snapshot.receivedAt,
                    barWidth: StatuslineMeterWidth.sidebarQuota,
                    windowLength: QuotaWindowLength.sevenDay,
                    readingAlignment: .leading
                )
                .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private func extraReadings(_ snapshot: QuotaSnapshot?, extras: SidebarQuotaExtras) -> some View {
        if extras.showsFable {
            fableReading(snapshot)
                .transition(.opacity)
        }
        if extras.showsCredit {
            creditReading(snapshot)
                .transition(.opacity)
        }
    }

    private func fableReading(_ snapshot: QuotaSnapshot?) -> some View {
        let fable = snapshot?.rateLimit.fable
        let isStale = snapshot.map { QuotaFreshness.isStale(receivedAt: $0.fableHeardAt, now: quota.now) } ?? false
        return HStack(spacing: 3) {
            Image(systemName: "f.circle")
                .foregroundStyle(colors.foreground.opacity(colors.emphasis[.secondary]))
                .accessibilityHidden(true)
            if let snapshot, let fable {
                StatuslineMeterSegment(
                    label: "Fable",
                    utilization: fable.utilization,
                    resetsAt: fable.resetsAt,
                    now: quota.now,
                    isStale: isStale,
                    receivedAt: snapshot.fableHeardAt,
                    barWidth: StatuslineMeterWidth.sidebarFableQuota,
                    windowLength: QuotaWindowLength.sevenDay,
                    readingAlignment: .leading
                )
            } else {
                placeholder.help("Fable weekly quota: no reading yet")
            }
        }
        .plumeID(
            AccessibilityID.sidebarQuotaFable,
            value: fable.map { SidebarQuotaSummary.percent($0.utilization) } ?? "none"
        )
    }

    private func creditReading(_ snapshot: QuotaSnapshot?) -> some View {
        let credit = snapshot?.credit
        let used = credit?.usedCents.map { UsageCreditFormat.amount(minorUnits: $0, currency: credit?.currency) }
        let isStale = credit != nil && QuotaFreshness.isCreditStale(receivedAt: snapshot?.creditReceivedAt, now: quota.now)
        return HStack(spacing: 3) {
            Image(systemName: "dollarsign.circle")
                .foregroundStyle(colors.foreground.opacity(colors.emphasis[.secondary]))
                .accessibilityHidden(true)
            if let used {
                Text(used)
                    .foregroundStyle(colors.foreground.opacity(colors.emphasis[.secondary]))
                    .monospacedDigit()
            } else {
                placeholder
            }
        }
        .opacity(isStale ? colors.emphasis[.secondary] : 1)
        .help(UsageCreditFormat.tooltip(credit))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Usage credits")
        .accessibilityValue(UsageCreditFormat.tooltip(credit))
        .plumeID(AccessibilityID.sidebarQuotaCredit, value: used.map { isStale ? "\($0) stale" : $0 } ?? "none")
    }

    private var placeholder: some View {
        Text("\u{2014}")
            .foregroundStyle(colors.foreground.opacity(colors.emphasis[.secondary]))
    }
}

/// Which of the sidebar's optional readings show: each only once it has
/// something to say, unless the setting forces both on.
struct SidebarQuotaExtras: Equatable {
    let showsFable: Bool
    let showsCredit: Bool

    var showsAny: Bool { showsFable || showsCredit }

    init(snapshot: QuotaSnapshot?, alwaysShows: Bool, now: Date) {
        showsFable = alwaysShows || (snapshot?.rateLimit.fable?.utilization ?? 0) > 0
        showsCredit = alwaysShows || Self.creditIsRelevant(snapshot, now: now)
    }

    private static func creditIsRelevant(_ snapshot: QuotaSnapshot?, now: Date) -> Bool {
        guard let snapshot, let credit = snapshot.credit else { return false }
        let isSpendingOverage = snapshot.rateLimit.isUsingOverage
            && now.timeIntervalSince(snapshot.receivedAt) <= ClaudeUsagePollSchedule.overLimitReadingMaxAge
        if isSpendingOverage { return true }
        return (credit.usedCents ?? 0) > 0
    }
}

enum SidebarQuotaSummary {
    /// Clamped, since the value comes off the wire and `Int.init` traps on
    /// anything out of range.
    static func percent(_ utilization: Double) -> String {
        guard let whole = Int(exactly: (min(max(utilization, 0), 9.99) * 100).rounded()) else { return "—" }
        return "\(whole)%"
    }
}

/// Lays the row's readings out left to right and wraps whatever doesn't fit
/// onto the next line, so a narrow sidebar shows every reading instead of
/// dropping some.
struct SidebarQuotaFlow: Layout {
    var horizontalSpacing: CGFloat
    var verticalSpacing: CGFloat

    private struct Line {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func lines(for subviews: Subviews, maxWidth: CGFloat?) -> (lines: [Line], sizes: [CGSize]) {
        let limit = maxWidth ?? .infinity
        let sizes = subviews.map { subview in
            let ideal = subview.sizeThatFits(.unspecified)
            return ideal.width > limit ? subview.sizeThatFits(ProposedViewSize(width: limit, height: nil)) : ideal
        }
        var lines: [Line] = []
        var line = Line()
        for (index, size) in sizes.enumerated() where size.width > 0 || size.height > 0 {
            let width = line.indices.isEmpty ? size.width : line.width + horizontalSpacing + size.width
            if !line.indices.isEmpty && width > limit {
                lines.append(line)
                line = Line(indices: [index], width: size.width, height: size.height)
            } else {
                line.indices.append(index)
                line.width = width
                line.height = max(line.height, size.height)
            }
        }
        if !line.indices.isEmpty { lines.append(line) }
        return (lines, sizes)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = lines(for: subviews, maxWidth: proposal.width).lines
        let height = lines.map(\.height).reduce(0, +) + verticalSpacing * CGFloat(max(lines.count - 1, 0))
        return CGSize(width: lines.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (lines, sizes) = lines(for: subviews, maxWidth: bounds.width)
        var y = bounds.minY
        for line in lines {
            var x = bounds.minX
            for index in line.indices {
                let size = sizes[index]
                subviews[index].place(
                    at: CGPoint(x: x, y: y + line.height / 2),
                    anchor: .leading,
                    proposal: ProposedViewSize(size)
                )
                x += size.width + horizontalSpacing
            }
            y += line.height + verticalSpacing
        }
    }

    /// Lines up the provider icon beside the row with the first line, not the
    /// middle of a wrapped row.
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? {
        guard guide == .quotaFirstLine, let first = lines(for: subviews, maxWidth: bounds.width).lines.first else { return nil }
        return first.height / 2
    }
}

nonisolated extension VerticalAlignment {
    private enum QuotaFirstLine: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat { context[VerticalAlignment.center] }
    }

    static let quotaFirstLine = VerticalAlignment(QuotaFirstLine.self)
}

enum UsageCreditFormat {
    private static var formatters: [String: NumberFormatter] = [:]

    /// Keyed by currency and locale; a view asks on every body pass.
    static func formatter(currency: String?, locale: Locale = .current) -> NumberFormatter {
        let code = currency?.uppercased() ?? "USD"
        let key = "\(code)|\(locale.identifier)"
        if let cached = formatters[key] { return cached }
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        formatter.minimumFractionDigits = minorUnitDigits(currency: code)
        formatter.maximumFractionDigits = minorUnitDigits(currency: code)
        formatters[key] = formatter
        return formatter
    }

    /// ISO 4217's minor-unit exponent: 2 for USD, 0 for JPY.
    static func minorUnitDigits(currency: String) -> Int {
        let probe = NumberFormatter()
        probe.locale = Locale(identifier: "en_US_POSIX")
        probe.numberStyle = .currencyISOCode
        probe.currencyCode = currency
        return probe.maximumFractionDigits
    }

    static func amount(minorUnits: Int, currency: String?, locale: Locale = .current) -> String {
        let formatter = formatter(currency: currency, locale: locale)
        let value = Decimal(minorUnits) / pow(Decimal(10), formatter.maximumFractionDigits)
        return formatter.string(from: value as NSDecimalNumber) ?? "\(minorUnits)"
    }

    static func tooltip(_ credit: UsageCredit?, locale: Locale = .current) -> String {
        guard let credit, let used = credit.usedCents else { return "Usage credits: no reading yet" }
        let format = { (units: Int) in amount(minorUnits: units, currency: credit.currency, locale: locale) }
        var lines = ["Usage credits: \(format(used)) used this month"]
        if let limit = credit.limitCents {
            lines.append("Monthly limit: \(format(limit))")
        } else {
            lines.append("No monthly limit")
        }
        if let remaining = credit.remainingCents {
            lines.append("\(format(remaining)) left")
        }
        return lines.joined(separator: "\n")
    }
}

/// Keep the Codex row visible while installed, even before its first reading.
struct SidebarCodexQuotaRow: View, ThemedView {
    @Environment(\.theme) var theme
    @State private var quota = CodexQuotaStore.shared

    var body: some View {
        HStack(spacing: 8) {
            AgentProviderIcon(provider: .codex, size: 16)
                .opacity(quota.windows.isEmpty ? colors.emphasis[.secondary] : 1)
            if quota.windows.contains(where: { $0.usedPercent > 0 }) {
                ViewThatFits(in: .horizontal) {
                    CodexQuotaStrip(windows: quota.windows, sidebar: true)
                    CodexQuotaStrip(windows: quota.windows, layout: .stacked, sidebar: true)
                }
                .transition(.opacity)
            } else {
                Text("—")
                    .foregroundStyle(colors.foreground.opacity(colors.emphasis[.secondary]))
                    .accessibilityLabel(quota.windows.isEmpty ? "No quota reading yet" : "No quota usage")
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
        }
        .animation(QuotaTransition.animation, value: quota.windows.filter { $0.usedPercent > 0 }.map(\.id))
        .font(typography.caption.font)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .padding(.horizontal, SidebarFooterMetrics.inset)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Codex account quota")
        .plumeID("sidebar-codex-quota-row")
    }
}
