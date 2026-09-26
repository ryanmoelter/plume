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
        .help(QuotaDescription.tooltip(visibleWindows.map(summary)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Codex account quota")
        .accessibilityValue(visibleWindows.flatMap { summary($0).lines }.joined(separator: "; "))
        .plumeID(sidebar ? "sidebar.codex-quota" : "statusline.codex-quota")
        .onAppear { clock.startTicking() }
        .popover(isPresented: $showingDetails) {
            QuotaDetailsPopover(title: "Codex quota", summaries: visibleWindows.map(summary))
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
            pacing: window.windowLength.flatMap {
                QuotaFreshness.pacing(resetsAt: window.resetsAt, now: clock.now, window: $0)
            },
            readingAlignment: sidebar ? .leading : .center,
            isStale: quota.isStale(window, now: clock.now)
        )
        .help(summary(window).text)
    }

    private func summary(_ window: CodexQuotaWindow) -> QuotaWindowSummary {
        QuotaDescription.summary(
            timeframe: window.timeframe,
            utilization: window.utilization,
            resetsAt: window.resetsAt,
            windowLength: window.windowLength,
            receivedAt: quota.receivedAt(for: window),
            now: clock.now
        )
    }
}

extension CodexQuotaWindow {
    var windowLength: TimeInterval? { durationMinutes.map { TimeInterval($0) * 60 } }

    /// Named by duration, never by slot: the server moves a window between
    /// slots when the account's limits change. The `codex` bucket goes
    /// unnamed, since it is the only one most accounts have.
    var timeframe: String? {
        let duration = durationMinutes.map(QuotaDescription.timeframe(minutes:))
        guard let bucket = bucketName ?? bucketID, bucket != "codex" else { return duration }
        return [bucket, duration].compactMap { $0 }.joined(separator: " ")
    }
}
