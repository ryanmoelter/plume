import SwiftUI
import Foundation

/// The statusline strip: context-window use, 5h/7d quota, session cost, and
/// branch — a native equivalent of `~/.scripts/.claude/statusline.sh`.
///
/// Everything is a plain parameter so it previews and renders without a
/// store. Context is transcript-derived; quota and cost only reach a headless
/// session, so those segments render only when the stream has pushed them.
///
/// What a message will do next — permission mode, model, effort — lives in
/// `ChatComposer` instead: those describe the *next* turn, not the session as
/// a whole, and reading them at the point of sending is more useful than
/// reading them above the transcript. `ComposerControlsRow` shares this
/// file's `MeterView`/`segmentLabel` styling.
struct StatuslineStripView: View, ThemedView {
    @Environment(\.theme) var theme

    // Transcript-derived, so available on either transport.
    let contextUsedTokens: Int?
    let contextMaxTokens: Int?
    let branch: String?
    /// The worktree or directory work happens in, shown beside the branch —
    /// together they say where, and neither is much use alone.
    let workspaceName: String?
    /// Ahead/behind and dirty, which no transcript or stream event carries —
    /// Plume runs `git` for these itself.
    let gitState: GitState?

    // Stream-derived, headless only — nil segments are simply omitted.
    let rateLimit: RateLimitInfo?
    let sessionCostUSD: Double?

    init(
        contextUsedTokens: Int? = nil,
        contextMaxTokens: Int? = nil,
        branch: String? = nil,
        workspaceName: String? = nil,
        gitState: GitState? = nil,
        rateLimit: RateLimitInfo? = nil,
        sessionCostUSD: Double? = nil
    ) {
        self.contextUsedTokens = contextUsedTokens
        self.contextMaxTokens = contextMaxTokens
        self.branch = branch
        self.workspaceName = workspaceName
        self.gitState = gitState
        self.rateLimit = rateLimit
        self.sessionCostUSD = sessionCostUSD
    }

    var body: some View {
        HStack(spacing: 14) {
            contextSegment
            if let fiveHour = rateLimit?.fiveHour {
                StatuslineMeterSegment(
                    label: "5h",
                    utilization: fiveHour.utilization,
                    resetsAt: fiveHour.resetsAt,
                    barWidth: StatuslineMeterWidth.shortQuota
                )
            }
            if let sevenDay = rateLimit?.sevenDay {
                StatuslineMeterSegment(
                    label: "7d",
                    utilization: sevenDay.utilization,
                    resetsAt: sevenDay.resetsAt,
                    barWidth: StatuslineMeterWidth.quota
                )
            }
            if let sessionCostUSD {
                costSegment(sessionCostUSD)
            }
            if let workspaceName, !workspaceName.isEmpty {
                workspaceSegment(workspaceName)
            }
            if let branch, !branch.isEmpty {
                branchSegment(branch)
            }
            Spacer(minLength: 0)
        }
        .font(typography.caption.font)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .listItemPadding(bleed: true, column: .none, vertical: false)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - Segments

    @ViewBuilder
    private var contextSegment: some View {
        let percent = percentage(used: contextUsedTokens, max: contextMaxTokens)

        if contextUsedTokens != nil || percent != nil {
            let attention = StatuslineAttention.attention(contextTokens: contextUsedTokens, percent: percent)
            HStack(spacing: 5) {
                Text(tokenLabel(used: contextUsedTokens, max: contextMaxTokens))
                MeterView(fraction: StatuslineMeterMath.fraction(percent: percent), color: color(for: attention))
                    .frame(width: StatuslineMeterWidth.context)
            }
            .foregroundStyle(foreground(for: attention))
        }
    }

    private func workspaceSegment(_ name: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "folder")
            Text(name)
        }
        .foregroundStyle(foreground(for: .neutral))
    }

    private func costSegment(_ cost: Double) -> some View {
        Text(String(format: "$%.2f", cost))
            .foregroundStyle(foreground(for: .neutral))
    }

    /// Ahead/behind and dirty ride alongside the branch, which is where they
    /// read as one fact about the working tree rather than three segments.
    private func branchSegment(_ branch: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.branch")
            Text(branch)
                .lineLimit(1)
                .truncationMode(.middle)
            if let gitState {
                if let ahead = gitState.ahead, ahead > 0 {
                    Text("↑\(ahead)")
                }
                if let behind = gitState.behind, behind > 0 {
                    Text("↓\(behind)")
                }
                // No upstream at all is worth saying: it is the common case
                // on a fresh worktree branch, and silence would read as
                // "level with upstream".
                if !gitState.hasUpstream {
                    Text("no upstream")
                        .foregroundStyle(foreground(for: .neutral).opacity(colors.emphasis[.subtle]))
                }
                if gitState.isDirty {
                    Text("•")
                        .help("Uncommitted changes")
                }
            }
        }
        .foregroundStyle(foreground(for: .neutral))
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

    private func color(for attention: StatuslineAttention) -> Color {
        StatuslineColors.meter(for: attention, colors: colors)
    }

    private func foreground(for attention: StatuslineAttention) -> Color {
        StatuslineColors.foreground(for: attention, colors: colors)
    }
}

/// Bar lengths, longest first: the context window reads most precisely, the
/// seven-day quota next, the five-hour quota least.
enum StatuslineMeterWidth {
    static let context: CGFloat = 56
    static let quota: CGFloat = 36
    static let shortQuota: CGFloat = 24
}

/// A quota window's compact meter: `5d` (the reset countdown, falling back to
/// the raw window label) over a bar, with the percentage alongside it — the
/// shape the roadmap asked for, `5d: 15%` over `|----________|`.
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
        let attention = StatuslineAttention.attention(percent: percent)
        HStack(spacing: 5) {
            Text(resetLabel)
            MeterView(fraction: StatuslineMeterMath.fraction(percent: percent), color: StatuslineColors.meter(for: attention, colors: colors))
                .frame(width: barWidth)
            Text("\(Int(percent.rounded()))%")
        }
        .foregroundStyle(StatuslineColors.foreground(for: attention, colors: colors))
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
        contextMaxTokens: 200_000,
        branch: "ryanm/native-chat-ui"
    )
    .frame(width: 640)
}

#Preview("Headless transport") {
    StatuslineStripView(
        contextUsedTokens: 620_000,
        contextMaxTokens: 1_000_000,
        branch: "ryanm/native-chat-ui",
        rateLimit: RateLimitInfo(
            fiveHour: .init(utilization: 0.45, resetsAt: Date().addingTimeInterval(3600 * 2)),
            sevenDay: .init(utilization: 0.91, resetsAt: Date().addingTimeInterval(86400 * 3)),
            isUsingOverage: false
        ),
        sessionCostUSD: 4.32
    )
    .frame(width: 640)
}
