import SwiftData
import SwiftUI

/// The overview the sidebar's Home row opens: the conversations that need the
/// user, then the quieter ones that are running or can be resumed.
struct HomeView: View {
    /// In sidebar order.
    let tasks: [WorkTask]
    let open: (_ taskID: UUID, _ tabID: UUID) -> Void
    let select: (_ taskID: UUID) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var context
    @State private var settings = AppSettings.shared
    @State private var composer = HomeComposerModel()
    @Query(sort: \TaskGroup.orderIndex) private var groups: [TaskGroup]

    var body: some View {
        HomeContent(
            feed: HomeFeed(tasks: tasks, source: .live),
            open: open,
            composer: HomeComposer(model: composer, onSend: start)
        )
            .task(id: HomeComposerInputs(tasks: tasks, groups: groups)) {
                await composer.refresh(
                    HomeComposerInputs(tasks: tasks, groups: groups),
                    recentTaskID: LastOpenTask.lastTask()
                )
            }
            .plumeTheme(bodySize: CGFloat(settings.chatFontSize))
            .environment(\.chatFontSize, CGFloat(settings.chatFontSize))
            .foregroundStyle(ThemeChrome.foreground(for: colorScheme) ?? .primary)
            .background(ThemeChrome.background(for: colorScheme) ?? Color.clear)
            .navigationTitle("Home")
    }

    private func start(_ message: ComposerHandOff.Message) async -> Bool {
        let home = HomeComposerTab.shared
        guard let task = await composer.start(
            message, choices: home.launchChoices, in: context, groups: groups, tasks: tasks
        ) else { return false }
        home.didStartTask()
        select(task.id)
        return true
    }
}

private struct HomeContent: View, ThemedView {
    let feed: HomeFeed
    let open: (UUID, UUID) -> Void
    let composer: HomeComposer
    @Environment(\.theme) var theme
    @State private var hangsMarkers = false
    #if DEBUG
    @AppStorage(HomeRowAlignment.collapseEmptyStatusSlotKey) private var collapsesEmptyStatusSlot = false
    @AppStorage(HomeRowAlignment.alignColorBarToTextKey) private var alignsColorBarToText = false
    #else
    private let collapsesEmptyStatusSlot = false
    private let alignsColorBarToText = false
    #endif

    private var rowAlignment: HomeRowAlignment {
        HomeRowAlignment(
            hangsMarkers: hangsMarkers,
            collapsesEmptyStatusSlot: collapsesEmptyStatusSlot,
            alignsColorBarToText: alignsColorBarToText
        )
    }
    @AppStorage("homeNeedsAttentionExpanded") private var needsAttentionExpanded = true
    @AppStorage("homeIdleExpanded") private var idleExpanded = true
    @AppStorage("homeNotStartedExpanded") private var notStartedExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                HomeGreetingHeader()
                composer
                needsYouSection
                if !feed.running.isEmpty {
                    quietSection("Running", items: feed.running)
                }
                if !feed.idle.isEmpty {
                    quietSection(
                        "Idle", items: feed.idle,
                        collapse: .init(id: AccessibilityID.homeIdleHeader, isExpanded: $idleExpanded, emphasis: .primary)
                    )
                }
                if !feed.notStarted.isEmpty {
                    quietSection(
                        "Not started", items: feed.notStarted,
                        collapse: .init(
                            id: AccessibilityID.homeNotStartedHeader, isExpanded: $notStartedExpanded,
                            emphasis: .secondary
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
                >= HomeRow.gutterWidth(alignsColorBarToText: alignsColorBarToText) + dimensions.horizontalEdgePadding
        } action: { hangsMarkers = $0 }
        .plumeID(AccessibilityID.homeView)
    }

    private var needsYouSection: some View {
        HomeSection(
            title: "Needs attention",
            header: .collapsible(.init(
                id: AccessibilityID.homeNeedsAttentionHeader, isExpanded: $needsAttentionExpanded,
                emphasis: .primary
            )),
            bleed: rowAlignment.bleed,
            count: max(feed.needsYou.count, 1)
        ) { transition in
            if feed.needsYou.isEmpty {
                Text("Nothing needs you right now.")
                    .font(typography.body.font)
                    .emphasis(.secondary)
                    .padding(.horizontal, HomeRow.horizontalPadding)
                    .plumeID(AccessibilityID.homeEmptyState)
                    .transition(transition(0))
            } else {
                ForEach(Array(feed.needsYou.enumerated()), id: \.element.id) { index, item in
                    HomeRow(item: item, isProminent: true, alignment: rowAlignment) { open(item.taskID, item.tabID) }
                        .padding(.top, index == 0 ? 0 : 4)
                        .transition(transition(index))
                }
            }
        }
    }

    private func quietSection(
        _ title: String,
        items: [HomeFeed.Item],
        collapse: HomeSectionCollapse? = nil
    ) -> some View {
        HomeSection(
            title: title,
            header: collapse.map(HomeSectionHeader.collapsible) ?? .plain(emphasis: .secondary),
            bleed: rowAlignment.bleed,
            count: items.count
        ) { transition in
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                HomeRow(item: item, isProminent: false, alignment: rowAlignment) {
                    open(item.taskID, item.tabID)
                }
                .transition(transition(index))
            }
        }
    }
}

private struct HomeSectionCollapse {
    let id: String
    let isExpanded: Binding<Bool>
    let emphasis: Emphasis
}

private enum HomeSectionHeader {
    case plain(emphasis: Emphasis)
    case collapsible(HomeSectionCollapse)
}

/// A header over rows that, when the header collapses, open and close as
/// `HomeSectionReveal` describes. `rows` gives each row the transition for
/// its index.
private struct HomeSection<Rows: View>: View, ThemedView {
    let title: String
    let header: HomeSectionHeader
    let bleed: CGFloat
    let count: Int
    @ViewBuilder let rows: (_ transition: @escaping (Int) -> AnyTransition) -> Rows
    @Environment(\.theme) var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Rows fade out before the height closes.
    @State private var rowsHidden = false

    private var isExpanded: Bool {
        guard case .collapsible(let collapse) = header else { return true }
        return collapse.isExpanded.wrappedValue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch header {
            case .plain(let emphasis):
                Text(title)
                    .font(typography.bodyLarge.font)
                    .emphasis(emphasis)
                    .padding(.horizontal, HomeRow.horizontalPadding)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.bottom, 4)
            case .collapsible(let collapse):
                CollapsibleSectionHeader(
                    title: title, id: collapse.id, isExpanded: isExpanded && !rowsHidden,
                    emphasis: collapse.emphasis, bleed: bleed
                ) { toggle(collapse.isExpanded) }
                .padding(.bottom, 4)
            }
            if isExpanded {
                rows { index in
                    HomeSectionReveal.rowTransition(index: index, count: count, reduceMotion: reduceMotion)
                }
                .opacity(rowsHidden ? 0 : 1)
            }
        }
    }

    private func toggle(_ isExpanded: Binding<Bool>) {
        if isExpanded.wrappedValue {
            guard !reduceMotion else {
                isExpanded.wrappedValue = false
                return
            }
            withAnimation(HomeSectionReveal.collapseFade) {
                rowsHidden = true
            } completion: {
                // Reopened while the rows were fading.
                guard rowsHidden else { return }
                withAnimation(HomeSectionReveal.collapseHeight) { isExpanded.wrappedValue = false }
                rowsHidden = false
            }
        } else {
            rowsHidden = false
            if reduceMotion {
                isExpanded.wrappedValue = true
            } else {
                withAnimation(HomeSectionReveal.expandHeight) { isExpanded.wrappedValue = true }
            }
        }
    }
}

private struct CollapsibleSectionHeader: View, ThemedView {
    let title: String
    let id: String
    let isExpanded: Bool
    let emphasis: Emphasis
    let bleed: CGFloat
    let toggle: () -> Void
    @Environment(\.theme) var theme
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Text(title)
                    .font(typography.bodyLarge.font)
                Image(systemName: "chevron.right")
                    .font(typography.caption.font)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                Spacer(minLength: 0)
            }
            .emphasis(emphasis)
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
        .plumeID(id, label: title, value: isExpanded ? "expanded" : "collapsed", invoke: toggle)
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

/// How a row's leading elements sit against the page's text keyline.
private struct HomeRowAlignment {
    static let collapseEmptyStatusSlotKey = "homeCollapseEmptyStatusSlot"
    static let alignColorBarToTextKey = "homeAlignColorBarToText"

    /// On a wide page the markers sit left of the keyline, in the gutter,
    /// so every section's text shares one leading edge.
    let hangsMarkers: Bool
    let collapsesEmptyStatusSlot: Bool
    let alignsColorBarToText: Bool

    var bleed: CGFloat {
        hangsMarkers ? HomeRow.gutterWidth(alignsColorBarToText: alignsColorBarToText) : 0
    }
}

private struct HomeRow: View, ThemedView {
    static let horizontalPadding: CGFloat = 10
    private static let markerWidth: CGFloat = 18
    private static let markerSpacing: CGFloat = 8
    private static let barWidth: CGFloat = 3
    private static let barTextGap: CGFloat = 8
    /// What sits left of the keyline: the status marker, and the color bar
    /// unless it is aligned to the keyline.
    static func gutterWidth(alignsColorBarToText: Bool) -> CGFloat {
        markerWidth + markerSpacing + (alignsColorBarToText ? 0 : barWidth + barTextGap)
    }
    private static let contextSeparator = "  •  "

    let item: HomeFeed.Item
    let isProminent: Bool
    let alignment: HomeRowAlignment
    let action: () -> Void
    @Environment(\.theme) var theme
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        let bleed = alignment.bleed
        return Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: Self.markerSpacing) {
                if !collapsesMarkerSlot {
                    leadingMarker
                }
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
                .padding(.leading, reservesBarSpace ? Self.barWidth + Self.barTextGap : 0)
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

    private var barColor: Color? {
        item.barTint.flatMap(theme.colors.color(for:))
    }

    private var reservesBarSpace: Bool {
        !alignment.alignsColorBarToText || barColor != nil
    }

    private var collapsesMarkerSlot: Bool {
        alignment.collapsesEmptyStatusSlot && !alignment.hangsMarkers
            && StatusBadge.isBlank(status: item.status, isUnread: item.isUnread)
    }

    @ViewBuilder
    private var colorBar: some View {
        if let color = barColor {
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
