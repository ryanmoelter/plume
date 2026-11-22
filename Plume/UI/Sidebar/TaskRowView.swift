import SwiftData
import SwiftUI

struct TaskRowView: View {
    @Bindable var task: WorkTask
    var isSelected = false
    var onSelect: (() -> Void)? = nil
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.theme) private var theme
    /// What this row currently holds watches on, so a directory leaving the
    /// set releases the watch it took rather than whatever the task points at
    /// now.
    @State private var watched = DirectoryWatchSet()
    /// Indices of the detail lines under the pointer. A set, not one index,
    /// so moving between two lines of a group never drops its hover when the
    /// exit lands after the enter.
    @State private var hoveredLines: Set<Int> = []
    @State private var isHoveringCapToggle = false
    /// Whether the left button is down over the hovered group.
    @State private var isPressingGroup = false
    @State private var pressMonitor = AgentGroupPressMonitor()
    @State private var showsAllAgents = false

    private var appearance: SidebarTaskAppearance {
        SidebarTaskAppearance(task: task, settings: .shared)
    }

    static let inactiveTintOpacity = 0.7
    private var tintOpacity: Double { isInactive ? Self.inactiveTintOpacity : 1 }

    /// Live status once the engine knows the task; the persisted snapshot
    /// covers the window before any agent has run this launch.
    private var status: TaskStatus {
        let live = StatusEngine.shared.status(forTask: task.id)
        return live == .notStarted ? task.lastStatus.afterRelaunch : live
    }

    private var isInactive: Bool {
        Self.isInactive(status: status, tabKinds: task.liveTabs.map(\.kind))
    }

    /// A task that hasn't started, or that a relaunch resumed mid-turn
    /// (`TaskStatus.afterRelaunch` maps those to `.notStarted`). An interrupted
    /// task has real content the user stopped on purpose, so it stays at full
    /// strength. Status comes only from agents, so a task of plain terminals
    /// never dims.
    static func isInactive(status: TaskStatus, tabKinds: [TabKind]) -> Bool {
        tabKinds.contains(.agent) && status == .notStarted
    }

    /// Every distinct directory the task's agent tabs are open in, which is
    /// what the row watches. A terminal's cwd follows `cd`, so including
    /// terminal tabs would make the list shift as the user moves around a
    /// shell.
    private var directories: [String] {
        task.agentDirectories
    }

    private func group(for directory: String) -> TaskRowDetails.DirectoryGroup {
        TaskRowDetails.DirectoryGroup(
            directory: directory,
            branch: branch(for: directory),
            pullRequest: PullRequestStore.shared.state(for: directory),
            checkout: CheckoutFactsStore.shared.facts(for: directory)
        )
    }

    /// Folders come from the rule `directories` uses, so every group's
    /// directory is one the row watches.
    private func agentGroups(for nested: [(item: TaskTab, depth: Int)]) -> [TaskRowDetails.AgentGroup] {
        let tabs = nested.map(\.item)
        let directories = task.agentTabDirectories(of: tabs)
        let titles = tabs.map { TitleStore.shared.chipTitle(for: $0) }
        let labels = TaskRowDetails.distinctLabels(titles)
        var groupsByDirectory: [String: TaskRowDetails.DirectoryGroup] = [:]
        return tabs.indices.map { index in
            let tab = tabs[index]
            let workspace: TaskRowDetails.DirectoryGroup
            if let directory = directories[index] {
                workspace = groupsByDirectory[directory] ?? group(for: directory)
                groupsByDirectory[directory] = workspace
            } else {
                workspace = TaskRowDetails.DirectoryGroup(directory: nil)
            }
            return TaskRowDetails.AgentGroup(
                header: header(for: tab, title: titles[index], label: labels[index], depth: nested[index].depth),
                workspace: workspace
            )
        }
    }

    private func header(for tab: TaskTab, title: String, label: String, depth: Int) -> TaskRowDetails.AgentHeader {
        let status = Self.status(of: tab)
        let held = DeviceLeaseStore.shared.leases(ownedBy: [tab.id])
        let mark = TaskRowDetails.childMark(of: tab)
        return TaskRowDetails.AgentHeader(
            tabID: tab.id,
            title: title,
            label: label,
            status: status,
            isUnread: UnreadStore.showsUnread(
                taskStatus: status,
                hasUnreadTab: UnreadStore.shared.isUnread(tabID: tab.id)
            ),
            depth: depth,
            isRemotelyControlled: Self.isRemoteControlled(tabIDs: [tab.id]),
            isDetachedChild: mark.isDetached,
            starter: mark.starter,
            heldDevices: held.isEmpty ? nil : DeviceLeaseStore.summary(held)
        )
    }

    static func status(of tab: TaskTab) -> TaskStatus {
        let live = StatusEngine.shared.status(forTab: tab.id)
        return live == .notStarted ? tab.lastStatus.afterRelaunch : live
    }

    private func branch(for directory: String) -> String? {
        task.displayedBranch(in: directory)
    }

    private var showsLinear: Bool {
        AppSettings.shared.showsLinearIssues && LinearStore.shared.isConfigured
    }

    private var workingLinearIssues: [LinkedLinearIssue] {
        guard showsLinear else { return [] }
        return LinearStore.shared.links(for: task, branches: task.linearBranches).filter { $0.role == .working }
    }

    private var pinnedPullRequests: [PullRequestReference] {
        guard AppSettings.shared.showsPullRequestStatus else { return [] }
        return TaskStore.pinnedPullRequests(of: task)
    }

    private func detailLines(
        nestedAgentTabs: [(item: TaskTab, depth: Int)],
        working: [LinkedLinearIssue],
        pinned: [PullRequestReference]
    ) -> [TaskRowDetails.Line] {
        func taskLines(groups: [TaskRowDetails.DirectoryGroup]) -> [TaskRowDetails.Line] {
            TaskRowDetails.pinnedPullRequestLines(
                pinned,
                groups: groups,
                details: { LinkedPullRequestStore.shared.detail(for: $0) }
            )
                + TaskRowDetails.linearLines(working, states: { LinearStore.shared.state(for: $0) })
        }
        if nestedAgentTabs.count <= 1 {
            let groups = directories.map(group(for:))
            return TaskRowDetails.lines(groups: groups) + taskLines(groups: groups)
        }
        let agents = agentGroups(for: nestedAgentTabs)
        let tabIDs = nestedAgentTabs.map(\.item.id)
        return TaskRowDetails.lines(
            agents: agents,
            taskLines: taskLines(groups: agents.map(\.workspace)),
            activity: Set(tabIDs.filter { TaskActivityRow.hasActivity(tabIDs: [$0]) })
        )
    }

    /// The remote-control and device icons of a task with one agent tab. Its
    /// project header repeats per directory, and the icons belong to the task
    /// rather than to any one of them, so they ride on the first, or on the
    /// title when there is no project line. With several agent tabs, each
    /// header carries its own tab's icons instead, except a header that
    /// stands for the task: its icons ride on its group's first line when
    /// that is a project line, and on the title otherwise.
    private struct ProjectLineIcons {
        var lineIndex: Int?
        var isRemoteControlled: Bool
        var heldDevices: [DeviceLease]
    }

    private func projectLineIcons(in lines: [TaskRowDetails.Line], agentTabIDs: [UUID]) -> ProjectLineIcons {
        ProjectLineIcons(
            lineIndex: lines.firstIndex { if case .project = $0 { true } else { false } },
            isRemoteControlled: Self.isRemoteControlled(tabIDs: agentTabIDs),
            heldDevices: DeviceLeaseStore.shared.leases(ownedBy: task.orderedLiveTabs.map(\.id))
        )
    }

    private func taskAgentIcons(in lines: [TaskRowDetails.Line]) -> ProjectLineIcons? {
        guard let start = lines.firstIndex(where: { !TaskRowDetails.isDrawn($0) }),
              case .agentHeader(let header) = lines[start]
        else { return nil }
        let next = lines.index(after: start)
        let startsWithProject = if lines.indices.contains(next), case .project = lines[next] { true } else { false }
        return ProjectLineIcons(
            lineIndex: startsWithProject ? next : nil,
            isRemoteControlled: header.isRemotelyControlled,
            heldDevices: DeviceLeaseStore.shared.leases(ownedBy: [header.tabID])
        )
    }

    /// With several agent tabs, a lease owned by a terminal or device tab
    /// belongs to no header, so it shows beside the task's title.
    private func taskLevelHeldDevices() -> [DeviceLease] {
        DeviceLeaseStore.shared.leases(ownedBy: task.orderedLiveTabs.filter { $0.kind != .agent }.map(\.id))
    }

    private func titleHeldDevices(_ held: [DeviceLease]) -> String? {
        held.isEmpty ? nil : DeviceLeaseStore.summary(held)
    }

    /// Whether any of these tabs can be driven from elsewhere. Only the
    /// headless transport carries the bridge; a terminal tab's own TUI serves
    /// `/rc` itself.
    private static func isRemoteControlled(tabIDs: [UUID]) -> Bool {
        tabIDs.contains { AgentSessionManager.shared.existingSession(for: $0)?.isRemotelyControlled == true }
    }

    var body: some View {
        let nestedAgentTabs = TaskStore.nestedAgentTabs(of: task)
        let agentTabIDs = nestedAgentTabs.map(\.item.id)
        let hasSeveralAgents = agentTabIDs.count > 1
        let working = workingLinearIssues
        let pinned = pinnedPullRequests
        let allLines = detailLines(nestedAgentTabs: nestedAgentTabs, working: working, pinned: pinned)
        let folded = AgentRowCap.fold(allLines, isExpanded: showsAllAgents, focusedTabID: focusedAgentTabID)
        let cap = folded.layout
        let rawLines = folded.lines
        let lines = Array(rawLines.enumerated())
        let badgeLineCount = Self.badgeLineCount(of: rawLines)
        let icons = hasSeveralAgents ? taskAgentIcons(in: rawLines) : projectLineIcons(in: rawLines, agentTabIDs: agentTabIDs)
        let titleIcons = icons?.lineIndex == nil ? icons : nil
        let firstDrawnLine = rawLines.firstIndex(where: TaskRowDetails.isDrawn)
        let owners = TaskRowDetails.owningAgentLabels(rawLines)
        let wipeKeys = TaskRowDetails.wipeKeys(rawLines)
        let nesting = TaskRowDetails.agentGroupNesting(rawLines)
        let hovered = hasSeveralAgents ? TaskRowDetails.hoveredAgentGroup(hoveredLines: hoveredLines, nesting: nesting) : nil
        let groups = AgentGroupState(
            nesting: hasSeveralAgents ? nesting : rawLines.map { _ in [] },
            targets: TaskRowDetails.agentTabTargets(rawLines, nesting: nesting),
            focused: hasSeveralAgents && isSelected
                ? TaskRowDetails.focusedAgentGroup(rawLines, focusedTabID: task.selectedTabID) : nil,
            hovered: hovered,
            pressed: isPressingGroup ? hovered : nil
        )
        let titleMark = TaskRowDetails.titleChildMark(
            rawLines,
            soleAgent: nestedAgentTabs.count == 1 ? TaskRowDetails.childMark(of: nestedAgentTabs[0].item) : nil
        )
        VStack(alignment: .leading, spacing: Self.lineSpacing) {
            // Above the title's line, so the task's badge stays beside the title.
            if let starter = titleMark?.starter {
                SidebarIconTitle(icon: icon.map { AnyView($0.hidden()) }, iconMinWidth: SidebarMetrics.taskIconMinWidth, spacing: 5) {
                    starterLine(
                        starter,
                        label: TitleStore.shared.displayTitle(for: task),
                        key: TaskRowDetails.titleTabID(
                            rawLines,
                            soleAgent: nestedAgentTabs.count == 1 ? nestedAgentTabs[0].item.id : nil
                        )
                    )
                }
            }
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: Self.lineSpacing) {
                    title(
                        heldDevices: titleHeldDevices(
                            (titleIcons?.heldDevices ?? []) + (hasSeveralAgents ? taskLevelHeldDevices() : [])
                        ),
                        isRemoteControlled: titleIcons?.isRemoteControlled ?? false,
                        isDetachedChild: titleMark?.isDetached == true
                    )
                    descriptionLine
                    ForEach(Array(lines.prefix(badgeLineCount)).filter { TaskRowDetails.isDrawn($0.element) }, id: \.offset) { index, line in
                        groupedDetailLine(line, at: index, owner: owners[index], wipeKey: wipeKeys[index], icons: icons, groups: groups, firstDrawnLine: firstDrawnLine)
                    }
                }
                Spacer(minLength: 4)
                StatusBadge(
                    status: status,
                    workStartedAt: StatusEngine.shared.workStarted(forTask: task.id),
                    isUnread: isUnread,
                    glyphWidth: hasSeveralAgents ? Self.badgeColumnWidth : nil
                )
            }

            ForEach(Array(lines.dropFirst(badgeLineCount)).filter { TaskRowDetails.isDrawn($0.element) }, id: \.offset) { index, line in
                groupedDetailLine(line, at: index, owner: owners[index], wipeKey: wipeKeys[index], icons: icons, groups: groups, firstDrawnLine: firstDrawnLine)
            }

            if let title = cap.toggleTitle, let symbol = cap.toggleSymbol {
                agentCapToggle(title: title, symbol: symbol)
            }

            // A folded header's activity shows here until it unfolds.
            TaskActivityRow(
                tabIDs: (hasSeveralAgents ? [] : agentTabIDs) + folded.hiddenTabIDs
            )
        }
        .agentGroupBars(isEnabled: hasSeveralAgents, style: barStyle(groups))
        .padding(.vertical, 2)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(lines: allLines, agentTabIDs: agentTabIDs, starter: titleMark?.starter))
        .plumeID(AccessibilityID.taskRow, label: TitleStore.shared.displayTitle(for: task), value: isSelected ? "selected" : nil, invoke: selectRow)
        // Adding or closing an agent tab changes how many groups the row
        // shows, so its height eases rather than snapping the rows below it.
        .padding(.horizontal, AgentGroupBar.drawingOutset)
        .animatedHeight(alignment: .top)
        .padding(.horizontal, -AgentGroupBar.drawingOutset)
        .linearIssueWatch(Set(working.map(\.identifier)))
        .task(id: pinned) { LinkedPullRequestStore.shared.retain(pinned, forTask: task.id) }
        .onChange(of: directories, initial: true) { _, current in
            watch(Set(current))
            // From a lifecycle event, never `body` — the store writes when the
            // lookup lands, which would invalidate the render that asked.
            for directory in current { CheckoutFactsStore.shared.load(directory) }
        }
        // Turning the setting off releases the pull request watch rather than
        // only hiding the chip, so no further request is made. The git watch
        // stays either way — the row still needs a branch.
        .onChange(of: AppSettings.shared.showsPullRequestStatus) { _, _ in
            watch(Set(directories))
        }
        // The row keeps its own git watch: a task whose chat tab is closed
        // still needs a branch, and the refcount makes the overlap free.
        .onChange(of: gitStates, initial: true) { _, states in
            for (directory, state) in states {
                PullRequestStore.shared.apply(gitState: state, for: directory)
            }
        }
        .onChange(of: hoveredLines.isEmpty) { _, isEmpty in
            if isEmpty {
                pressMonitor.stop()
            } else {
                pressMonitor.start { isPressingGroup = $0 }
            }
        }
        .onChange(of: TaskRowDetails.headerCount(allLines) > AgentRowCap.limit) { _, isOverCap in
            if !isOverCap { showsAllAgents = false }
        }
        // Hovered lines are indices, which a re-fold points at other lines.
        .onChange(of: folded.hiddenTabIDs) { _, _ in
            hoveredLines = []
        }
        .onDisappear {
            watch([])
            pressMonitor.stop()
        }
    }

    /// Keyed rather than a bare array so a directory leaving the set cannot
    /// shift another's state onto the wrong key.
    private var gitStates: [String: GitState?] {
        watched.git.reduce(into: [:]) { $0[$1] = GitStateStore.shared.state(for: $1) }
    }

    /// Diffed rather than blindly retaken: both stores are refcounted, so
    /// releasing what left and taking only what arrived is what keeps the
    /// counts balanced.
    private func watch(_ directories: Set<String>) {
        let wantsPullRequests = AppSettings.shared.showsPullRequestStatus
        let change = watched.change(to: directories, watchesPullRequests: wantsPullRequests)
        guard !change.isEmpty else { return }

        for directory in change.gitToRelease { GitStateStore.shared.release(directory) }
        for directory in change.pullRequestsToRelease { PullRequestStore.shared.release(directory) }
        for directory in change.gitToWatch { GitStateStore.shared.watch(directory) }
        for directory in change.pullRequestsToWatch { PullRequestStore.shared.watch(directory) }
        watched.apply(change)
    }

    /// A selected terminal keeps the last focused agent's group unfolded.
    private var focusedAgentTabID: UUID? {
        let selected = task.liveTabs.first { $0.id == task.selectedTabID }
        return selected?.kind == .agent ? selected?.id : task.lastFocusedAgentTabID
    }

    private func title(heldDevices: String?, isRemoteControlled: Bool, isDetachedChild: Bool) -> some View {
        SidebarIconTitle(
            icon: icon,
            iconMinWidth: SidebarMetrics.taskIconMinWidth,
            spacing: 5
        ) {
            HStack(spacing: 4) {
                if isDetachedChild {
                    detachedChildMarker(label: TitleStore.shared.displayTitle(for: task))
                }
                titleText
                if isRemoteControlled {
                    remoteControlIcon()
                }
                if let heldDevices {
                    deviceLeaseIcon(heldDevices, label: TitleStore.shared.displayTitle(for: task))
                }
            }
        }
    }

    /// A nil `font` inherits the line's, as an agent header's icons do.
    private func remoteControlIcon(font: Font? = .caption) -> some View {
        Image(systemName: StatusSymbol.remoteControl.name)
            .font(font)
            .imageScale(.small)
            .foregroundStyle(ChatRole.attention(for: colorScheme))
            .help("Remote control is on")
    }

    private func detachedChildMarker(label: String) -> some View {
        Image(systemName: "arrow.turn.down.right")
            .imageScale(.small)
            .emphasis(.secondary)
            .help("Started by a session that is elsewhere")
            .plumeID(AccessibilityID.taskAgentChildMarker, label: label, value: "detached")
    }

    /// Not a click target of its own: a click on it does what a click on
    /// the line it heads does, selecting the child above a header and the
    /// task above the title.
    private func starterLine(_ starter: TaskRowDetails.Starter, label: String, key: AnyHashable? = nil) -> some View {
        FadeWipeText(starter.text, key: key) {
            Text($0)
                .font(.caption)
                .emphasis(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .help(starter.help)
        .plumeID(AccessibilityID.taskAgentStarter, label: label, value: starter.text)
    }

    private func deviceLeaseIcon(_ summary: String, label: String, font: Font? = .caption) -> some View {
        Image(systemName: "iphone")
            .font(font)
            .imageScale(.small)
            .emphasis(.secondary)
            .help("Holds \(summary)")
            .plumeID(AccessibilityID.taskDeviceLeaseBadge, label: label, value: summary)
    }

    private var icon: AnyView? {
        task.iconName.map { AnyView(taskIcon($0)) }
    }

    @ViewBuilder
    private func taskIcon(_ name: String) -> some View {
        let appearance = appearance
        let icon = Image(systemName: name)
            .symbolRenderingMode(SidebarIcons.renderingMode(twoTone: AppSettings.shared.sidebarTwoToneIcons))
            .fontWeight(appearance.weight)
        if let color = appearance.iconTint.flatMap(theme.colors.color(for:)) {
            icon.foregroundStyle(color.opacity(tintOpacity))
        } else {
            icon.emphasis(isInactive ? .secondary : .primary)
        }
    }

    /// Switching agent tabs can rename the task, so the title wipes rather
    /// than swapping.
    @ViewBuilder
    private var titleText: some View {
        let isBold = appearance.weight == .bold
        let tint = appearance.titleTint.flatMap(theme.colors.color(for:))?.opacity(tintOpacity)
        let emphasis: Emphasis = isInactive ? .secondary : .primary
        // The styling branches inside the content, so a tint change never
        // gives the wipe a new identity mid-wipe.
        FadeWipeText(TitleStore.shared.displayTitle(for: task)) { title in
            let text = Text(title)
                .lineLimit(1)
                .truncationMode(.tail)
                .bold(isBold)
            if let tint {
                text.foregroundStyle(tint)
            } else {
                text.emphasis(emphasis)
            }
        }
    }

    @ViewBuilder
    private var descriptionLine: some View {
        if !task.taskDescription.isEmpty {
            Text(task.taskDescription)
                .font(.caption)
                .emphasis(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(task.taskDescription)
                .plumeID(AccessibilityID.taskDescription, label: TitleStore.shared.displayTitle(for: task), value: task.taskDescription)
        }
    }

    /// The first project line shares the status badge's lines, so a badge
    /// glyph taller than the title never changes the row's height. A drawn
    /// agent header never does: its own badge sits in the same trailing column.
    private static func badgeLineCount(of lines: [TaskRowDetails.Line]) -> Int {
        let skipped = lines.prefix { !TaskRowDetails.isDrawn($0) }.count
        switch lines.dropFirst(skipped).first {
        case .project: return skipped + 1
        default: return skipped
        }
    }

    /// The trailing column the task's badge and every agent's badge are
    /// centered in. The agent's is drawn smaller, so the task's reads first.
    static let badgeColumnWidth: CGFloat = 16
    private static let lineSpacing: CGFloat = 1
    /// Separates an agent group from what is above it. It sits outside the
    /// group's bar but inside its header's click and hover target.
    private static let agentHeaderGap: CGFloat = 3

    /// What the row's agent groups need to draw and answer clicks, each group
    /// named by its header's line index.
    private struct AgentGroupState {
        /// Empty for every line of a row with one agent tab.
        var nesting: [[Int]]
        var targets: [UUID?]
        var focused: Int?
        var hovered: Int?
        var pressed: Int?

        /// Whether the pointer raises this line's text to full strength.
        func isEmphasized(_ index: Int) -> Bool {
            guard let hovered else { return false }
            return nesting[index].contains(hovered)
        }

        func look(ofGroup group: Int) -> AgentGroupBar.Look {
            AgentGroupBar.look(ofGroup: group, focused: focused, hovered: hovered, pressed: pressed)
        }
    }

    /// The focused agent's bar takes the task's color, or the accent when the
    /// task has none.
    private func barStyle(_ groups: AgentGroupState) -> AgentGroupBar.Style {
        let headers = Set(groups.nesting.joined())
        var style = AgentGroupBar.Style(
            color: theme.colors.surface(AgentGroupBar.emphasis),
            lineWidth: AgentGroupBar.lineWidth(captionSize: theme.typography.caption.size),
            looks: Dictionary(uniqueKeysWithValues: headers.map { ($0, groups.look(ofGroup: $0)) })
        )
        if let focused = groups.focused {
            style.colors[focused] = SidebarTint.effective(for: task).flatMap(theme.colors.color(for:))
                ?? ChatRole.selection(for: colorScheme)
        }
        return style
    }

    /// A line inside an agent group selects that agent's tab when clicked.
    /// The tap is simultaneous so the row's own tap, drag and double-click
    /// still see the mouse.
    @ViewBuilder
    private func groupedDetailLine(
        _ line: TaskRowDetails.Line,
        at index: Int,
        owner: String?,
        wipeKey: String,
        icons: ProjectLineIcons?,
        groups: AgentGroupState,
        firstDrawnLine: Int?
    ) -> some View {
        let member = detailLine(line, at: index, owner: owner, wipeKey: wipeKey, icons: icons, groups: groups)
            .animation(AgentGroupBar.fade, value: groups.isEmphasized(index))
            .agentGroupMember(groups.nesting[index])
        if !groups.nesting[index].isEmpty, let tabID = groups.targets[index] {
            // Reaching half the stack's spacing past each edge leaves no gap
            // between lines where the pointer falls through to the row.
            member
                .padding(.top, Self.headerGap(above: line, at: index, firstDrawnLine: firstDrawnLine))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, Self.lineSpacing / 2)
                .contentShape(.rect)
                .simultaneousGesture(TapGesture().onEnded {
                    TaskRowClick.claim()
                    selectAgentTab(tabID)
                })
                .plumeHover { hovering in
                    if hovering {
                        hoveredLines.insert(index)
                    } else {
                        hoveredLines.remove(index)
                    }
                }
                .padding(.vertical, -Self.lineSpacing / 2)
        } else {
            member
        }
    }

    /// None above the first drawn line, which already sits under the title.
    private static func headerGap(above line: TaskRowDetails.Line, at index: Int, firstDrawnLine: Int?) -> CGFloat {
        guard let firstDrawnLine, index > firstDrawnLine, case .agentHeader = line else { return 0 }
        return agentHeaderGap
    }

    /// What a click on the row itself does, for the control server's `invoke`.
    private func selectRow() {
        onSelect?()
        TaskStore.selectRowClickTab(of: task)
    }

    /// Folding never changes the selected tab, so the toggle claims its click
    /// from the row.
    private func agentCapToggle(title: String, symbol: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .imageScale(.small)
                .fontWeight(isHoveringCapToggle ? .bold : .regular)
            Text(title)
        }
        .font(.caption)
        .emphasis(isHoveringCapToggle ? .primary : .secondary)
        .animation(AgentGroupBar.fade, value: isHoveringCapToggle)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .simultaneousGesture(TapGesture().onEnded {
            TaskRowClick.claim()
            toggleAgentCap()
        })
        .plumeHover { isHoveringCapToggle = $0 }
        .onDisappear { isHoveringCapToggle = false }
        .plumeID(
            AccessibilityID.taskAgentCapToggle,
            label: TitleStore.shared.displayTitle(for: task),
            value: AgentRowCap.toggleValue(isExpanded: showsAllAgents, isHovered: isHoveringCapToggle),
            invoke: toggleAgentCap
        )
    }

    private func toggleAgentCap() {
        onSelect?()
        showsAllAgents.toggle()
    }

    /// Selecting the task as well lets the control server's `invoke` stand in
    /// for a click, which the row's own tap also answers.
    private func selectAgentTab(_ tabID: UUID) {
        onSelect?()
        guard let tab = task.liveTabs.first(where: { $0.id == tabID }) else { return }
        TaskStore.selectTab(tab, in: task)
    }

    /// An agent's title dims while it is inactive, as the task's title does,
    /// and the pointer raises it back to full strength.
    static func agentTitleEmphasis(status: TaskStatus, isEmphasized: Bool) -> Emphasis {
        isEmphasized || !isInactive(status: status, tabKinds: [.agent]) ? .primary : .secondary
    }

    private func agentHeaderLine(
        _ header: TaskRowDetails.AgentHeader,
        wipeKey: String,
        isFocused: Bool,
        isHovered: Bool,
        isPressed: Bool,
        isEmphasized: Bool
    ) -> some View {
        let titleEmphasis = Self.agentTitleEmphasis(status: header.status, isEmphasized: isEmphasized)
        let isBold = header.drawsBold(boldsAttention: AppSettings.shared.sidebarBoldsAgentsNeedingAttention)
        return VStack(alignment: .leading, spacing: Self.lineSpacing) {
            if let starter = header.starter {
                starterLine(starter, label: header.label, key: wipeKey)
            }
            agentHeaderTitleLine(header, wipeKey: wipeKey, titleEmphasis: titleEmphasis, isBold: isBold)
                .plumeID(
                    AccessibilityID.taskAgentGroup,
                    label: header.label,
                    value: header.controlValue(isFocused: isFocused, isHovered: isHovered, isPressed: isPressed),
                    invoke: { selectAgentTab(header.tabID) }
                )
        }
    }

    private func agentHeaderTitleLine(_ header: TaskRowDetails.AgentHeader, wipeKey: String, titleEmphasis: Emphasis, isBold: Bool) -> some View {
        HStack(spacing: 4) {
            if header.isDetachedChild {
                detachedChildMarker(label: header.label)
            }
            FadeWipeText(header.title, key: wipeKey) {
                Text($0)
                    .bold(isBold)
                    .emphasis(titleEmphasis)
                    .animation(AgentGroupBar.fade, value: titleEmphasis)
                    // Selecting an unread agent reads it, which drops the bold.
                    .animation(AgentGroupBar.fade, value: isBold)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if header.isRemotelyControlled {
                remoteControlIcon(font: nil)
            }
            if let heldDevices = header.heldDevices {
                deviceLeaseIcon(heldDevices, label: header.label, font: nil)
            }
            Spacer(minLength: 4)
            StatusBadge(
                status: header.status,
                isUnread: header.isUnread,
                showsElapsed: false,
                scalesDotWithFont: true
            )
                .imageScale(.small)
                .frame(width: Self.badgeColumnWidth)
        }
    }

    @ViewBuilder
    private func detailLine(
        _ line: TaskRowDetails.Line,
        at index: Int,
        owner: String?,
        wipeKey: String,
        icons: ProjectLineIcons?,
        groups: AgentGroupState
    ) -> some View {
        let emphasis: Emphasis = groups.isEmphasized(index) ? .primary : .secondary
        switch line {
        case .text(let text):
            FadeWipeText(text, key: wipeKey) {
                Text($0)
                    .font(.caption)
                    .emphasis(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        case .agentHeader(let header):
            agentHeaderLine(
                header,
                wipeKey: wipeKey,
                isFocused: groups.focused == index,
                isHovered: groups.hovered == index,
                isPressed: groups.pressed == index,
                isEmphasized: groups.isEmphasized(index)
            )
        case .project(let name):
            HStack(spacing: 4) {
                FadeWipeText(name, key: wipeKey) {
                    Text($0)
                        .font(.caption)
                        .emphasis(emphasis)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let icons, index == icons.lineIndex {
                    if icons.isRemoteControlled {
                        remoteControlIcon()
                    }
                    if !icons.heldDevices.isEmpty {
                        deviceLeaseIcon(
                            DeviceLeaseStore.summary(icons.heldDevices),
                            label: TitleStore.shared.displayTitle(for: task)
                        )
                    }
                }
            }
            .plumeID(
                AccessibilityID.taskProjectLine,
                label: TaskRowDetails.controlLabel(line),
                value: TaskRowDetails.controlValue(line, owner: owner)
            )
        case .branch(let branch, let isWorktree, let companion):
            HStack(spacing: 4) {
                if isWorktree {
                    Image(systemName: "tree")
                        .font(.caption)
                        .imageScale(.small)
                        .emphasis(emphasis)
                }
                FadeWipeText(branch, key: wipeKey) {
                    Text($0)
                        .font(.caption)
                        .emphasis(emphasis)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let companion {
                    PullRequestChip(state: companion, emphasis: emphasis, symbolWeight: .bold)
                }
            }
            .plumeID(
                AccessibilityID.taskBranchLine,
                label: TaskRowDetails.controlLabel(line),
                value: TaskRowDetails.controlValue(line, owner: owner)
            )
        case .linearIssue(let identifier, let state):
            LinearIssueLine(identifier: identifier, state: state)
        case .linearOverflow(let count):
            HStack(spacing: 4) {
                LinearLogo(size: 10)
                    .emphasis(.secondary)
                Text("+\(count) more")
                    .font(.caption)
                    .emphasis(.secondary)
            }
        case .pinnedPullRequest(let reference, let detail):
            PinnedPullRequestLine(reference: reference, detail: detail)
        case .pinnedPullRequestOverflow(let count):
            PinnedPullRequestOverflowLine(count: count)
        case .activity(let tabID):
            TaskActivityRow(tabIDs: [tabID])
        case .pullRequest(let directory, let state):
            Group {
                if case .pullRequest(let pullRequest) = state {
                    PullRequestLine(summary: PullRequestSummary(
                        pullRequest,
                        ignoredChecks: PullRequestStore.shared.ignoredPendingChecks(for: directory)
                    ), titleKey: wipeKey)
                } else {
                    PullRequestChip(
                        state: state,
                        forge: PullRequestStore.shared.forge(for: directory),
                        checkRollup: { PullRequestStore.shared.checkRollup(for: directory, of: $0) },
                        symbolWeight: .bold
                    )
                }
            }
            .plumeID(
                AccessibilityID.taskPRLine,
                label: TaskRowDetails.controlLabel(line),
                value: TaskRowDetails.controlValue(line, owner: owner)
            )
        }
    }

    private var isUnread: Bool {
        UnreadStore.showsUnread(
            taskStatus: status,
            hasUnreadTab: UnreadStore.shared.hasUnread(among: task.liveTabs.map(\.id))
        )
    }

    private func accessibilityLabel(lines: [TaskRowDetails.Line], agentTabIDs: [UUID], starter: TaskRowDetails.Starter?) -> String {
        ([TitleStore.shared.displayTitle(for: task)]
            + (starter.map { [$0.accessibilityText] } ?? [])
            + (task.taskDescription.isEmpty ? [] : [task.taskDescription])
            + (isUnread ? ["unread"] : [])
            + lines.compactMap(TaskRowDetails.accessibilityText)
            + [TaskActivityRow.accessibilityText(tabIDs: agentTabIDs)].compactMap { $0 }).joined(separator: ", ")
    }
}
