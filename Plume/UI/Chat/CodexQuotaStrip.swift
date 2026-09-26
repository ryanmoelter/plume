import SwiftUI

/// Provider-specific windows use the shared meter styling while retaining
/// bucket identity and an aggregate popup for the collapsed presentation.
struct CodexQuotaStrip: View, ThemedView {
    @Environment(\.theme) var theme
    @State private var showingDetails = false
    @State private var clock = QuotaStore.shared
    @State private var quota = CodexQuotaStore.shared

    enum Layout { case wide, stacked }
    let windows: [CodexQuotaWindow]
    var layout: Layout = .wide
    var sidebar = false

    private var visibleWindows: [CodexQuotaWindow] { windows.filter { $0.usedPercent > 0 } }

    var body: some View {
        Button { showingDetails = true } label: {
            Group {
                switch layout {
                case .wide:
                    HStack(alignment: .top, spacing: dimensions.statuslineSegmentSpacing) {
                        ForEach(visibleWindows) { window in meter(window, showsReading: true).transition(.opacity) }
                    }
                    .fixedSize()
                case .stacked:
                    VStack(alignment: .leading, spacing: dimensions.statuslineStackedBarSpacing) {
                        ForEach(visibleWindows) { window in meter(window, showsReading: false).transition(.opacity) }
                    }
                    .frame(minHeight: 22)
                }
            }
            .contentShape(Rectangle())
            .animation(QuotaTransition.animation, value: visibleWindows.map(\.id))
        }
        .buttonStyle(.plain)
        .font(typography.caption.font)
        .help(visibleWindows.map { tooltip($0) }.joined(separator: "\n"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Codex account quota")
        .accessibilityValue(visibleWindows.map { tooltip($0) }.joined(separator: "; "))
        .plumeID(sidebar ? "sidebar.codex-quota" : "statusline.codex-quota")
        .onAppear { clock.startTicking() }
        .popover(isPresented: $showingDetails) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Codex quota").font(.headline)
                ForEach(visibleWindows) { window in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(window.quotaTitle).font(.subheadline)
                        Text("Used: \(window.usedPercent)%")
                        Text("Window: \(window.durationLabel) (\(window.slot.label))")
                        Text(resetDescription(window))
                        if quota.isStale(window, now: clock.now) {
                            Text("Reading may be out of date").foregroundStyle(.secondary)
                        }
                    }
                    if window.id != visibleWindows.last?.id { Divider() }
                }
            }
            .font(typography.caption.font)
            .padding(12)
            .frame(minWidth: 220, alignment: .leading)
            .environment(\.theme, theme)
        }
    }

    private func meter(_ window: CodexQuotaWindow, showsReading: Bool) -> some View {
        let short = (window.durationMinutes ?? .max) <= 300
        let width = sidebar
            ? (short ? StatuslineMeterWidth.sidebarShortQuota : StatuslineMeterWidth.sidebarQuota)
            : (short ? StatuslineMeterWidth.shortQuota : StatuslineMeterWidth.quota)
        return StackedMeter(
            reading: "\(QuotaFreshness.resetLabel(resetsAt: window.resetsAt, now: clock.now, fallback: "—")) \(window.usedPercent)%",
            fraction: StatuslineMeterMath.fraction(percent: Double(window.usedPercent)),
            barWidth: width,
            attention: StatuslineAttention.attention(percent: Double(window.usedPercent)),
            showsReading: showsReading,
            pacing: window.durationMinutes.flatMap {
                QuotaFreshness.pacing(resetsAt: window.resetsAt, now: clock.now, window: Double($0) * 60)
            },
            readingAlignment: sidebar ? .leading : .center,
            isStale: quota.isStale(window, now: clock.now)
        )
        .help(tooltip(window))
    }

    private func resetDescription(_ window: CodexQuotaWindow) -> String {
        guard let reset = window.resetsAt else { return "Reset time unavailable" }
        return "Resets \(QuotaFreshness.absoluteResetLabel(resetsAt: reset, now: clock.now))"
    }

    private func tooltip(_ window: CodexQuotaWindow) -> String {
        let stale = quota.isStale(window, now: clock.now) ? "; reading may be out of date" : ""
        return "\(window.quotaTitle): \(window.usedPercent)% used; \(resetDescription(window))\(stale)"
    }
}

extension CodexQuotaWindow {
    var durationLabel: String {
        guard let minutes = durationMinutes else { return "Duration unavailable" }
        if minutes > 0 && minutes % 1440 == 0 { return "\(minutes / 1440)d" }
        if minutes > 0 && minutes % 60 == 0 { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }

    var quotaTitle: String {
        let bucket = bucketName ?? bucketID ?? "Codex"
        return "\(bucket) · \(durationMinutes == nil ? slot.label : durationLabel)"
    }
}
