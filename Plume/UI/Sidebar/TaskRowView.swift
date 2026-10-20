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

    private var appearance: SidebarTaskAppearance {
        SidebarTaskAppearance(task: task, settings: .shared)
    }

    private var tintOpacity: Double { isInactive ? 0.7 : 1 }

    /// Live status once the engine knows the task; the persisted snapshot
    /// covers the window before any agent has run this launch.
    private var status: TaskStatus {
        let live = StatusEngine.shared.status(forTask: task.id)
        return live == .notStarted ? task.lastStatus.afterRelaunch : live
    }

    /// Not actively being worked on — covers a task that hasn't started and
    /// one resumed mid-turn (which `TaskStatus.afterRelaunch` maps to
    /// `.interrupted`, whether relaunch or the user interrupted it).
    private var isInactive: Bool {
        status == .notStarted || status == .interrupted
    }

    /// One group per distinct directory the task's agent tabs are open in. A
    /// terminal's cwd follows `cd`, so including terminal tabs would make the
    /// list shift as the user moves around a shell.
    private var directories: [String] {
        TaskRowDetails.distinctDirectories(
            agentTabDirectories: task.orderedTabs
                .filter { $0.kind == .agent }
                .map { TabDirectoryStore.shared.directory(for: $0) },
            taskDirectory: task.workingDirectoryPath
        )
    }

    private func group(for directory: String) -> TaskRowDetails.DirectoryGroup {
        TaskRowDetails.DirectoryGroup(
            directory: directory,
            branch: branch(for: directory),
            pullRequest: PullRequestStore.shared.state(for: directory),
            checkout: CheckoutFactsStore.shared.facts(for: directory)
        )
    }

    private func branch(for directory: String) -> String? {
        GitState.displayedBranch(
            state: GitStateStore.shared.state(for: directory),
            taskBranchName: task.branchName
        )
    }

    private var detailLines: [TaskRowDetails.Line] {
        TaskRowDetails.lines(groups: directories.map(group(for:)))
    }

    /// A task with several directories repeats the project header per group,
    /// and the bridge belongs to the task rather than to any one of them.
    private var firstProjectLineIndex: Int? {
        detailLines.firstIndex { if case .project = $0 { true } else { false } }
    }

    private var agentTabIDs: [UUID] {
        task.orderedTabs.filter { $0.kind == .agent }.map(\.id)
    }

    /// Whether any of the task's tabs can be driven from elsewhere. Only the
    /// headless transport carries the bridge; a terminal tab's own TUI serves
    /// `/rc` itself.
    private var isRemoteControlled: Bool {
        agentTabIDs.contains { AgentSessionManager.shared.existingSession(for: $0)?.isRemotelyControlled == true }
    }

    var body: some View {
        let lines = Array(detailLines.enumerated())
        let badgeLineCount = Self.badgeLineCount(of: detailLines)
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    title
                    descriptionLine
                    ForEach(Array(lines.prefix(badgeLineCount)), id: \.offset) { index, line in
                        detailLine(line, at: index)
                    }
                }
                Spacer(minLength: 4)
                StatusBadge(
                    status: status,
                    workStartedAt: StatusEngine.shared.workStarted(forTask: task.id),
                    isUnread: isUnread
                )
            }

            ForEach(Array(lines.dropFirst(badgeLineCount)), id: \.offset) { index, line in
                detailLine(line, at: index)
            }

            TaskActivityRow(tabIDs: agentTabIDs)
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .plumeID(AccessibilityID.taskRow, label: TitleStore.shared.displayTitle(for: task), value: isSelected ? "selected" : nil, invoke: onSelect)
        // Adding or closing an agent tab changes how many groups the row
        // shows, so its height eases rather than snapping the rows below it.
        .animatedHeight(alignment: .top)
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

    private var title: some View {
        SidebarIconTitle(
            icon: icon,
            iconMinWidth: SidebarMetrics.taskIconMinWidth,
            spacing: 5
        ) {
            titleText
        }
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

    /// The project header shares the status badge's lines, so a badge glyph
    /// taller than the title never changes the row's height.
    private static func badgeLineCount(of lines: [TaskRowDetails.Line]) -> Int {
        if case .project = lines.first { 1 } else { 0 }
    }

    @ViewBuilder
    private func detailLine(_ line: TaskRowDetails.Line, at index: Int) -> some View {
        switch line {
        case .text(let text):
            Text(text)
                .font(.caption)
                .emphasis(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        case .project(let name):
            HStack(spacing: 4) {
                Text(name)
                    .font(.caption)
                    .emphasis(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if isRemoteControlled, index == firstProjectLineIndex {
                    Image(systemName: StatusSymbol.remoteControl.name)
                        .font(.caption)
                        .imageScale(.small)
                        .foregroundStyle(ChatRole.attention(for: colorScheme))
                        .help("Remote control is on")
                }
            }
        case .branch(let branch, let isWorktree, let companion):
            HStack(spacing: 4) {
                if isWorktree {
                    Image(systemName: "tree")
                        .font(.caption)
                        .imageScale(.small)
                        .emphasis(.secondary)
                }
                Text(branch)
                    .font(.caption)
                    .emphasis(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let companion {
                    PullRequestChip(state: companion, emphasis: .secondary, symbolWeight: .bold)
                }
            }
        case .pullRequest(let directory, let state):
            PullRequestChip(
                state: state,
                forge: PullRequestStore.shared.forge(for: directory),
                checkRollup: { PullRequestStore.shared.checkRollup(for: directory, of: $0) },
                symbolWeight: .bold
            )
        }
    }

    private var isUnread: Bool {
        UnreadStore.showsUnread(
            taskStatus: status,
            hasUnreadTab: UnreadStore.shared.hasUnread(among: task.tabs.map(\.id))
        )
    }

    private var accessibilityLabel: String {
        ([TitleStore.shared.displayTitle(for: task)]
            + (task.taskDescription.isEmpty ? [] : [task.taskDescription])
            + (isUnread ? ["unread"] : [])
            + detailLines.compactMap(TaskRowDetails.accessibilityText)
            + [TaskActivityRow.accessibilityText(tabIDs: agentTabIDs)].compactMap { $0 }).joined(separator: ", ")
    }
}
