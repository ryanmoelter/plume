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
    #if DEBUG
    @AppStorage(AgentGroupBar.debugHoverEmphasisKey) private var hoverEmphasizes = false
    #else
    private let hoverEmphasizes = false
    #endif

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
    private func agentGroups(for tabs: [TaskTab]) -> [TaskRowDetails.AgentGroup] {
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
                header: header(for: tab, title: titles[index], label: labels[index]),
                workspace: workspace
            )
        }
    }

    private func header(for tab: TaskTab, title: String, label: String) -> TaskRowDetails.AgentHeader {
        let status = Self.status(of: tab)
        let held = DeviceLeaseStore.shared.leases(ownedBy: [tab.id])
        return TaskRowDetails.AgentHeader(
            tabID: tab.id,
            title: title,
            label: label,
            status: status,
            isUnread: UnreadStore.showsUnread(
                taskStatus: status,
                hasUnreadTab: UnreadStore.shared.isUnread(tabID: tab.id)
            ),
            isRemotelyControlled: Self.isRemoteControlled(tabIDs: [tab.id]),
            heldDevices: held.isEmpty ? nil : DeviceLeaseStore.summary(held)
        )
    }

    private static func status(of tab: TaskTab) -> TaskStatus {
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
        agentTabs: [TaskTab],
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
        if agentTabs.count <= 1 {
            let groups = directories.map(group(for:))
            return TaskRowDetails.lines(groups: groups) + taskLines(groups: groups)
        }
        let agents = agentGroups(for: agentTabs)
        return TaskRowDetails.lines(agents: agents, taskLines: taskLines(groups: agents.map(\.workspace)))
    }

    /// The remote-control and device icons of a task with one agent tab. Its
    /// project header repeats per directory, and the icons belong to the task
    /// rather than to any one of them, so they ride on the first. With several
    /// agent tabs, each header carries its own tab's icons instead.
    private struct ProjectLineIcons {
        var lineIndex: Int
        var isRemoteControlled: Bool
        var heldDevices: [DeviceLease]
    }

    private func projectLineIcons(in lines: [TaskRowDetails.Line], agentTabIDs: [UUID]) -> ProjectLineIcons? {
        guard let index = lines.firstIndex(where: { if case .project = $0 { true } else { false } }) else { return nil }
        return ProjectLineIcons(
            lineIndex: index,
            isRemoteControlled: Self.isRemoteControlled(tabIDs: agentTabIDs),
            heldDevices: DeviceLeaseStore.shared.leases(ownedBy: task.orderedLiveTabs.map(\.id))
        )
    }

    /// With several agent tabs, a lease owned by a terminal or device tab
    /// belongs to no header, so it shows beside the task's title.
    private func taskLevelHeldDevices() -> String? {
        let held = DeviceLeaseStore.shared.leases(ownedBy: task.orderedLiveTabs.filter { $0.kind != .agent }.map(\.id))
        return held.isEmpty ? nil : DeviceLeaseStore.summary(held)
    }

    private var agentTabs: [TaskTab] {
        task.orderedLiveTabs.filter { $0.kind == .agent }
    }

    /// Whether any of these tabs can be driven from elsewhere. Only the
    /// headless transport carries the bridge; a terminal tab's own TUI serves
    /// `/rc` itself.
    private static func isRemoteControlled(tabIDs: [UUID]) -> Bool {
        tabIDs.contains { AgentSessionManager.shared.existingSession(for: $0)?.isRemotelyControlled == true }
    }

    var body: some View {
        let agentTabs = agentTabs
        let agentTabIDs = agentTabs.map(\.id)
        let hasSeveralAgents = agentTabs.count > 1
        let working = workingLinearIssues
        let pinned = pinnedPullRequests
        let rawLines = detailLines(agentTabs: agentTabs, working: working, pinned: pinned)
        let lines = Array(rawLines.enumerated())
        let badgeLineCount = Self.badgeLineCount(of: rawLines)
        let icons = hasSeveralAgents ? nil : projectLineIcons(in: rawLines, agentTabIDs: agentTabIDs)
        let owners = TaskRowDetails.owningAgentLabels(rawLines)
        let nesting = TaskRowDetails.agentGroupNesting(rawLines)
        let groups = AgentGroupState(
            nesting: hasSeveralAgents ? nesting : rawLines.map { _ in [] },
            targets: TaskRowDetails.agentTabTargets(rawLines, nesting: nesting),
            focused: hasSeveralAgents && isSelected
                ? TaskRowDetails.focusedAgentGroup(rawLines, focusedTabID: task.selectedTabID) : nil,
            hovered: hasSeveralAgents ? TaskRowDetails.hoveredAgentGroup(hoveredLines: hoveredLines, nesting: nesting) : nil,
            hoverEmphasizes: hoverEmphasizes
        )
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    title(heldDevices: hasSeveralAgents ? taskLevelHeldDevices() : nil)
                    descriptionLine
                    ForEach(Array(lines.prefix(badgeLineCount)), id: \.offset) { index, line in
                        groupedDetailLine(line, at: index, owner: owners[index], icons: icons, groups: groups)
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

            ForEach(Array(lines.dropFirst(badgeLineCount)), id: \.offset) { index, line in
                groupedDetailLine(line, at: index, owner: owners[index], icons: icons, groups: groups)
            }

            TaskActivityRow(tabIDs: agentTabIDs)
        }
        .agentGroupBars(
            isEnabled: hasSeveralAgents,
            color: theme.colors.surface(AgentGroupBar.emphasis),
            lineWidth: AgentGroupBar.lineWidth(captionSize: theme.typography.caption.size),
            highlights: barHighlights(groups),
            wash: groups.hoverEmphasizes ? nil : groups.hovered.map {
                AgentGroupBar.Wash(group: $0, color: Color.chatSurface(.divider, colorScheme: colorScheme))
            }
        )
        .padding(.vertical, 2)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(lines: rawLines, agentTabIDs: agentTabIDs))
        .plumeID(AccessibilityID.taskRow, label: TitleStore.shared.displayTitle(for: task), value: isSelected ? "selected" : nil, invoke: onSelect)
        // Adding or closing an agent tab changes how many groups the row
        // shows, so its height eases rather than snapping the rows below it.
        .animatedHeight(alignment: .top)
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
        .onDisappear { watch([]) }
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

    private func title(heldDevices: String?) -> some View {
        SidebarIconTitle(
            icon: icon,
            iconMinWidth: SidebarMetrics.taskIconMinWidth,
            spacing: 5
        ) {
            HStack(spacing: 4) {
                titleText
                if let heldDevices {
                    deviceLeaseIcon(heldDevices, label: TitleStore.shared.displayTitle(for: task))
                }
            }
        }
    }

    private var remoteControlIcon: some View {
        Image(systemName: StatusSymbol.remoteControl.name)
            .font(.caption)
            .imageScale(.small)
            .foregroundStyle(ChatRole.attention(for: colorScheme))
            .help("Remote control is on")
    }

    private func deviceLeaseIcon(_ summary: String, label: String) -> some View {
        Image(systemName: "iphone")
            .font(.caption)
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

    @ViewBuilder
    private var titleText: some View {
        let text = Text(TitleStore.shared.displayTitle(for: task))
            .lineLimit(1)
            .truncationMode(.tail)
            .bold(appearance.weight == .bold)
        if let color = appearance.titleTint.flatMap(theme.colors.color(for:)) {
            text
                .foregroundStyle(color.opacity(tintOpacity))
        } else {
            text.emphasis(isInactive ? .secondary : .primary)
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
    /// glyph taller than the title never changes the row's height. An agent
    /// header never does: its own badge sits in the same trailing column.
    private static func badgeLineCount(of lines: [TaskRowDetails.Line]) -> Int {
        switch lines.first {
        case .project: 1
        default: 0
        }
    }

    /// The trailing column the task's badge and every agent's badge are
    /// centered in. The agent's is drawn smaller, so the task's reads first.
    static let badgeColumnWidth: CGFloat = 16

    /// What the row's agent groups need to draw and answer clicks, each group
    /// named by its header's line index.
    private struct AgentGroupState {
        /// Empty for every line of a row with one agent tab.
        var nesting: [[Int]]
        var targets: [UUID?]
        var focused: Int?
        var hovered: Int?
        var hoverEmphasizes: Bool

        func emphasis(ofLine index: Int) -> Emphasis {
            guard hoverEmphasizes, let hovered, nesting[index].contains(hovered) else { return .secondary }
            return .primary
        }
    }

    /// The focused agent's bar takes the task's color, or the accent when the
    /// task has none. The focused bar keeps its color under the pointer.
    private func barHighlights(_ groups: AgentGroupState) -> [Int: Color] {
        var highlights: [Int: Color] = [:]
        if groups.hoverEmphasizes, let hovered = groups.hovered {
            highlights[hovered] = theme.colors.surface(.secondary)
        }
        if let focused = groups.focused {
            highlights[focused] = SidebarTint.effective(for: task).flatMap(theme.colors.color(for:))
                ?? ChatRole.selection(for: colorScheme)
        }
        return highlights
    }

    /// A line inside an agent group selects that agent's tab when clicked.
    /// The tap is simultaneous so the row's own tap, drag and double-click
    /// still see the mouse.
    @ViewBuilder
    private func groupedDetailLine(
        _ line: TaskRowDetails.Line,
        at index: Int,
        owner: String?,
        icons: ProjectLineIcons?,
        groups: AgentGroupState
    ) -> some View {
        let member = detailLine(line, at: index, owner: owner, icons: icons, groups: groups)
            .agentGroupMember(groups.nesting[index])
        if !groups.nesting[index].isEmpty, let tabID = groups.targets[index] {
            member
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
                .simultaneousGesture(TapGesture().onEnded { selectAgentTab(tabID) })
                .plumeHover { hovering in
                    if hovering {
                        hoveredLines.insert(index)
                    } else {
                        hoveredLines.remove(index)
                    }
                }
        } else {
            member
        }
    }

    /// Selecting the task as well lets the control server's `invoke` stand in
    /// for a click, which the row's own tap also answers.
    private func selectAgentTab(_ tabID: UUID) {
        onSelect?()
        guard let tab = task.liveTabs.first(where: { $0.id == tabID }) else { return }
        TaskStore.selectTab(tab, in: task)
    }

    private func agentHeaderLine(
        _ header: TaskRowDetails.AgentHeader,
        isFocused: Bool,
        isHovered: Bool
    ) -> some View {
        HStack(spacing: 4) {
            Text(header.title)
                .font(.caption)
                .emphasis(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            if header.isRemotelyControlled {
                remoteControlIcon
            }
            if let heldDevices = header.heldDevices {
                deviceLeaseIcon(heldDevices, label: header.label)
            }
            Spacer(minLength: 4)
            StatusBadge(
                status: header.status,
                isUnread: header.isUnread,
                showsElapsed: false,
                scalesDotWithFont: true
            )
                .font(.caption)
                .imageScale(.small)
                .frame(width: Self.badgeColumnWidth)
        }
        .plumeID(
            AccessibilityID.taskAgentGroup,
            label: header.label,
            value: header.controlValue(isFocused: isFocused, isHovered: isHovered),
            invoke: { selectAgentTab(header.tabID) }
        )
    }

    @ViewBuilder
    private func detailLine(
        _ line: TaskRowDetails.Line,
        at index: Int,
        owner: String?,
        icons: ProjectLineIcons?,
        groups: AgentGroupState
    ) -> some View {
        let emphasis = groups.emphasis(ofLine: index)
        switch line {
        case .text(let text):
            Text(text)
                .font(.caption)
                .emphasis(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        case .agentHeader(let header):
            agentHeaderLine(header, isFocused: groups.focused == index, isHovered: groups.hovered == index)
        case .project(let name):
            HStack(spacing: 4) {
                Text(name)
                    .font(.caption)
                    .emphasis(emphasis)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let icons, index == icons.lineIndex {
                    if icons.isRemoteControlled {
                        remoteControlIcon
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
                Text(branch)
                    .font(.caption)
                    .emphasis(emphasis)
                    .lineLimit(1)
                    .truncationMode(.middle)
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
        case .pullRequest(let directory, let state):
            Group {
                if case .pullRequest(let pullRequest) = state {
                    PullRequestLine(summary: PullRequestSummary(
                        pullRequest,
                        ignoredChecks: PullRequestStore.shared.ignoredPendingChecks(for: directory)
                    ))
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

    private func accessibilityLabel(lines: [TaskRowDetails.Line], agentTabIDs: [UUID]) -> String {
        ([TitleStore.shared.displayTitle(for: task)]
            + (task.taskDescription.isEmpty ? [] : [task.taskDescription])
            + (isUnread ? ["unread"] : [])
            + lines.compactMap(TaskRowDetails.accessibilityText)
            + [TaskActivityRow.accessibilityText(tabIDs: agentTabIDs)].compactMap { $0 }).joined(separator: ", ")
    }
}
