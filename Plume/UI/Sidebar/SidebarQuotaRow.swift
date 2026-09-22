import SwiftUI

/// The account's 5h and 7d quota, at the bottom of the sidebar.
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
    @State private var quota = QuotaStore.shared

    var body: some View {
        content(quota.snapshot)
            .onAppear { quota.startTicking() }
    }

    @ViewBuilder
    private func content(_ snapshot: QuotaSnapshot?) -> some View {
        let isStale = snapshot.map {
            QuotaFreshness.isStale(receivedAt: $0.receivedAt, now: quota.now)
        } ?? false

        HStack(spacing: 8) {
            icon(snapshot)
                .frame(width: 16)
                // A row with nothing to say reads as quiet as one gone stale.
                .opacity(isStale || snapshot == nil ? colors.emphasis[.secondary] : 1)
            if let snapshot {
                meters(snapshot, isStale: isStale)
            } else {
                Text("\u{2014}")
                    .foregroundStyle(colors.foreground.opacity(colors.emphasis[.secondary]))
                    .accessibilityLabel("No quota reading yet")
            }
            Spacer(minLength: 0)
        }
        .font(typography.caption.font)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .padding(.horizontal, SidebarFooterMetrics.inset)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Account quota")
        .accessibilityIdentifier(AccessibilityID.sidebarQuotaRow)
    }

    /// The ring fills with the five-hour window, the one that moves fast
    /// enough to be worth a glance. A gauge would read as effort, which is
    /// what it means everywhere else in the app.
    private func icon(_ snapshot: QuotaSnapshot?) -> some View {
        Image(
            systemName: "ring.dashed",
            variableValue: snapshot?.rateLimit.fiveHour?.utilization ?? 0
        )
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
                    barWidth: StatuslineMeterWidth.sidebarShortQuota,
                    windowLength: QuotaWindowLength.fiveHour,
                    readingAlignment: .leading
                )
            }
            if let sevenDay = snapshot.rateLimit.sevenDay {
                StatuslineMeterSegment(
                    label: "7d",
                    utilization: sevenDay.utilization,
                    resetsAt: sevenDay.resetsAt,
                    now: quota.now,
                    isStale: isStale,
                    barWidth: StatuslineMeterWidth.sidebarQuota,
                    windowLength: QuotaWindowLength.sevenDay,
                    readingAlignment: .leading
                )
            }
        }
    }
}
