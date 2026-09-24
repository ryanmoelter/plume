#if DEBUG
import SwiftUI

/// Names the branch, worktree and build time of this debug binary, to tell
/// worktrees' builds apart. The `TimelineView` rolls "today" over without a
/// relaunch.
struct SidebarBuildLabel: View, ThemedView {
    @Environment(\.theme) var theme

    private static let branch = BuildInfo.branch
    private static let worktreeName = BuildInfo.worktreeName
    private static let builtAt = BuildInfo.builtAt

    var body: some View {
        TimelineView(.everyMinute) { context in
            let buildTime = Self.builtAt.map {
                BuildInfo.buildTime($0, now: context.date, calendar: .current, locale: .current)
            }
            let details = [Self.worktreeName, buildTime].compactMap { $0 }
            if Self.branch != nil || !details.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    if let branch = Self.branch {
                        Text(branch).font(typography.caption.font)
                    }
                    ForEach(details, id: \.self) { detail in
                        Text(detail).font(.system(size: typography.size(steps: -2)))
                    }
                }
                .foregroundStyle(colors.foreground.opacity(colors.emphasis[.secondary]))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .padding(.horizontal, SidebarFooterMetrics.inset)
                .help(helpText)
                .plumeID(
                    AccessibilityID.sidebarBuildLabel,
                    value: ([Self.branch].compactMap { $0 } + details).joined(separator: "\n")
                )
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
