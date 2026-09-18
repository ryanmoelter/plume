import SwiftUI
import Foundation

/// The statusline strip's meters: context-window use, 5h/7d quota and session
/// cost — a native equivalent of `~/.scripts/.claude/statusline.sh`.
///
/// Context and cost are plain parameters, per session. Quota is not: it
/// belongs to the account, so it comes from `QuotaStore.shared` and reads the
/// same in every chat. `contextMaxTokens` may be a measured value or the
/// model's assumed window — the label makes no distinction, by design. Cost
/// only reaches a headless session, so that segment renders only when the
/// stream has pushed it.
///
/// Each meter stacks its reading over its bar. Side by side the two ran the
/// full width of the panel for what is a percentage; stacked, the bar can be
/// no wider than the number above it.
///
/// The strip hugs its content: `ChatTabView.statuslineFooter` puts the
/// workspace group on the row's leading edge and Remote Control on its
/// trailing one, so the whole row reads left to right as where this runs,
/// then what it has spent.
///
/// Which of the two layouts to draw is the caller's decision, not this
/// view's: `ChatTabView.statuslineFooter` runs one `ViewThatFits` over the
/// whole row, so the branch name and the meters give way in a single
/// ordering rather than shrinking against each other.
///
/// What a message will do next — permission mode, model, effort — lives in
/// `ChatComposer` instead: those describe the *next* turn, not the session as
/// a whole, and reading them at the point of sending is more useful than
/// reading them above the transcript. Both rows share the segment styling
/// `ComposerControlsRow.swift` defines (`ComposerSegmentLabel`,
/// `StatuslineColors`).
struct StatuslineStripView: View, ThemedView {
    @Environment(\.theme) var theme

    let layout: StatuslineStripLayout

    // Transcript-derived, so available on either transport.
    let contextUsedTokens: Int?
    let contextMaxTokens: Int?

    // Stream-derived, headless only — nil segments are simply omitted.
    let sessionCostUSD: Double?

    /// Account-wide, so it comes from the shared store rather than from the
    /// session this strip belongs to: a chat that has not taken a turn in an
    /// hour still shows what the account heard a moment ago.
    @State private var quota = QuotaStore.shared

    init(
        layout: StatuslineStripLayout = .wide,
        contextUsedTokens: Int? = nil,
        contextMaxTokens: Int? = nil,
        sessionCostUSD: Double? = nil
    ) {
        self.layout = layout
        self.contextUsedTokens = contextUsedTokens
        self.contextMaxTokens = contextMaxTokens
        self.sessionCostUSD = sessionCostUSD
    }

    var body: some View {
        Group {
            switch layout {
            case .wide: wideLayout
            case .stacked: stackedLayout
            }
        }
        .font(typography.caption.font)
        .onAppear { quota.startTicking() }
    }

    private var rateLimit: RateLimitInfo? { quota.snapshot?.rateLimit }

    private var isStale: Bool {
        guard let snapshot = quota.snapshot else { return false }
        return QuotaFreshness.isStale(receivedAt: snapshot.receivedAt, now: quota.now)
    }

    // MARK: - Layouts

    private var wideLayout: some View {
        // Top-aligned: a meter's reading is its first line, so the meters line
        // up along it whether or not a bar follows. The cost opts back out.
        HStack(alignment: .top, spacing: dimensions.statuslineSegmentSpacing) {
            contextSegment(showsReading: true)
            if let fiveHour = rateLimit?.fiveHour {
                StatuslineMeterSegment(
                    label: "5h",
                    utilization: fiveHour.utilization,
                    resetsAt: fiveHour.resetsAt,
                    now: quota.now,
                    isStale: isStale,
                    barWidth: StatuslineMeterWidth.shortQuota
                )
                .accessibilityIdentifier(AccessibilityID.statuslineFiveHourMeter)
            }
            if let sevenDay = rateLimit?.sevenDay {
                StatuslineMeterSegment(
                    label: "7d",
                    utilization: sevenDay.utilization,
                    resetsAt: sevenDay.resetsAt,
                    now: quota.now,
                    isStale: isStale,
                    barWidth: StatuslineMeterWidth.quota
                )
                .accessibilityIdentifier(AccessibilityID.statuslineSevenDayMeter)
            }
            if let sessionCostUSD {
                costSegment(sessionCostUSD)
                    .accessibilityIdentifier(AccessibilityID.statuslineCost)
            }
        }
        .fixedSize()
    }

    /// Bars only, stacked top to bottom instead of side by side, and no cost
    /// — what the row falls back to once `wideLayout` no longer fits.
    /// `statuslineStackedBarSpacing` keeps the three bars within the height
    /// one reading-over-bar meter already takes.
    private var stackedLayout: some View {
        VStack(alignment: .leading, spacing: dimensions.statuslineStackedBarSpacing) {
            contextSegment(showsReading: false)
            if let fiveHour = rateLimit?.fiveHour {
                StatuslineMeterSegment(
                    label: "5h",
                    utilization: fiveHour.utilization,
                    resetsAt: fiveHour.resetsAt,
                    now: quota.now,
                    isStale: isStale,
                    barWidth: StatuslineMeterWidth.shortQuota,
                    showsReading: false
                )
                .accessibilityIdentifier(AccessibilityID.statuslineFiveHourMeter)
            }
            if let sevenDay = rateLimit?.sevenDay {
                StatuslineMeterSegment(
                    label: "7d",
                    utilization: sevenDay.utilization,
                    resetsAt: sevenDay.resetsAt,
                    now: quota.now,
                    isStale: isStale,
                    barWidth: StatuslineMeterWidth.quota,
                    showsReading: false
                )
                .accessibilityIdentifier(AccessibilityID.statuslineSevenDayMeter)
            }
        }
    }

    // MARK: - Segments

    @ViewBuilder
    private func contextSegment(showsReading: Bool) -> some View {
        let percent = percentage(used: contextUsedTokens, max: contextMaxTokens)

        if contextUsedTokens != nil || percent != nil {
            let attention = StatuslineAttention.attention(contextTokens: contextUsedTokens, percent: percent)
            StackedMeter(
                reading: tokenLabel(used: contextUsedTokens, max: contextMaxTokens),
                fraction: StatuslineMeterMath.fraction(percent: percent),
                barWidth: StatuslineMeterWidth.context,
                attention: attention,
                showsReading: showsReading
            )
            .help("Context window used")
            .accessibilityLabel("Context window")
            .accessibilityIdentifier(AccessibilityID.statuslineContextMeter)
        }
    }

    /// Centred rather than top-aligned with the readings beside it: the cost
    /// is not a measurement of a limit, it is how much this would cost at API
    /// prices. Centring is what says that — sharing the meters' reading line
    /// would file it as one more quota.
    private func costSegment(_ cost: Double) -> some View {
        Text(String(format: "$%.2f", cost))
            .foregroundStyle(StatuslineColors.statuslineText(for: .neutral, colors: colors))
            .help("What this session has cost so far")
            .frame(maxHeight: .infinity)
    }

    // MARK: - Helpers

    private func percentage(used: Int?, max: Int?) -> Double? {
        guard let used, let max, max > 0 else { return nil }
        return Double(used) / Double(max) * 100
    }

    private func tokenLabel(used: Int?, max: Int?) -> String {
        let usedText = used.map(formatTokenCount) ?? "0"
        let maxText = max.map(formatTokenCount) ?? "—"
        return "\(usedText)/\(maxText)"
    }

    private func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            let value = Double(count) / 1_000_000
            return value.truncatingRemainder(dividingBy: 1) == 0
                ? "\(Int(value))M" : String(format: "%.1fM", value)
        }
        if count >= 1_000 {
            return "\(count / 1_000)k"
        }
        return "\(count)"
    }
}

/// Which shape the strip draws. `ChatTabView.statuslineFooter` picks one per
/// `ViewThatFits` candidate: `wide` is the full row of side-by-side meters
/// with their readings and the session cost, `stacked` is the same meters as
/// bars alone, one above the next.
enum StatuslineStripLayout {
    case wide
    case stacked
}

/// Bar lengths, longest first: the context window reads most precisely, the
/// seven-day quota next, the five-hour quota least. The row now lays out from
/// each segment's own intrinsic size rather than squeezing to fit, so these
/// can run a bit longer than a reading needs and still cost nothing but the
/// branch chip's own truncation room. The stacked layout reuses the same widths,
/// so a bar means the same thing whichever layout is showing.
enum StatuslineMeterWidth {
    static let context: CGFloat = 50
    static let quota: CGFloat = 36
    static let shortQuota: CGFloat = 28
}

/// A reading over its bar — the shape every meter in the strip takes.
struct StackedMeter: View, ThemedView {
    @Environment(\.theme) var theme

    let reading: String
    let fraction: Double
    let barWidth: CGFloat
    let attention: StatuslineAttention
    /// The stacked statusline layout drops the reading and keeps only the
    /// bar; the reading still reaches VoiceOver, as the bar's
    /// `accessibilityValue`, rather than disappearing with the label.
    var showsReading: Bool = true

    var body: some View {
        let bar = MeterView(fraction: fraction, color: StatuslineColors.meter(for: attention, colors: colors))
            .frame(width: barWidth)
        if showsReading {
            // Centered rather than leading: the reading and the bar rarely
            // share a width (a short reading over a long bar, or the
            // reverse), and centering is what keeps whichever is narrower
            // looking placed rather than merely left-aligned with the other.
            VStack(alignment: .center, spacing: dimensions.statuslineMeterSpacing) {
                Text(reading)
                    .foregroundStyle(StatuslineColors.statuslineText(for: attention, colors: colors))
                    .lineLimit(1)
                bar
            }
        } else {
            bar.accessibilityValue(reading)
        }
    }
}

/// A quota window's compact meter: the reset countdown and the percentage —
/// `5d 15%` — over its bar.
struct StatuslineMeterSegment: View, ThemedView {
    @Environment(\.theme) var theme

    let label: String
    /// 0–1, matching the stream's own `utilization` — scaled to a percent
    /// once, here, rather than by each caller.
    let utilization: Double
    let resetsAt: Date?
    /// Supplied by `QuotaStore`'s tick rather than read as `Date()`, so the
    /// countdown re-renders every minute instead of at whatever else happens
    /// to invalidate the view.
    var now: Date = Date()
    /// Dims the whole meter once the reading is old enough that presenting it
    /// at full strength would overstate what is known.
    var isStale: Bool = false
    /// Bar length carries how finely the number is worth reading. Context
    /// deserves the most precision, then the seven-day window; the five-hour
    /// quota moves fast enough that its exact percent matters least.
    var barWidth: CGFloat = StatuslineMeterWidth.quota
    var showsReading: Bool = true

    var body: some View {
        let percent = utilization * 100
        StackedMeter(
            reading: "\(resetLabel) \(Int(percent.rounded()))%",
            fraction: StatuslineMeterMath.fraction(percent: percent),
            barWidth: barWidth,
            attention: StatuslineAttention.attention(percent: percent),
            showsReading: showsReading
        )
        .opacity(isStale ? QuotaFreshness.staleOpacity : 1)
        .help(helpText)
    }

    private var helpText: String {
        var text = "\(label) quota used"
        if let resetsAt {
            text += ", resetting at \(QuotaFreshness.absoluteResetLabel(resetsAt: resetsAt, now: now))"
        }
        if isStale { text += " (last heard over 30 minutes ago)" }
        return text
    }

    private var resetLabel: String {
        QuotaFreshness.resetLabel(resetsAt: resetsAt, now: now, fallback: label)
    }
}

/// Remote Control's own segment, driving the same `setRemoteControl` the
/// typed `/rc` does. A session-wide fact like quota and cost, so it sits in
/// the statusline rather than beside the next turn's settings. Absent before
/// a session exists, since there is no bridge to attach to until then.
struct RemoteControlControl: View, ThemedView {
    @Environment(\.theme) var theme
    let session: HeadlessSession

    var body: some View {
        Menu {
            switch session.remoteControl {
            case .connected(let link):
                Button("Disconnect Remote Control") { session.setRemoteControl(enabled: false) }
                if let url = link.shareableURL {
                    Button("Copy Remote Control Link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url, forType: .string)
                    }
                }
            default:
                Button("Connect Remote Control") { session.setRemoteControl(enabled: true) }
            }
        } label: {
            // No height, so the label takes one caption line: the composer's
            // 22pt control height would centre the glyph well below the meter
            // readings this sits beside.
            ComposerSegmentLabel(
                systemImage: symbol,
                text: "Remote Control",
                showsText: false,
                foreground: tint
            )
        }
        .menuStyle(.borderlessButton)
        .font(typography.caption.font)
        .fixedSize()
        // The antenna reports on the session rather than on any one meter, so
        // it centres against the two-line strip instead of topping out with
        // the readings. Stretching leaves the row's height the meters'.
        .frame(maxHeight: .infinity)
        .help(helpText)
        .accessibilityLabel("Remote Control")
        .accessibilityValue(accessibilityValue)
        .accessibilityIdentifier(AccessibilityID.composerRemoteControlControl)
    }

    private var symbol: String {
        switch session.remoteControl {
        case .connected, .connecting: return StatusSymbol.remoteControl.name
        case .disconnected, .failed: return "\(StatusSymbol.remoteControl.name).slash"
        }
    }

    /// A live bridge means someone else can drive this session, which is worth
    /// its own color; a failure is worth another. Connecting and off are
    /// ordinary statusline chrome and dim with the rest of the strip.
    private var tint: Color {
        switch session.remoteControl {
        case .connected: return colors.attention
        case .failed: return colors.danger
        case .connecting, .disconnected:
            return colors.foreground.opacity(colors.emphasis[.secondary])
        }
    }

    private var accessibilityValue: String {
        switch session.remoteControl {
        case .disconnected: return "Off"
        case .connecting: return "Connecting"
        case .connected: return "On"
        case .failed(let message): return "Failed: \(message)"
        }
    }

    private var helpText: String {
        switch session.remoteControl {
        case .connected: return "Remote Control is on \u{2014} this session is on claude.ai/code"
        case .connecting: return "Connecting to Remote Control\u{2026}"
        case .failed(let message): return "Remote Control failed: \(message)"
        case .disconnected: return "Remote Control \u{2014} drive this session from your phone or claude.ai/code"
        }
    }
}

/// Pure percent-to-fraction arithmetic shared by every meter, kept apart from
/// any view so it can be tested without SwiftUI.
enum StatuslineMeterMath {
    /// Clamps a percent (0–100, or nil) to the 0–1 fraction `MeterView` fills.
    static func fraction(percent: Double?) -> Double {
        guard let percent else { return 0 }
        return Swift.min(Swift.max(percent / 100, 0), 1)
    }
}

/// Attention-to-color mapping shared by the strip and the composer's
/// controls row, so a segment moved between them keeps its meaning.
enum StatuslineColors {
    /// The meter's own fill, which is a graphic rather than text — so a
    /// neutral meter dims the theme foreground instead of borrowing the text
    /// hierarchy, which a `Capsule` fill cannot use.
    static func meter(for attention: StatuslineAttention, colors: Palette) -> Color {
        switch attention {
        case .neutral: return colors.foreground.opacity(colors.emphasis[.secondary])
        case .yellow: return colors.warning
        case .red: return colors.danger
        }
    }

    static func foreground(for attention: StatuslineAttention, colors: Palette) -> Color {
        switch attention {
        case .neutral: return colors.foreground
        case .yellow: return colors.warning
        case .red: return colors.danger
        }
    }

    /// The strip's own text: neutral dims to secondary so the eye lands on
    /// the box content and the composer's model/effort/permission dropdowns
    /// instead, while yellow and red keep `foreground`'s full-strength
    /// attention hue — that is the one signal this row still needs to win.
    /// `ComposerControlsRow` keeps calling `foreground` directly, since its
    /// dropdowns are next-turn controls the row is not trying to de-emphasize.
    static func statuslineText(for attention: StatuslineAttention, colors: Palette) -> Color {
        switch attention {
        case .neutral: return colors.foreground.opacity(colors.emphasis[.secondary])
        case .yellow, .red: return foreground(for: attention, colors: colors)
        }
    }
}

/// A small capsule meter — the native stand-in for the shell script's braille
/// bars, not a reproduction of them.
struct MeterView: View, ThemedView {
    @Environment(\.theme) var theme

    let fraction: Double
    let color: Color

    private var trackOpacity: Double {
        colors.emphasis[.divider]
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(color.opacity(trackOpacity))
                Capsule()
                    .fill(color)
                    .frame(width: geometry.size.width * fraction)
            }
        }
        .frame(height: 5)
    }
}

#Preview("Terminal transport") {
    StatuslineStripView(
        contextUsedTokens: 82_000,
        contextMaxTokens: 200_000
    )
    .frame(width: 640)
}

#Preview("Headless transport") {
    StatuslineStripView(
        contextUsedTokens: 620_000,
        contextMaxTokens: 1_000_000,
        sessionCostUSD: 4.32
    )
    .frame(width: 640)
}

#Preview("Stacked fallback") {
    StatuslineStripView(
        layout: .stacked,
        contextUsedTokens: 620_000,
        contextMaxTokens: 1_000_000,
        sessionCostUSD: 4.32
    )
    .frame(width: 100)
}
