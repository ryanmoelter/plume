import SwiftUI
import Foundation

/// The statusline strip: context-window use, 5h/7d quota, session cost,
/// branch, and model + effort — a native equivalent of
/// `~/.scripts/.claude/statusline.sh`.
///
/// Everything is a plain parameter so it previews and renders without a
/// store. Context/model/effort/branch are transcript-derived; quota and cost
/// only reach a headless session, so those segments render only when the
/// stream has pushed them.
///
/// The model and effort segments become pickers when `onSelectModel`/
/// `onSelectEffort` are supplied; otherwise they render read-only.
struct StatuslineStripView: View, ThemedView {
    @Environment(\.theme) var theme

    // Transcript-derived, so available on either transport.
    let contextUsedTokens: Int?
    let contextMaxTokens: Int?
    let model: String?
    let effort: String?
    let branch: String?
    /// Ahead/behind and dirty, which no transcript or stream event carries —
    /// Plume runs `git` for these itself.
    let gitState: GitState?
    let permissionMode: String?

    // Stream-derived, headless only — nil segments are simply omitted.
    let rateLimit: RateLimitInfo?
    let sessionCostUSD: Double?

    // Turns the model/effort segments into pickers. Nil keeps them read-only.
    var onSelectModel: ((AgentModel) -> Void)?
    var onSelectEffort: ((AgentEffort) -> Void)?
    /// Advances the session one permission mode. Not a setter: Claude Code
    /// only steps through the modes, so the strip offers the step and shows
    /// where the session landed.
    var onCyclePermissionMode: (() -> Void)?

    init(
        contextUsedTokens: Int? = nil,
        contextMaxTokens: Int? = nil,
        model: String? = nil,
        effort: String? = nil,
        branch: String? = nil,
        gitState: GitState? = nil,
        permissionMode: String? = nil,
        rateLimit: RateLimitInfo? = nil,
        sessionCostUSD: Double? = nil,
        onSelectModel: ((AgentModel) -> Void)? = nil,
        onSelectEffort: ((AgentEffort) -> Void)? = nil,
        onCyclePermissionMode: (() -> Void)? = nil
    ) {
        self.contextUsedTokens = contextUsedTokens
        self.contextMaxTokens = contextMaxTokens
        self.model = model
        self.effort = effort
        self.branch = branch
        self.gitState = gitState
        self.permissionMode = permissionMode
        self.rateLimit = rateLimit
        self.sessionCostUSD = sessionCostUSD
        self.onSelectModel = onSelectModel
        self.onSelectEffort = onSelectEffort
        self.onCyclePermissionMode = onCyclePermissionMode
    }

    var body: some View {
        HStack(spacing: 14) {
            contextSegment
            if let fiveHour = rateLimit?.fiveHour {
                quotaSegment(label: "5h", window: fiveHour)
            }
            if let sevenDay = rateLimit?.sevenDay {
                quotaSegment(label: "7d", window: sevenDay)
            }
            if let sessionCostUSD {
                costSegment(sessionCostUSD)
            }
            if let branch, !branch.isEmpty {
                branchSegment(branch)
            }
            permissionModeSegment
            modelSegment
            Spacer(minLength: 0)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    // MARK: - Segments

    @ViewBuilder
    private var contextSegment: some View {
        let percent = percentage(used: contextUsedTokens, max: contextMaxTokens)

        if contextUsedTokens != nil || percent != nil {
            let attention = StatuslineAttention.attention(contextTokens: contextUsedTokens, percent: percent)
            HStack(spacing: 5) {
                MeterView(fraction: fraction(percent: percent), color: color(for: attention))
                    .frame(width: 36)
                Text(tokenLabel(used: contextUsedTokens, max: contextMaxTokens))
            }
            .foregroundStyle(foreground(for: attention))
        }
    }

    /// The stream reports `utilization` as a 0–1 fraction; every threshold and
    /// label here works in percent, so it is scaled once on the way in.
    private func quotaSegment(label: String, window: RateLimitInfo.Window) -> some View {
        let percent = window.utilization * 100
        let attention = StatuslineAttention.attention(percent: percent)
        return HStack(spacing: 5) {
            Text(resetLabel(fallback: label, resetsAt: window.resetsAt))
            MeterView(fraction: fraction(percent: percent), color: color(for: attention))
                .frame(width: 28)
            Text("\(Int(percent.rounded()))%")
        }
        .foregroundStyle(foreground(for: attention))
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

    /// A mode this UI does not offer still shows its reported name — better a
    /// truthful unfamiliar label than a familiar wrong one.
    @ViewBuilder
    private var permissionModeSegment: some View {
        if let permissionMode, !permissionMode.isEmpty {
            let label = PermissionMode.recognizing(permissionMode)?.label ?? permissionMode
            let attention = permissionModeAttention(permissionMode)
            if let onCyclePermissionMode {
                Button(action: onCyclePermissionMode) {
                    segmentLabel(label, attention: attention)
                }
                .buttonStyle(.plain)
                .help("Next permission mode (⇧⇥)")
            } else {
                Text(label)
                    .foregroundStyle(foreground(for: attention))
            }
        }
    }

    @ViewBuilder
    private var modelSegment: some View {
        if let model, !model.isEmpty {
            HStack(spacing: 4) {
                modelPicker(model)
                if let effort, !effort.isEmpty {
                    effortPicker(effort)
                }
            }
        } else if let effort, !effort.isEmpty {
            effortPicker(effort)
        }
    }

    @ViewBuilder
    private func modelPicker(_ displayModel: String) -> some View {
        if let onSelectModel {
            Menu {
                ForEach(AgentModel.allCases) { option in
                    Button(option.label) { onSelectModel(option) }
                }
            } label: {
                segmentLabel(displayModel, attention: .neutral)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        } else {
            Text(displayModel)
                .foregroundStyle(foreground(for: .neutral))
        }
    }

    @ViewBuilder
    private func effortPicker(_ displayEffort: String) -> some View {
        if let onSelectEffort {
            Menu {
                ForEach(AgentEffort.allCases) { option in
                    Button(option.label) { onSelectEffort(option) }
                }
            } label: {
                segmentLabel(displayEffort, attention: effortAttention(displayEffort))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        } else {
            Text(displayEffort)
                .foregroundStyle(foreground(for: effortAttention(displayEffort)))
        }
    }

    private func segmentLabel(_ text: String, attention: StatuslineAttention) -> some View {
        HStack(spacing: 2) {
            Text(text)
            Image(systemName: "chevron.down")
                .font(.system(size: 8))
        }
        .foregroundStyle(foreground(for: attention))
    }

    // MARK: - Helpers

    /// Matches `statusline.sh`'s `effort_seg`: `xhigh`/`max` need attention,
    /// everything else (including an unrecognized level) is neutral.
    private func effortAttention(_ level: String) -> StatuslineAttention {
        switch level {
        case "xhigh", "max": return .yellow
        default: return .neutral
        }
    }

    /// Bypassing every permission check is worth flagging; the rest are
    /// ordinary working modes.
    private func permissionModeAttention(_ mode: String) -> StatuslineAttention {
        PermissionMode.recognizing(mode) == .bypassPermissions ? .red : .neutral
    }

    private func percentage(used: Int?, max: Int?) -> Double? {
        guard let used, let max, max > 0 else { return nil }
        return Double(used) / Double(max) * 100
    }

    private func fraction(percent: Double?) -> Double {
        guard let percent else { return 0 }
        return Swift.min(Swift.max(percent / 100, 0), 1)
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

    private func resetLabel(fallback: String, resetsAt: Date?) -> String {
        guard let resetsAt else { return fallback }
        let seconds = resetsAt.timeIntervalSinceNow
        guard seconds > 0 else { return fallback }
        if seconds >= 86400 {
            return "\(Int((seconds + 43200) / 86400))d"
        }
        if seconds >= 3600 {
            return "\(Int((seconds + 1800) / 3600))h"
        }
        return "\(Int((seconds + 30) / 60))m"
    }

    /// The meter's own fill, which is a graphic rather than text — so a
    /// neutral meter dims the theme foreground instead of borrowing the text
    /// hierarchy, which a `Capsule` fill cannot use.
    private func color(for attention: StatuslineAttention) -> Color {
        switch attention {
        case .neutral: return colors.foreground
            .opacity(colors.emphasis[.secondary])
        case .yellow: return colors.warning
        case .red: return colors.danger
        }
    }

    private func foreground(for attention: StatuslineAttention) -> Color {
        switch attention {
        case .neutral: return colors.foreground
        case .yellow: return colors.warning
        case .red: return colors.danger
        }
    }
}

/// A small capsule meter — the native stand-in for the shell script's braille
/// bars, not a reproduction of them.
private struct MeterView: View, ThemedView {
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
        model: "Sonnet 5",
        effort: "medium",
        branch: "ryanm/native-chat-ui"
    )
    .frame(width: 640)
}

#Preview("Headless transport") {
    StatuslineStripView(
        contextUsedTokens: 620_000,
        contextMaxTokens: 1_000_000,
        model: "Opus 5 (1M)",
        effort: "max",
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

#Preview("Pickers active") {
    StatuslineStripView(
        contextUsedTokens: 82_000,
        contextMaxTokens: 200_000,
        model: "sonnet",
        effort: "medium",
        branch: "ryanm/native-chat-ui",
        onSelectModel: { _ in },
        onSelectEffort: { _ in }
    )
    .frame(width: 640)
}
