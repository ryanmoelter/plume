import SwiftUI
import Foundation

/// The statusline strip: context-window use, 5h/7d quota, session cost,
/// branch, and model + effort — a native equivalent of
/// `~/.scripts/.claude/statusline.sh`.
///
/// Everything is a plain parameter so it previews and renders without a
/// store. Context/model/effort/branch are transcript-derived and available
/// even with statusline capture off; quota and cost only exist in a captured
/// payload, so those segments render only when one is supplied.
///
/// The model and effort segments become pickers when `onSelectModel`/
/// `onSelectEffort` are supplied; otherwise they render read-only as before.
struct StatuslineStripView: View {
    @Environment(\.colorScheme) private var colorScheme

    // Transcript-derived — available regardless of capture.
    let contextUsedTokens: Int?
    let contextMaxTokens: Int?
    let model: String?
    let effort: String?
    let branch: String?

    // Capture-derived — nil segments are simply omitted.
    let payload: StatuslinePayload?

    // Turns the model/effort segments into pickers. Nil keeps them
    // read-only, so every existing preview and call site is unaffected.
    var onSelectModel: ((AgentModel) -> Void)?
    var onSelectEffort: ((AgentEffort) -> Void)?

    init(
        contextUsedTokens: Int? = nil,
        contextMaxTokens: Int? = nil,
        model: String? = nil,
        effort: String? = nil,
        branch: String? = nil,
        payload: StatuslinePayload? = nil,
        onSelectModel: ((AgentModel) -> Void)? = nil,
        onSelectEffort: ((AgentEffort) -> Void)? = nil
    ) {
        self.contextUsedTokens = contextUsedTokens
        self.contextMaxTokens = contextMaxTokens
        self.model = model
        self.effort = effort
        self.branch = branch
        self.payload = payload
        self.onSelectModel = onSelectModel
        self.onSelectEffort = onSelectEffort
    }

    private var themeForeground: Color? {
        ThemeChrome.foreground(for: colorScheme)
    }

    var body: some View {
        HStack(spacing: 14) {
            contextSegment
            if let fiveHour = payload?.rateLimits?.fiveHour {
                quotaSegment(label: "5h", rateLimit: fiveHour)
            }
            if let sevenDay = payload?.rateLimits?.sevenDay {
                quotaSegment(label: "7d", rateLimit: sevenDay)
            }
            if let cost = payload?.cost?.totalCostUSD {
                costSegment(cost)
            }
            if let branch, !branch.isEmpty {
                branchSegment(branch)
            }
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
        let usedTokens = contextUsedTokens ?? payload?.contextUsedTokens
        let maxTokens = contextMaxTokens ?? payload?.contextWindow?.contextWindowSize
        let percent = payload?.contextWindow?.usedPercentage
            ?? percentage(used: usedTokens, max: maxTokens)

        if usedTokens != nil || percent != nil {
            let attention = StatuslineAttention.attention(contextTokens: usedTokens, percent: percent)
            HStack(spacing: 5) {
                MeterView(fraction: fraction(percent: percent), color: color(for: attention))
                    .frame(width: 36)
                Text(tokenLabel(used: usedTokens, max: maxTokens))
            }
            .foregroundStyle(foreground(for: attention))
        }
    }

    private func quotaSegment(label: String, rateLimit: StatuslinePayload.RateLimit) -> some View {
        let percent = rateLimit.usedPercentage
        let attention = StatuslineAttention.attention(percent: percent)
        return HStack(spacing: 5) {
            Text(resetLabel(fallback: label, resetsAt: rateLimit.resetsAt))
            MeterView(fraction: fraction(percent: percent), color: color(for: attention))
                .frame(width: 28)
            if let percent {
                Text("\(Int(percent.rounded()))%")
            }
        }
        .foregroundStyle(foreground(for: attention))
    }

    private func costSegment(_ cost: Double) -> some View {
        Text(String(format: "$%.2f", cost))
            .foregroundStyle(foreground(for: .neutral))
    }

    private func branchSegment(_ branch: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.branch")
            Text(branch)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(foreground(for: .neutral))
    }

    @ViewBuilder
    private var modelSegment: some View {
        let displayModel = model ?? payload?.model?.displayName
        let displayEffort = effort ?? payload?.effort?.level
        if let displayModel, !displayModel.isEmpty {
            HStack(spacing: 4) {
                modelPicker(displayModel)
                if let displayEffort, !displayEffort.isEmpty {
                    effortPicker(displayEffort)
                }
            }
        } else if let displayEffort, !displayEffort.isEmpty {
            effortPicker(displayEffort)
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

    private func resetLabel(fallback: String, resetsAt: Double?) -> String {
        guard let resetsAt, resetsAt > 0 else { return fallback }
        let seconds = resetsAt - Date().timeIntervalSince1970
        guard seconds > 0 else { return fallback }
        if seconds >= 86400 {
            return "\(Int((seconds + 43200) / 86400))d"
        }
        if seconds >= 3600 {
            return "\(Int((seconds + 1800) / 3600))h"
        }
        return "\(Int((seconds + 30) / 60))m"
    }

    private func color(for attention: StatuslineAttention) -> Color {
        switch attention {
        case .neutral: return themeForeground ?? .secondary
        case .yellow: return .yellow
        case .red: return .red
        }
    }

    private func foreground(for attention: StatuslineAttention) -> Color {
        switch attention {
        case .neutral: return themeForeground ?? .primary
        case .yellow: return .yellow
        case .red: return .red
        }
    }
}

/// A small capsule meter — the native stand-in for the shell script's braille
/// bars, not a reproduction of them.
private struct MeterView: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(color.opacity(0.2))
                Capsule()
                    .fill(color)
                    .frame(width: geometry.size.width * fraction)
            }
        }
        .frame(height: 5)
    }
}

#Preview("Capture off") {
    StatuslineStripView(
        contextUsedTokens: 82_000,
        contextMaxTokens: 200_000,
        model: "Sonnet 5",
        effort: "medium",
        branch: "ryanm/native-chat-ui"
    )
    .frame(width: 640)
}

#Preview("Capture on") {
    StatuslineStripView(
        contextUsedTokens: 620_000,
        contextMaxTokens: 1_000_000,
        model: "Opus 5 (1M)",
        effort: "max",
        branch: "ryanm/native-chat-ui",
        payload: StatuslinePayload(
            contextWindow: .init(
                usedPercentage: 62,
                totalInputTokens: 600_000,
                totalOutputTokens: 20_000,
                contextWindowSize: 1_000_000
            ),
            rateLimits: .init(
                fiveHour: .init(usedPercentage: 45, resetsAt: Date().timeIntervalSince1970 + 3600 * 2),
                sevenDay: .init(usedPercentage: 91, resetsAt: Date().timeIntervalSince1970 + 86400 * 3)
            ),
            cost: .init(totalCostUSD: 4.32),
            workspace: nil,
            cwd: nil,
            model: .init(displayName: "Opus 5 (1M)"),
            effort: .init(level: "max")
        )
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
