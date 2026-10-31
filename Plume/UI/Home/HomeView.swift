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
            .foregroundStyle(ThemeChrome.foreground(for: colorScheme) ?? .primary)
            .background(ThemeChrome.background(for: colorScheme) ?? Color.clear)
            .navigationTitle("Home")
    }
}

private struct HomeContent: View, ThemedView {
    let feed: HomeFeed
    let open: (UUID, UUID) -> Void
    @Environment(\.theme) var theme
    @State private var hangsMarkers = false
    @AppStorage("homeIdleExpanded") private var idleExpanded = true
    @AppStorage("homeNotStartedExpanded") private var notStartedExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                HomeGreetingHeader()
                needsYouSection
                if !feed.running.isEmpty {
                    quietSection("Running", items: feed.running)
                }
                if !feed.idle.isEmpty {
                    quietSection(
                        "Idle", items: feed.idle,
                        collapse: CollapseControl(
                            id: AccessibilityID.homeIdleHeader, isExpanded: $idleExpanded
                        )
                    )
                }
                if !feed.notStarted.isEmpty {
                    quietSection(
                        "Not started", items: feed.notStarted,
                        collapse: CollapseControl(
                            id: AccessibilityID.homeNotStartedHeader, isExpanded: $notStartedExpanded
                        )
                    )
                }
            }
            .frame(maxWidth: dimensions.contentWidth, alignment: .leading)
            .padding(.horizontal, dimensions.horizontalEdgePadding)
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity)
        }
        .onGeometryChange(for: Bool.self) { proxy in
            (proxy.size.width - dimensions.contentWidth) / 2
                >= HomeRow.markerGutterWidth + dimensions.horizontalEdgePadding
        } action: { hangsMarkers = $0 }
        .plumeID(AccessibilityID.homeView)
    }

    private var needsYouSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            if feed.needsYou.isEmpty {
                Text("Nothing needs you right now.")
                    .font(typography.body.font)
                    .emphasis(.secondary)
                    .padding(.horizontal, HomeRow.horizontalPadding)
                    .plumeID(AccessibilityID.homeEmptyState)
            } else {
                ForEach(feed.needsYou) { item in
                    HomeRow(item: item, isProminent: true, hangsMarkers: hangsMarkers) { open(item.taskID, item.tabID) }
                }
            }
        }
    }

    private struct CollapseControl {
        let id: String
        let isExpanded: Binding<Bool>
    }

    private func quietSection(
        _ title: String,
        items: [HomeFeed.Item],
        collapse: CollapseControl? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let collapse {
                CollapsibleSectionHeader(
                    title: title, id: collapse.id, isExpanded: collapse.isExpanded, hangsMarkers: hangsMarkers
                )
            } else {
                sectionTitle(title)
                    .emphasis(.secondary)
            }
            if collapse?.isExpanded.wrappedValue ?? true {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(items) { item in
                        HomeRow(item: item, isProminent: false, hangsMarkers: hangsMarkers) {
                            open(item.taskID, item.tabID)
                        }
                    }
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

private struct CollapsibleSectionHeader: View, ThemedView {
    let title: String
    let id: String
    @Binding var isExpanded: Bool
    let hangsMarkers: Bool
    @Environment(\.theme) var theme
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        let bleed = hangsMarkers ? HomeRow.markerGutterWidth : 0
        Button { isExpanded.toggle() } label: {
            HStack(spacing: 6) {
                Text(title)
                    .font(typography.bodyLarge.font)
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(typography.caption.font)
                Spacer(minLength: 0)
            }
            .emphasis(.secondary)
            .padding(.horizontal, HomeRow.horizontalPadding + bleed)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: SidebarMetrics.selectionCornerRadius)
                    .fill(isHovered ? Color.chatSurface(.backgroundTint, colorScheme: colorScheme) : .clear)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isHeader)
        .plumeHover { isHovered = $0 }
        .plumeID(id, label: title, value: isExpanded ? "expanded" : "collapsed") { isExpanded.toggle() }
        .padding(.horizontal, -bleed)
    }
}

/// Re-reads the clock each minute, so the greeting turns over without the
/// whole feed redrawing.
private struct HomeGreetingHeader: View, ThemedView {
    @Environment(\.theme) var theme

    var body: some View {
        TimelineView(.everyMinute) { context in
            let greeting = HomeGreeting(date: context.date)
            HStack(spacing: 6) {
                Text(greeting.title)
                Image(systemName: greeting.symbolName)
                    .symbolRenderingMode(.multicolor)
            }
            .font(proseTypography.headline.font)
            .padding(.horizontal, HomeRow.horizontalPadding)
            .accessibilityAddTraits(.isHeader)
            .plumeID(AccessibilityID.homeGreeting, value: greeting.title)
        }
    }
}

private struct HomeRow: View, ThemedView {
    static let horizontalPadding: CGFloat = 10
    private static let markerWidth: CGFloat = 18
    private static let markerSpacing: CGFloat = 8
    private static let barWidth: CGFloat = 3
    private static let barTextGap: CGFloat = 8
    /// What sits before the text column: the status marker and the color bar.
    static let markerGutterWidth = markerWidth + markerSpacing + barWidth + barTextGap
    private static let contextSeparator = "  •  "

    let item: HomeFeed.Item
    let isProminent: Bool
    /// On a wide page the markers sit left of the text column, in the gutter,
    /// so every section's text shares one leading edge.
    let hangsMarkers: Bool
    let action: () -> Void
    @Environment(\.theme) var theme
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        let bleed = hangsMarkers ? Self.markerGutterWidth : 0
        return Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                leadingMarker
                VStack(alignment: .leading, spacing: 2) {
                    titleLine
                    if isProminent, let reason = item.reason {
                        Text(reasonText(reason))
                            .font(typography.body.font)
                            .emphasis(.secondary)
                            .lineLimit(2)
                            .truncationMode(.tail)
                    }
                    contextLine
                }
                .padding(.leading, Self.barWidth + Self.barTextGap)
                .overlay(alignment: .leading) { colorBar }
                Spacer(minLength: 8)
                if item.status.isActive, let workStartedAt = item.workStartedAt {
                    ElapsedLabel(since: workStartedAt)
                        .font(typography.caption.font)
                        .emphasis(.secondary)
                }
            }
            .padding(.horizontal, Self.horizontalPadding)
            .padding(.trailing, bleed)
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
        // Outermost, so the fill, the click target and the hover region all
        // span the gutter: negative padding shrinks only the size reported
        // to the column, and anything applied outside it gets that size.
        .padding(.horizontal, -bleed)
    }

    private var titleEmphasis: Emphasis {
        item.isInactive ? .secondary : .primary
    }

    private var tintOpacity: Double {
        item.isInactive ? TaskRowView.inactiveTintOpacity : 1
    }

    @ViewBuilder
    private var colorBar: some View {
        if let color = item.barTint.flatMap(theme.colors.color(for:)) {
            Capsule()
                .fill(color)
                .frame(width: Self.barWidth)
                .padding(.vertical, -3)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var leadingMarker: some View {
        if StatusBadge.isBlank(status: item.status, isUnread: item.isUnread) {
            Color.clear.frame(width: Self.markerWidth, height: 0)
        } else {
            StatusBadge(status: item.status, isUnread: item.isUnread, showsElapsed: false)
                .font(isProminent ? typography.body.font : typography.caption.font)
                .frame(width: Self.markerWidth)
        }
    }

    private var label: String {
        [item.taskTitle, item.tabTitle].compactMap { $0 }.joined(separator: " / ")
    }

    @ViewBuilder
    private var titleLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let iconName = item.iconName {
                taskIcon(iconName)
            }
            Text(item.taskTitle)
                .font(isProminent ? typography.body.semibold : typography.caption.font)
                .emphasis(titleEmphasis)
            if let tabTitle = item.tabTitle {
                Text(tabTitle)
                    .font(typography.caption.font)
                    .emphasis(.subtle)
            }
        }
        .lineLimit(1)
        .truncationMode(.tail)
    }

    @ViewBuilder
    private func taskIcon(_ name: String) -> some View {
        let icon = Image(systemName: name)
            .symbolRenderingMode(SidebarIcons.renderingMode(twoTone: AppSettings.shared.sidebarTwoToneIcons))
            .font(isProminent ? typography.body.font : typography.caption.font)
        if let color = item.iconTint.flatMap(theme.colors.color(for:)) {
            icon.foregroundStyle(color.opacity(tintOpacity))
        } else {
            icon.emphasis(titleEmphasis)
        }
    }

    @ViewBuilder
    private var contextLine: some View {
        let segments = item.context.segments
        if !segments.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                    if index > 0 {
                        Text(Self.contextSeparator).emphasis(.subtle)
                    }
                    contextSegment(segment)
                }
            }
            .font(typography.caption.font)
            .imageScale(.small)
            .emphasis(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
    }

    @ViewBuilder
    private func contextSegment(_ segment: HomeRowContext.Segment) -> some View {
        switch segment {
        case .project(let name):
            Text(name)
        case .branch(let branch, let isWorktree, let isLocalOnly):
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                if isWorktree { Image(systemName: "tree") }
                Text(branch)
                if isLocalOnly, let glyph = PullRequestChipContent.glyphs(for: .localOnly).first,
                   let symbol = glyph.symbol {
                    Image(systemName: symbol).help(glyph.label)
                }
            }
        case .issue(let reference, let more), .pullRequest(let reference, let more):
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                if let icon = reference.icon {
                    Image(systemName: icon.symbol)
                        .foregroundStyle(chipPalette.color(for: icon.tint))
                }
                Text(more > 0 ? "\(reference.id) +\(more)" : reference.id)
                    .fixedSize()
            }
        }
    }

    private var chipPalette: ReferenceChipPalette {
        ReferenceChipPalette(colors: theme.colors, colorScheme: colorScheme)
    }

    /// Only the unread preview is prose; a status reason shows as written.
    private func reasonText(_ reason: String) -> AttributedString {
        item.reasonIsPreview
            ? MarkdownCache.inline(reason)
            : AttributedString(reason)
    }
}
