#if DEBUG
import SwiftUI

/// Names the branch and build time of this debug binary, to tell worktrees'
/// builds apart. The `TimelineView` rolls "today" over without a relaunch.
struct SidebarBuildLabel: View, ThemedView {
    @Environment(\.theme) var theme

    private static let branch = BuildInfo.branch
    private static let builtAt = BuildInfo.builtAt

    var body: some View {
        TimelineView(.everyMinute) { context in
            if let label = BuildInfo.label(
                branch: Self.branch,
                builtAt: Self.builtAt,
                now: context.date,
                calendar: .current,
                locale: .current
            ) {
                Text(label)
                    .font(typography.caption.font)
                    .foregroundStyle(colors.foreground.opacity(colors.emphasis[.secondary]))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .padding(.horizontal, SidebarFooterMetrics.inset)
                    .help(helpText)
                    .plumeID(AccessibilityID.sidebarBuildLabel, value: label)
            }
        }
    }

    private var helpText: String {
        let root = BuildInfo.sourceRoot?.path ?? "Unknown source root"
        guard let builtAt = Self.builtAt else { return root }
        let absolute = builtAt.formatted(date: .abbreviated, time: .standard)
        return "\(root)\nBuilt \(absolute)"
    }
}
#endif
