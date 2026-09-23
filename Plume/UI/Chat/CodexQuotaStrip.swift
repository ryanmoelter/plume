import SwiftUI

/// A quota strip for Codex's provider-specific account windows.
///
/// Unlike Claude's fixed five-hour/seven-day strip, this view keeps the
/// server's bucket IDs, primary/secondary slots, and actual durations visible.
/// It is standalone so the shared statusline can adopt it without teaching the
/// Claude view about Codex's account schema.
struct CodexQuotaStrip: View, ThemedView {
    @Environment(\.theme) var theme
    @State private var showingDetails = false

    enum Layout {
        case wide
        case stacked
    }

    let windows: [CodexQuotaWindow]
    var layout: Layout = .wide

    init(windows: [CodexQuotaWindow], layout: Layout = .wide) {
        self.windows = windows.filter { $0.usedPercent > 0 }
        self.layout = layout
    }

    var body: some View {
        Button {
            showingDetails = true
        } label: {
            switch layout {
            case .wide:
                HStack(alignment: .top, spacing: dimensions.statuslineSegmentSpacing) {
                    ForEach(windows) { window in
                        meter(for: window, showsReading: true)
                    }
                }
                .fixedSize()
            case .stacked:
                VStack(alignment: .leading, spacing: dimensions.statuslineStackedBarSpacing) {
                    ForEach(windows) { window in
                        meter(for: window, showsReading: false)
                    }
                }
                .frame(minHeight: 22)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .font(typography.caption.font)
        .help("Codex quota")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Codex quota")
        .accessibilityValue(accessibilitySummary)
        .popover(isPresented: $showingDetails) {
            CodexQuotaDetails(windows: windows)
                .environment(\.theme, theme)
        }
    }

    @ViewBuilder
    private func meter(for window: CodexQuotaWindow, showsReading: Bool) -> some View {
        let percent = Double(window.usedPercent)
        let attention = StatuslineAttention.attention(percent: percent)
        let bar = MeterView(
            fraction: StatuslineMeterMath.fraction(percent: percent),
            color: StatuslineColors.meter(for: attention, colors: colors)
        )
        .frame(width: StatuslineMeterWidth.quota)

        if showsReading {
            VStack(alignment: .center, spacing: dimensions.statuslineMeterSpacing) {
                Text(reading(window))
                    .foregroundStyle(StatuslineColors.statuslineText(for: attention, colors: colors))
                    .lineLimit(1)
                bar
            }
        } else {
            bar
        }
    }

    private var accessibilitySummary: String {
        windows.map { "\(windowTitle($0)): \($0.usedPercent)% used, \(resetLabel($0.resetsAt))" }
            .joined(separator: "; ")
    }

    private func windowTitle(_ window: CodexQuotaWindow) -> String {
        var parts: [String] = []
        if let bucketID = window.bucketID, !bucketID.isEmpty {
            if let bucketName = window.bucketName, bucketName != bucketID {
                parts.append(bucketName)
            } else {
                parts.append(bucketID)
            }
        } else if let bucketName = window.bucketName, !bucketName.isEmpty {
            parts.append(bucketName)
        }
        parts.append(window.durationMinutes == nil ? window.slot.label : durationLabel(window.durationMinutes))
        return parts.joined(separator: " · ")
    }

    private func reading(_ window: CodexQuotaWindow) -> String {
        "\(resetLabel(window.resetsAt)) \(window.usedPercent)%"
    }

    private func durationLabel(_ minutes: Int?) -> String {
        guard let minutes else { return "duration unavailable" }
        guard minutes > 0 else { return "0m" }
        let days = minutes / (24 * 60)
        let hours = (minutes % (24 * 60)) / 60
        let remainder = minutes % 60
        if days > 0 {
            if hours > 0 { return "\(days)d \(hours)h" }
            return "\(days)d"
        }
        if hours > 0 {
            if remainder > 0 { return "\(hours)h \(remainder)m" }
            return "\(hours)h"
        }
        return "\(remainder)m"
    }

    private func resetLabel(_ date: Date?) -> String {
        guard let date else { return "—" }
        let seconds = date.timeIntervalSinceNow
        guard seconds > 0 else { return "now" }
        if seconds >= 86400 {
            return "\(Int((seconds + 43200) / 86400))d"
        }
        if seconds >= 3600 {
            return "\(Int((seconds + 1800) / 3600))h"
        }
        return "\(Int((seconds + 30) / 60))m"
    }
}

private struct CodexQuotaDetails: View, ThemedView {
    @Environment(\.theme) var theme

    let windows: [CodexQuotaWindow]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Codex quota")
                .font(.headline)
            ForEach(windows) { window in
                VStack(alignment: .leading, spacing: 4) {
                    Text(windowTitle(window))
                        .font(.subheadline)
                    detail("Window", value: window.slot.label)
                    detail("Duration", value: durationDescription(window))
                    detail("Used", value: "\(window.usedPercent)%")
                    detail("Resets", value: resetDescription(window))
                }
                if window.id != windows.last?.id {
                    Divider()
                }
            }
        }
        .padding(12)
        .frame(minWidth: 190, alignment: .leading)
    }

    private func detail(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(colors.foreground.opacity(colors.emphasis[.secondary]))
            Spacer(minLength: 8)
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .font(typography.caption.font)
    }

    private func windowTitle(_ window: CodexQuotaWindow) -> String {
        var parts: [String] = []
        if let bucketID = window.bucketID, !bucketID.isEmpty {
            if let bucketName = window.bucketName, bucketName != bucketID {
                parts.append("\(bucketName) (\(bucketID))")
            } else {
                parts.append(bucketID)
            }
        } else if let bucketName = window.bucketName, !bucketName.isEmpty {
            parts.append(bucketName)
        }
        parts.append(window.durationMinutes.map(durationLabel) ?? window.slot.label)
        return parts.joined(separator: " · ")
    }

    private func durationDescription(_ window: CodexQuotaWindow) -> String {
        guard let minutes = window.durationMinutes else { return "Unavailable" }
        if minutes % (24 * 60) == 0 { return "\(minutes / (24 * 60)) days" }
        if minutes % 60 == 0 { return "\(minutes / 60) hours" }
        return "\(minutes) minutes"
    }

    private func resetDescription(_ window: CodexQuotaWindow) -> String {
        guard let date = window.resetsAt else { return "Unavailable" }
        let seconds = date.timeIntervalSinceNow
        guard seconds > 0 else { return "Now" }
        if seconds >= 86400 { return "in \(Int((seconds + 43200) / 86400))d" }
        if seconds >= 3600 { return "in \(Int((seconds + 1800) / 3600))h" }
        return "in \(Int((seconds + 30) / 60))m"
    }

    private func durationLabel(_ minutes: Int) -> String {
        if minutes % (24 * 60) == 0 { return "\(minutes / (24 * 60))d" }
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }
}

#Preview("Codex quota") {
    CodexQuotaStrip(windows: [
        CodexQuotaWindow(
            bucketID: "codex",
            bucketName: "Codex",
            slot: .primary,
            usedPercent: 45,
            durationMinutes: 300,
            resetsAt: Date().addingTimeInterval(2 * 3600)
        ),
        CodexQuotaWindow(
            bucketID: "codex",
            bucketName: "Codex",
            slot: .secondary,
            usedPercent: 81,
            durationMinutes: 10_080,
            resetsAt: Date().addingTimeInterval(3 * 86400)
        ),
        CodexQuotaWindow(
            bucketID: "team",
            bucketName: nil,
            slot: .primary,
            usedPercent: 12,
            durationMinutes: nil,
            resetsAt: nil
        )
    ])
    .padding()
}
