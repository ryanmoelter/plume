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
    @State private var poller: ClaudeUsagePoller

    init(quota: QuotaStore = .shared, settings: AppSettings = .shared, poller: ClaudeUsagePoller = .shared) {
        _quota = State(initialValue: quota)
        _settings = State(initialValue: settings)
        _poller = State(initialValue: poller)
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
        let isChecking = poller.status == .checking

        HStack(alignment: .quotaFirstLine, spacing: 8) {
            AgentProviderIcon(provider: .claudeCode, size: 16)
                // A row with nothing to say reads as quiet as one gone stale.
                .opacity(rowIsStale || !(snapshot?.hasReading ?? false) ? colors.emphasis[.secondary] : 1)
            SidebarQuotaFlow(horizontalSpacing: 8) {
                if let windows {
                    meters(windows, isStale: windowsAreStale)
                }
                ClaudeQuotaGlyphs(snapshot: snapshot, extras: extras, now: quota.now, isChecking: isChecking, ids: .sidebar)
                if windows == nil && !extras.showsAny {
                    noReading
                }
                // With no glyph to pulse, a spinner shows the check instead.
                if isChecking && !extras.showsAny {
                    ProgressView()
                        .controlSize(.mini)
                        .help("Reading usage credit and the Fable quota…")
                }
                if case .failed(let reason) = poller.status {
                    placeholder
                        .opacity(colors.emphasis[.secondary])
                        .help(reason)
                        .accessibilityLabel(reason)
                        .transition(.opacity)
                }
            }
            // A trailing Spacer would split the free width with the flow and
            // wrap it well short of the footer chevrons' edge.
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .animation(QuotaTransition.animation, value: presence(snapshot, extras: extras))
        .font(typography.caption.font)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .padding(.horizontal, SidebarFooterMetrics.inset)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Claude account quota")
        .plumeID(AccessibilityID.sidebarQuotaRow, value: poller.status.description)
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
            poller.status != .idle,
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

    private var placeholder: some View {
        Text("\u{2014}")
            .foregroundStyle(colors.foreground.opacity(colors.emphasis[.secondary]))
    }
}

/// Which of the sidebar's optional readings show: each only once it has
/// something to say, unless the setting forces both on. Credit with no
/// monthly limit never shows: its glyph has nothing to fill toward.
struct SidebarQuotaExtras: Equatable {
    let showsFable: Bool
    let showsCredit: Bool

    var showsAny: Bool { showsFable || showsCredit }

    init(snapshot: QuotaSnapshot?, alwaysShows: Bool, now: Date) {
        showsFable = alwaysShows || (snapshot?.rateLimit.fable?.utilization ?? 0) > 0
        let hasNoLimit = snapshot?.credit.map { $0.limitCents == nil } ?? false
        showsCredit = !hasNoLimit && (alwaysShows || Self.creditIsRelevant(snapshot, now: now))
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

/// A reading drawn as its circle symbol, the circle filling with
/// `fraction` through the symbol's variable draw, over a faint full circle as
/// its track. Clicking it opens the detail popover.
struct SidebarQuotaGlyph<Detail: View>: View, ThemedView {
    @Environment(\.theme) var theme
    @State private var showingDetails = false

    let symbol: String
    let fraction: Double
    let fill: Color
    let isStale: Bool
    let isPulsing: Bool
    let help: String
    let accessibilityLabel: String
    let id: String
    let value: String
    let popoverID: String
    let popoverValue: String
    @ViewBuilder let detail: () -> Detail

    var body: some View {
        Button(action: showDetails) {
            ZStack {
                Image(systemName: symbol)
                    .foregroundStyle(colors.foreground.opacity(colors.emphasis[.backgroundTint]))
                Image(systemName: symbol, variableValue: fraction)
                    .symbolVariableValueMode(.draw)
                    .foregroundStyle(fill)
            }
            // Body size and semibold, since a caption-size hairline arc
            // barely separates from its track.
            .font(typography.body.semibold)
            .opacity(isStale ? colors.emphasis[.secondary] : 1)
            .modifier(QuotaPulse(isActive: isPulsing))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(help)
        .popover(isPresented: $showingDetails) {
            detail()
                .environment(\.theme, theme)
                .plumeID(popoverID, value: popoverValue)
        }
        .plumeID(id, value: value, invoke: showDetails)
    }

    private func showDetails() {
        showingDetails = true
    }
}

/// Fades a reading in and out while a fetch for it is in flight. Driven by
/// a `TimelineView` rather than a repeating symbol effect, which would
/// re-rasterize the glyph every frame on the main thread; it exists only
/// while active.
struct QuotaPulse: ViewModifier {
    let isActive: Bool

    static let step: TimeInterval = 0.6
    private static let epoch = Date(timeIntervalSinceReferenceDate: 0)

    func body(content: Content) -> some View {
        if isActive {
            TimelineView(.periodic(from: Self.epoch, by: Self.step)) { context in
                let isDim = Int(context.date.timeIntervalSince(Self.epoch) / Self.step) % 2 == 1
                content
                    .opacity(isDim ? 0.35 : 1)
                    .animation(.easeInOut(duration: Self.step), value: isDim)
            }
        } else {
            content
        }
    }
}

/// The credit reading's click-through: spend against the monthly limit.
struct UsageCreditPopover: View, ThemedView {
    @Environment(\.theme) var theme

    let credit: UsageCredit?
    var isStale = false

    var body: some View {
        UsageCreditSection(credit: credit, isStale: isStale)
            .usagePopoverStyle(typography: typography)
    }
}

/// The credit reading's section of a usage popover.
struct UsageCreditSection: View, ThemedView {
    @Environment(\.theme) var theme

    let credit: UsageCredit?
    var isStale = false

    var body: some View {
        let fraction = UsageCreditFormat.fraction(credit)
        VStack(alignment: .leading, spacing: 2) {
            Text("Usage credits").font(.headline)
            if let fraction {
                let attention = StatuslineAttention.attention(percent: fraction * 100)
                MeterView(
                    fraction: fraction,
                    color: StatuslineColors.meter(for: attention, colors: colors),
                    attention: attention,
                    pacing: UsageCreditFormat.pacing(credit, now: .now),
                    isStale: isStale,
                    height: PacingMark.barHeight * 2
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            ForEach(UsageCreditFormat.detailLines(credit), id: \.self) { Text($0) }
                .opacity(isStale ? colors.emphasis[.secondary] : 1)
        }
    }
}

/// Lays the row's readings out left to right and wraps whatever doesn't fit
/// onto the next line, so a narrow sidebar shows every reading instead of
/// dropping some.
struct SidebarQuotaFlow: Layout {
    var horizontalSpacing: CGFloat
    /// Room above every line after the first, so a body-size glyph on a
    /// wrapped line clears the meters.
    var verticalSpacing: CGFloat = SidebarQuotaFlow.wrappedLineSpacing

    static let wrappedLineSpacing: CGFloat = 8

    private struct Line {
        var indices: [Int] = []
        var width: CGFloat = 0
        /// Above and below the line's `quotaFirstLine` guide, which every
        /// item on it shares. Items default it to their centre, so a line
        /// centres each glyph on the meter block beside it, label and bar.
        var above: CGFloat = 0
        var below: CGFloat = 0
        var height: CGFloat { above + below }
    }

    private func lines(for subviews: Subviews, maxWidth: CGFloat?) -> (lines: [Line], sizes: [CGSize], guides: [CGFloat]) {
        let limit = maxWidth ?? .infinity
        let sizes = subviews.map { subview in
            let ideal = subview.sizeThatFits(.unspecified)
            return ideal.width > limit ? subview.sizeThatFits(ProposedViewSize(width: limit, height: nil)) : ideal
        }
        let guides = zip(subviews, sizes).map { subview, size in
            subview.dimensions(in: ProposedViewSize(size))[.quotaFirstLine]
        }
        var lines: [Line] = []
        var line = Line()
        for (index, size) in sizes.enumerated() where size.width > 0 || size.height > 0 {
            let width = line.indices.isEmpty ? size.width : line.width + horizontalSpacing + size.width
            if !line.indices.isEmpty && width > limit {
                lines.append(line)
                line = Line()
            }
            line.width = line.indices.isEmpty ? size.width : line.width + horizontalSpacing + size.width
            line.indices.append(index)
            line.above = max(line.above, guides[index])
            line.below = max(line.below, size.height - guides[index])
        }
        if !line.indices.isEmpty { lines.append(line) }
        return (lines, sizes, guides)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = lines(for: subviews, maxWidth: proposal.width).lines
        let height = lines.map(\.height).reduce(0, +) + verticalSpacing * CGFloat(max(lines.count - 1, 0))
        return CGSize(width: lines.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (lines, sizes, guides) = lines(for: subviews, maxWidth: bounds.width)
        var y = bounds.minY
        for line in lines {
            var x = bounds.minX
            for index in line.indices {
                let size = sizes[index]
                subviews[index].place(
                    at: CGPoint(x: x, y: y + line.above - guides[index]),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(size)
                )
                x += size.width + horizontalSpacing
            }
            y += line.height + verticalSpacing
        }
    }

    /// Lines up the provider icon beside the row with the first line's
    /// centre, not the middle of a wrapped row.
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? {
        guard guide == .quotaFirstLine, let first = lines(for: subviews, maxWidth: bounds.width).lines.first else { return nil }
        return first.above
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
    nonisolated static func minorUnitDigits(currency: String) -> Int {
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

    /// Spend against the monthly limit, or nil with no limit to fill toward.
    static func fraction(_ credit: UsageCredit?) -> Double? {
        guard let used = credit?.usedCents, let limit = credit?.limitCents, limit > 0 else { return nil }
        return min(max(Double(used) / Double(limit), 0), 1)
    }

    /// How far through the billing month the clock is, or nil without a limit
    /// to pace against. The reading names only when the period resets, so it
    /// opens one calendar month earlier.
    static func pacing(_ credit: UsageCredit?, now: Date, calendar: Calendar = .current) -> Double? {
        guard fraction(credit) != nil,
              let resetsAt = credit?.resetsAt,
              let opened = calendar.date(byAdding: .month, value: -1, to: resetsAt)
        else { return nil }
        return QuotaFreshness.pacing(resetsAt: resetsAt, now: now, window: resetsAt.timeIntervalSince(opened))
    }

    static func detailLines(_ credit: UsageCredit?, locale: Locale = .current) -> [String] {
        guard let credit, let used = credit.usedCents else { return ["No reading yet"] }
        let format = { (units: Int) in amount(minorUnits: units, currency: credit.currency, locale: locale) }
        var lines = ["\(format(used)) used this month"]
        if let limit = credit.limitCents {
            lines.append("Monthly limit: \(format(limit))")
        }
        if let remaining = credit.remainingCents {
            lines.append("\(format(remaining)) left")
        }
        if let resetsAt = credit.resetsAt {
            lines.append("Resets \(resetsAt.formatted(Date.FormatStyle(locale: locale).month(.abbreviated).day()))")
        }
        return lines
    }

    /// A popover's `plumeID` value: its detail lines, then `stale` when the
    /// reading is.
    static func controlValue(_ credit: UsageCredit?, isStale: Bool) -> String {
        (detailLines(credit) + (isStale ? ["stale"] : [])).joined(separator: "; ")
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
