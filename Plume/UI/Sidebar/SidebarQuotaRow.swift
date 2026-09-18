import SwiftUI

/// The account's 5h and 7d quota, at the bottom of the sidebar.
///
/// The same reading a chat's statusline shows, in the one place that is not
/// about any single chat — the quota is the account's, so it belongs beside
/// Archive and Settings rather than inside a conversation.
struct SidebarQuotaRow: View, ThemedView {
    @Environment(\.theme) var theme
    @State private var quota = QuotaStore.shared

    var body: some View {
        // Nothing to show before the first message of the app's life; a row
        // reading "—" would be worse than no row.
        if let snapshot = quota.snapshot {
            content(snapshot)
                .onAppear { quota.startTicking() }
        }
    }

    @ViewBuilder
    private func content(_ snapshot: QuotaSnapshot) -> some View {
        let isStale = QuotaFreshness.isStale(receivedAt: snapshot.receivedAt, now: quota.now)

        HStack(spacing: 10) {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .frame(width: 16)
            if let fiveHour = snapshot.rateLimit.fiveHour {
                StatuslineMeterSegment(
                    label: "5h",
                    utilization: fiveHour.utilization,
                    resetsAt: fiveHour.resetsAt,
                    now: quota.now,
                    isStale: isStale,
                    barWidth: StatuslineMeterWidth.shortQuota
                )
            }
            if let sevenDay = snapshot.rateLimit.sevenDay {
                StatuslineMeterSegment(
                    label: "7d",
                    utilization: sevenDay.utilization,
                    resetsAt: sevenDay.resetsAt,
                    now: quota.now,
                    isStale: isStale,
                    barWidth: StatuslineMeterWidth.quota
                )
            }
            Spacer(minLength: 0)
        }
        .font(typography.caption.font)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Account quota")
        .accessibilityIdentifier(AccessibilityID.sidebarQuotaRow)
    }
}
