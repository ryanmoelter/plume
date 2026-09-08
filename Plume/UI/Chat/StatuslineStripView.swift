import SwiftUI
import Foundation

/// The statusline strip's meters: context-window use, 5h/7d quota and session
/// cost — a native equivalent of `~/.scripts/.claude/statusline.sh`.
///
/// Everything is a plain parameter so it previews and renders without a
/// store. `contextMaxTokens` may be a measured value or the model's assumed
/// window — the label makes no distinction, by design. Quota and cost only
/// reach a headless session, so those segments render only when the stream
/// has pushed them.
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
/// What a message will do next — permission mode, model, effort — lives in
/// `ChatComposer` instead: those describe the *next* turn, not the session as
/// a whole, and reading them at the point of sending is more useful than
/// reading them above the transcript. Both rows share the segment styling
/// `ComposerControlsRow.swift` defines (`ComposerSegmentLabel`,
/// `StatuslineColors`).
struct StatuslineStripView: View, ThemedView {
    @Environment(\.theme) var theme

    // Transcript-derived, so available on either transport.
    let contextUsedTokens: Int?
    let contextMaxTokens: Int?

    // Stream-derived, headless only — nil segments are simply omitted.
    let rateLimit: RateLimitInfo?
    let sessionCostUSD: Double?

    init(
        contextUsedTokens: Int? = nil,
        contextMaxTokens: Int? = nil,
        rateLimit: RateLimitInfo? = nil,
        sessionCostUSD: Double? = nil
    ) {
        self.contextUsedTokens = contextUsedTokens
        self.contextMaxTokens = contextMaxTokens
        self.rateLimit = rateLimit
        self.sessionCostUSD = sessionCostUSD
    }

    var body: some View {
        // Top-aligned: a meter's reading is its first line, so the meters line
        // up along it whether or not a bar follows. The cost opts back out.
        HStack(alignment: .top, spacing: dimensions.statuslineSegmentSpacing) {
            contextSegment
            if let fiveHour = rateLimit?.fiveHour {
                StatuslineMeterSegment(
                    label: "5h",
                    utilization: fiveHour.utilization,
                    resetsAt: fiveHour.resetsAt,
                    barWidth: StatuslineMeterWidth.shortQuota
                )
                .accessibilityIdentifier(AccessibilityID.statuslineFiveHourMeter)
            }
            if let sevenDay = rateLimit?.sevenDay {
                StatuslineMeterSegment(
                    label: "7d",
                    utilization: sevenDay.utilization,
                    resetsAt: sevenDay.resetsAt,
                    barWidth: StatuslineMeterWidth.quota
                )
                .accessibilityIdentifier(AccessibilityID.statuslineSevenDayMeter)
            }
            if let sessionCostUSD {
                costSegment(sessionCostUSD)
                    .accessibilityIdentifier(AccessibilityID.statuslineCost)
            }
        }
        .font(typography.caption.font)
    }

    // MARK: - Segments

    @ViewBuilder
    private var contextSegment: some View {
        let percent = percentage(used: contextUsedTokens, max: contextMaxTokens)

        if contextUsedTokens != nil || percent != nil {
            let attention = StatuslineAttention.attention(contextTokens: contextUsedTokens, percent: percent)
            StackedMeter(
                reading: tokenLabel(used: contextUsedTokens, max: contextMaxTokens),
                fraction: StatuslineMeterMath.fraction(percent: percent),
                barWidth: StatuslineMeterWidth.context,
                attention: attention
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

/// Bar lengths, longest first: the context window reads most precisely, the
/// seven-day quota next, the five-hour quota least. The row now lays out from
/// each segment's own intrinsic size rather than squeezing to fit, so these
/// can run a bit longer than a reading needs and still cost nothing but the
/// branch chip's own truncation room.
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

    var body: some View {
        // Centered rather than leading: the reading and the bar rarely share
        // a width (a short reading over a long bar, or the reverse), and
        // centering is what keeps whichever is narrower looking placed
        // rather than merely left-aligned with the other.
        VStack(alignment: .center, spacing: dimensions.statuslineMeterSpacing) {
            Text(reading)
                .foregroundStyle(StatuslineColors.statuslineText(for: attention, colors: colors))
                .lineLimit(1)
            MeterView(fraction: fraction, color: StatuslineColors.meter(for: attention, colors: colors))
                .frame(width: barWidth)
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
    /// Bar length carries how finely the number is worth reading. Context
    /// deserves the most precision, then the seven-day window; the five-hour
    /// quota moves fast enough that its exact percent matters least.
    var barWidth: CGFloat = StatuslineMeterWidth.quota

    var body: some View {
        let percent = utilization * 100
        StackedMeter(
            reading: "\(resetLabel) \(Int(percent.rounded()))%",
            fraction: StatuslineMeterMath.fraction(percent: percent),
            barWidth: barWidth,
            attention: StatuslineAttention.attention(percent: percent)
        )
        .help(helpText)
    }

    private var helpText: String {
        guard resetLabel != label else { return "\(label) quota used" }
        return "\(label) quota used, resetting in \(resetLabel)"
    }

    private var resetLabel: String {
        guard let resetsAt else { return label }
        let seconds = resetsAt.timeIntervalSinceNow
        guard seconds > 0 else { return label }
        if seconds >= 86400 {
            return "\(Int((seconds + 43200) / 86400))d"
        }
        if seconds >= 3600 {
            return "\(Int((seconds + 1800) / 3600))h"
        }
        return "\(Int((seconds + 30) / 60))m"
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
        case .connected, .connecting: return "antenna.radiowaves.left.and.right"
        case .disconnected, .failed: return "antenna.radiowaves.left.and.right.slash"
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
        rateLimit: RateLimitInfo(
            fiveHour: .init(utilization: 0.45, resetsAt: Date().addingTimeInterval(3600 * 2)),
            sevenDay: .init(utilization: 0.91, resetsAt: Date().addingTimeInterval(86400 * 3)),
            isUsingOverage: false
        ),
        sessionCostUSD: 4.32
    )
    .frame(width: 640)
}
