import SwiftUI

/// The overview the sidebar's Home row opens: the conversations that need the
/// user, then the quieter ones that are running or can be resumed.
struct HomeView: View {
    /// In sidebar order.
    let tasks: [WorkTask]
    let open: (_ taskID: UUID, _ tabID: UUID) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var settings = AppSettings.shared

    var body: some View {
        HomeContent(feed: HomeFeed(tasks: tasks, source: .live), open: open)
            .plumeTheme(bodySize: CGFloat(settings.chatFontSize))
            .themeTint(colorScheme: colorScheme)
            .navigationTitle("Home")
    }
}

private struct HomeContent: View, ThemedView {
    let feed: HomeFeed
    let open: (UUID, UUID) -> Void
    @Environment(\.theme) var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                HomeGreetingHeader()
                needsYouSection
                if !feed.running.isEmpty {
                    quietSection("Running", items: feed.running)
                }
                if !feed.notStarted.isEmpty {
                    quietSection("Not started", items: feed.notStarted)
                }
            }
            .frame(maxWidth: dimensions.contentWidth, alignment: .leading)
            .padding(.horizontal, dimensions.horizontalEdgePadding)
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity)
        }
        .plumeID(AccessibilityID.homeView)
    }

    private var needsYouSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Needs you")
                .emphasis(.primary)
            if feed.needsYou.isEmpty {
                Text("Nothing needs you right now.")
                    .font(typography.body.font)
                    .emphasis(.secondary)
                    .padding(.horizontal, HomeRow.horizontalPadding)
                    .plumeID(AccessibilityID.homeEmptyState)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(feed.needsYou) { item in
                        HomeRow(item: item, isProminent: true) { open(item.taskID, item.tabID) }
                    }
                }
            }
        }
    }

    private func quietSection(_ title: String, items: [HomeFeed.Item]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle(title)
                .emphasis(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(items) { item in
                    HomeRow(item: item, isProminent: false) { open(item.taskID, item.tabID) }
                }
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(typography.bodyLarge.font)
            .padding(.horizontal, HomeRow.horizontalPadding)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Re-reads the clock each minute, so the greeting turns over without the
/// whole feed redrawing.
private struct HomeGreetingHeader: View, ThemedView {
    @Environment(\.theme) var theme

    var body: some View {
        TimelineView(.everyMinute) { context in
            let greeting = HomeGreeting(date: context.date)
            Label {
                Text(greeting.title)
            } icon: {
                Image(systemName: greeting.symbolName)
                    .symbolRenderingMode(.multicolor)
            }
            .font(typography.headline.font)
            .padding(.horizontal, HomeRow.horizontalPadding)
            .accessibilityAddTraits(.isHeader)
            .plumeID(AccessibilityID.homeGreeting, value: greeting.title)
        }
    }
}

private struct HomeRow: View, ThemedView {
    static let horizontalPadding: CGFloat = 10

    let item: HomeFeed.Item
    let isProminent: Bool
    let action: () -> Void
    @Environment(\.theme) var theme
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    titleLine
                    if isProminent, let reason = item.reason {
                        Text(reasonText(reason))
                            .font(typography.body.font)
                            .emphasis(.secondary)
                            .lineLimit(2)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 8)
                StatusBadge(status: item.status, workStartedAt: item.workStartedAt, isUnread: item.isUnread)
                    .font(isProminent ? typography.body.font : typography.caption.font)
            }
            .padding(.horizontal, Self.horizontalPadding)
            .padding(.vertical, isProminent ? 8 : 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: SidebarMetrics.selectionCornerRadius)
                    .fill(isHovered ? Color.chatSurface(.backgroundTint, colorScheme: colorScheme) : .clear)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .plumeHover { isHovered = $0 }
        .plumeID(AccessibilityID.homeRow, label: label, value: item.reason, invoke: action)
    }

    private var label: String {
        [item.taskTitle, item.tabTitle].compactMap { $0 }.joined(separator: " / ")
    }

    @ViewBuilder
    private var titleLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(item.taskTitle)
                .font(isProminent ? typography.body.semibold : typography.caption.font)
                .emphasis(isProminent ? .primary : .secondary)
            if let tabTitle = item.tabTitle {
                Text(tabTitle)
                    .font(typography.caption.font)
                    .emphasis(.subtle)
            }
        }
        .lineLimit(1)
        .truncationMode(.tail)
    }

    /// Only the unread preview is prose; a status reason shows as written.
    private func reasonText(_ reason: String) -> AttributedString {
        item.reasonIsPreview
            ? MarkdownCache.inline(reason)
            : AttributedString(reason)
    }
}
