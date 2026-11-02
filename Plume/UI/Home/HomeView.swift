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
    @State private var hasRefreshed = false
    @Query(sort: \TaskGroup.orderIndex) private var groups: [TaskGroup]

    private var composer: HomeComposerModel { HomeComposerTab.shared.model }

    var body: some View {
        HomeContent(
            feed: HomeFeed(tasks: tasks, source: .live),
            open: open,
            composer: HomeComposer(model: composer, onSend: start)
        )
            .task(id: HomeComposerInputs(tasks: tasks, groups: groups)) {
                let picksDefaults = !hasRefreshed
                hasRefreshed = true
                await composer.refresh(
                    HomeComposerInputs(tasks: tasks, groups: groups),
                    recentTaskID: LastOpenTask.lastTask(),
                    picksDefaults: picksDefaults
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
        guard let task = await composer.start(message, choices: home.launchChoices, in: context) else {
            return false
        }
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
    @State private var scrollPosition = ScrollPosition()
    @State private var scrollGeometry = HomeScrollGeometry()
    @State private var scrollReserve: CGFloat = 0

    private var bleed: CGFloat {
        hangsMarkers ? HomeRow.gutterWidth : 0
    }

    @AppStorage("homeNeedsAttentionExpanded") private var needsAttentionExpanded = true
    @AppStorage("homeIdleExpanded") private var idleExpanded = true
    @AppStorage("homeFromLastTimeExpanded") private var fromLastTimeExpanded = false
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
                        collapse: .init(
                            id: AccessibilityID.homeIdleHeader, isExpanded: $idleExpanded,
                            emphasis: .primary, itemCount: feed.idle.count
                        )
                    )
                }
                if !feed.fromLastTime.isEmpty {
                    quietSection(
                        "From last time", items: feed.fromLastTime,
                        collapse: .init(
                            id: AccessibilityID.homeFromLastTimeHeader, isExpanded: $fromLastTimeExpanded,
                            emphasis: .secondary, itemCount: feed.fromLastTime.count
                        )
                    )
                }
                if !feed.notStarted.isEmpty {
                    quietSection(
                        "Not started", items: feed.notStarted,
                        collapse: .init(
                            id: AccessibilityID.homeNotStartedHeader, isExpanded: $notStartedExpanded,
                            emphasis: .secondary, itemCount: feed.notStarted.count
                        )
                    )
                }
            }
            .frame(maxWidth: dimensions.contentWidth, alignment: .leading)
            .padding(.horizontal, dimensions.horizontalEdgePadding)
            .padding(.vertical, 40)
            .padding(.bottom, scrollReserve)
            .frame(maxWidth: .infinity)
            .coordinateSpace(.named(HomeScrollGeometry.contentSpace))
        }
        .scrollPosition($scrollPosition)
        // `scrollTo(y:)` takes an offset measured from the resting position,
        // which sits `contentInsets.top` above zero under the title bar.
        .onScrollGeometryChange(for: HomeScrollGeometry.Snapshot.self) { geometry in
            HomeScrollGeometry.Snapshot(
                offset: geometry.contentOffset.y + geometry.contentInsets.top,
                visibleHeight: geometry.containerSize.height
            )
        } action: { _, snapshot in
            scrollGeometry.latest = snapshot
        }
        .onGeometryChange(for: Bool.self) { proxy in
            (proxy.size.width - dimensions.contentWidth) / 2
                >= HomeRow.gutterWidth + dimensions.horizontalEdgePadding
        } action: { hangsMarkers = $0 }
        .plumeID(AccessibilityID.homeView)
    }

    private var sectionStyle: HomeSectionStyle {
        HomeSectionStyle(
            bleed: bleed, reveal: reveal, endReveal: endReveal
        )
    }

    private func reveal(_ section: CGRect, animation: Animation?) {
        guard let snapshot = scrollGeometry.latest else { return }
        let delta = HomeSectionReveal.scrollDelta(
            headerTop: section.minY - snapshot.offset,
            sectionBottom: section.maxY - snapshot.offset,
            visibleHeight: snapshot.visibleHeight
        )
        guard delta > 0 else { return }
        // The scroll view clamps a scroll to the page's height as drawn, which
        // lags the opening section until its animation ends. Reserving the
        // section's height below the page keeps the target in reach throughout.
        var unanimated = Transaction(animation: nil)
        unanimated.disablesAnimations = true
        withTransaction(unanimated) { scrollReserve = section.height }
        withAnimation(animation) {
            scrollPosition.scrollTo(y: snapshot.offset + delta)
        } completion: {
            // Without an animation the section has no opening to wait for.
            if animation == nil { endReveal() }
        }
    }

    private func endReveal() {
        guard scrollReserve > 0 else { return }
        var unanimated = Transaction(animation: nil)
        unanimated.disablesAnimations = true
        withTransaction(unanimated) { scrollReserve = 0 }
    }

    private var needsYouSection: some View {
        HomeSection(
            title: "Needs attention",
            header: .collapsible(.init(
                id: AccessibilityID.homeNeedsAttentionHeader, isExpanded: $needsAttentionExpanded,
                emphasis: .primary, itemCount: feed.needsYou.count, marksUnread: !feed.needsYou.isEmpty
            )),
            style: sectionStyle,
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
                    HomeRow(item: item, isProminent: true, hangsMarkers: hangsMarkers) { open(item.taskID, item.tabID) }
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
            style: sectionStyle,
            count: items.count
        ) { transition in
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                HomeRow(item: item, isProminent: false, hangsMarkers: hangsMarkers) {
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
    /// Shown beside the chevron while the section is collapsed.
    let itemCount: Int
    var marksUnread = false
}

private enum HomeSectionHeader {
    case plain(emphasis: Emphasis)
    case collapsible(HomeSectionCollapse)
}

private struct HomeSectionStyle {
    let bleed: CGFloat
    /// Scrolls just far enough to show a section that has opened, given its
    /// frame in `HomeScrollGeometry.contentSpace`, on the animation its height
    /// opens with.
    let reveal: (_ section: CGRect, _ animation: Animation?) -> Void
    /// Called once the section has finished opening.
    let endReveal: () -> Void
}

/// Where the page is scrolled to. Not observable, so scrolling never
/// re-renders the page.
private final class HomeScrollGeometry {
    static let contentSpace = "homeScrollContent"

    struct Snapshot: Equatable {
        var offset: CGFloat
        var visibleHeight: CGFloat
    }

    var latest: Snapshot?
}

/// A header over rows that, when the header collapses, open and close as
/// `HomeSectionReveal` describes. `rows` gives each row the transition for
/// its index.
private struct HomeSection<Rows: View>: View, ThemedView {
    let title: String
    let header: HomeSectionHeader
    let style: HomeSectionStyle
    let count: Int
    @ViewBuilder let rows: (_ transition: @escaping (Int) -> AnyTransition) -> Rows
    @Environment(\.theme) var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// What the open and close animate, rather than the stored setting:
    /// `@AppStorage` delivers its new value through defaults observation, in
    /// a transaction of its own, so a write inside `withAnimation` can render
    /// unanimated.
    @State private var isShown: Bool
    /// Rows fade out before the height closes.
    @State private var rowsHidden = false
    @State private var revealsOnNextLayout = false

    init(
        title: String,
        header: HomeSectionHeader,
        style: HomeSectionStyle,
        count: Int,
        @ViewBuilder rows: @escaping (_ transition: @escaping (Int) -> AnyTransition) -> Rows
    ) {
        self.title = title
        self.header = header
        self.style = style
        self.count = count
        self.rows = rows
        _isShown = State(initialValue: Self.storedExpansion(of: header))
    }

    private static func storedExpansion(of header: HomeSectionHeader) -> Bool {
        guard case .collapsible(let collapse) = header else { return true }
        return collapse.isExpanded.wrappedValue
    }

    private var isOpen: Bool { isShown && !rowsHidden }

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
                    title: title, collapse: collapse, isExpanded: isOpen, bleed: style.bleed
                ) { toggle(collapse.isExpanded) }
                .padding(.bottom, 4)
            }
            if isShown {
                rows { index in
                    HomeSectionReveal.rowTransition(
                        index: index, count: count, reduceMotion: reduceMotion
                    )
                }
                .opacity(rowsHidden ? 0 : 1)
            }
        }
        // The frame here is the layout's, already at the opened height while
        // the animation is still under way.
        .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .named(HomeScrollGeometry.contentSpace))
        } action: { frame in
            guard revealsOnNextLayout else { return }
            revealsOnNextLayout = false
            style.reveal(frame, reduceMotion ? nil : HomeSectionReveal.expandHeight(count: count))
        }
        .onChange(of: Self.storedExpansion(of: header)) { _, stored in
            guard stored != isShown else { return }
            rowsHidden = false
            isShown = stored
        }
    }

    private func toggle(_ stored: Binding<Bool>) {
        if isOpen {
            revealsOnNextLayout = false
            guard !reduceMotion else {
                isShown = false
                stored.wrappedValue = false
                return
            }
            withAnimation(HomeSectionReveal.collapseFade) {
                rowsHidden = true
            } completion: {
                // Reopened while the rows were fading.
                guard rowsHidden else { return }
                withAnimation(HomeSectionReveal.collapseHeight(count: count)) {
                    isShown = false
                    rowsHidden = false
                }
                stored.wrappedValue = false
            }
        } else {
            revealsOnNextLayout = !isShown
            withAnimation(reduceMotion ? nil : HomeSectionReveal.expandHeight(count: count)) {
                rowsHidden = false
                isShown = true
            } completion: {
                style.endReveal()
            }
            stored.wrappedValue = true
        }
    }
}

private struct CollapsibleSectionHeader: View, ThemedView {
    let title: String
    let collapse: HomeSectionCollapse
    let isExpanded: Bool
    let bleed: CGFloat
    let toggle: () -> Void
    @Environment(\.theme) var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Text(title)
                    .font(typography.bodyLarge.font)
                Image(systemName: "chevron.right")
                    .font(typography.caption.font)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                if !isExpanded {
                    collapsedSummary
                }
                Spacer(minLength: 0)
            }
            .animation(reduceMotion ? nil : HomeSectionReveal.chevron, value: isExpanded)
            .emphasis(collapse.emphasis)
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
        .plumeID(collapse.id, label: title, value: isExpanded ? "expanded" : "collapsed", invoke: toggle)
        .padding(.horizontal, -bleed)
    }

    @ViewBuilder
    private var collapsedSummary: some View {
        if collapse.itemCount > 0 {
            Text(collapse.itemCount, format: .number)
                .font(typography.bodyLarge.font)
                .monospacedDigit()
                .emphasis(.subtle)
                .padding(.leading, 2)
                .transition(.opacity)
        }
        if collapse.marksUnread {
            UnreadDot()
                .transition(.opacity)
        }
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
    /// What sits left of the keyline: the status marker and the color bar.
    static let gutterWidth = markerWidth + markerSpacing + barWidth + barTextGap
    private static let contextSeparator = "  •  "

    let item: HomeFeed.Item
    let isProminent: Bool
    /// On a wide page the markers sit left of the keyline, in the gutter,
    /// so every section's text shares one leading edge.
    let hangsMarkers: Bool
    let action: () -> Void
    @Environment(\.theme) var theme
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        let bleed = hangsMarkers ? Self.gutterWidth : 0
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

    private var barColor: Color? {
        item.barTint.flatMap(theme.colors.color(for:))
    }

    private var collapsesMarkerSlot: Bool {
        !hangsMarkers
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
