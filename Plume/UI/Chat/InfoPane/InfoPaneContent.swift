import SwiftUI

/// The info pane's sections — subagents, background tasks, the plan, and where
/// the conversation runs — shared by every presentation.
///
/// Every icon centers in a column `InfoPaneLayout.iconColumnWidth` wide, so
/// the text beside the icons starts on one edge. A collapsible section ends
/// with its disclosure chevron, and its rows start on that text edge.
struct InfoPaneContent: View, ThemedView {
    @Environment(\.theme) var theme

    let facts: InfoPaneFacts
    let headerButton: InfoPaneHeaderButton?
    let onOpenSubagent: (SubagentTranscript) -> Void
    let onOpenPlan: () -> Void
    let onOpenSideChat: () -> Void
    /// Held by the presentation, which outlives this view as the side pane
    /// opens and closes.
    @Binding var showsCompleted: Bool

    @State private var settings = AppSettings.shared
    @State private var isHoveringPullRequest = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            InfoPaneHeader(button: headerButton) {
                Text("Info")
                    .font(typography.caption.font.weight(.semibold))
                    .emphasis(.secondary)
            }
            ForEach(facts.sections, id: \.self) { section in
                self.section(section)
            }
        }
        .font(typography.caption.font)
    }

    @ViewBuilder
    private func section(_ section: InfoPaneSection) -> some View {
        switch section {
        case .subagents: subagents
        case .backgroundTasks: backgroundTasks
        case .plan: plan
        case .sideChat: sideChat
        case .folder: folder
        case .branch: branch
        case .pullRequest: pullRequest
        }
    }

    // MARK: Subagents

    private var subagents: some View {
        let isExpanded = settings.infoPaneSubagentsExpanded
        return VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(InfoPaneLayout.sectionAnimation) { settings.infoPaneSubagentsExpanded.toggle() }
            } label: {
                HStack(spacing: InfoPaneLayout.columnSpacing) {
                    InfoPaneIcon { Image(systemName: StatusSymbol.subagents.name) }
                    // Collapsed, the running subagents say more than the
                    // section's name does.
                    if !isExpanded, !facts.liveSubagents.isEmpty {
                        SubagentGlyphs(subagents: facts.liveSubagents)
                    } else {
                        Text("Subagents")
                    }
                    DisclosureChevron(isExpanded: isExpanded)
                    Spacer(minLength: 0)
                }
                .emphasis(.secondary)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .plumeID(AccessibilityID.infoPaneSubagentsToggle, value: isExpanded ? "expanded" : "collapsed")

            if isExpanded {
                ForEach(facts.liveSubagents) { subagentRow($0) }
                if !facts.completedSubagents.isEmpty {
                    completedSubagents
                }
            }
        }
    }

    private var completedSubagents: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(InfoPaneLayout.sectionAnimation) { showsCompleted.toggle() }
            } label: {
                HStack(spacing: InfoPaneLayout.columnSpacing) {
                    // Holds the first column without filling the row's height.
                    InfoPaneIcon { DisclosureChevron(isExpanded: false).hidden() }
                    Text("Completed")
                    Text("\(facts.completedSubagents.count)")
                    DisclosureChevron(isExpanded: showsCompleted)
                    Spacer(minLength: 0)
                }
                .emphasis(.subtle)
                .padding(.vertical, 3)
                // Straight under the section header, it needs the room a
                // running row would otherwise give it.
                .padding(.top, facts.liveSubagents.isEmpty ? 3 : 0)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .plumeID(AccessibilityID.infoPaneCompletedToggle, value: showsCompleted ? "expanded" : "collapsed")

            if showsCompleted {
                ForEach(facts.completedSubagents) { subagentRow($0) }
            }
        }
    }

    private func subagentRow(_ subagent: SubagentTranscript) -> some View {
        SubagentRow(subagent: subagent, tabID: facts.tabID, columns: .infoPane) { onOpenSubagent(subagent) }
            .id(subagent.id)
            // The row insets itself for its hover wash; pulling it out puts
            // its badge back in the pane's icon column.
            .padding(.horizontal, -SubagentRow.Columns.washInset)
    }

    // MARK: Background tasks

    @ViewBuilder
    private var backgroundTasks: some View {
        if facts.backgroundTasks.count == 1, let entry = facts.backgroundTasks.first {
            HStack(spacing: InfoPaneLayout.columnSpacing) {
                InfoPaneIcon { Image(systemName: StatusSymbol.backgroundTasks.name) }
                    .emphasis(.secondary)
                backgroundTaskRow(entry)
            }
        } else {
            backgroundTaskSection
        }
    }

    private var backgroundTaskSection: some View {
        let isExpanded = settings.infoPaneBackgroundTasksExpanded
        return VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(InfoPaneLayout.sectionAnimation) { settings.infoPaneBackgroundTasksExpanded.toggle() }
            } label: {
                HStack(spacing: InfoPaneLayout.columnSpacing) {
                    InfoPaneIcon { Image(systemName: StatusSymbol.backgroundTasks.name) }
                    Text("Background Tasks")
                    Text("\(facts.backgroundTasks.count)")
                    DisclosureChevron(isExpanded: isExpanded)
                    Spacer(minLength: 0)
                }
                .emphasis(.secondary)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .plumeID(AccessibilityID.infoPaneBackgroundTasksToggle, value: isExpanded ? "expanded" : "collapsed")

            if isExpanded {
                ForEach(facts.backgroundTasks) { entry in
                    backgroundTaskRow(entry)
                        .padding(.leading, InfoPaneLayout.iconColumnWidth + InfoPaneLayout.columnSpacing)
                }
            }
        }
    }

    private func backgroundTaskRow(_ entry: BackgroundTaskTracker.Entry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: InfoPaneLayout.columnSpacing) {
            Text(entry.description ?? entry.kind.label)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            ElapsedLabel(since: entry.startedAt)
                .emphasis(.subtle)
        }
        .help(entry.kind.label)
        .plumeID(AccessibilityID.infoPaneBackgroundTask, label: entry.description ?? entry.kind.label)
    }

    // MARK: Plan

    private var plan: some View {
        Button(action: onOpenPlan) {
            HStack(spacing: InfoPaneLayout.columnSpacing) {
                InfoPaneIcon { Image(systemName: StatusSymbol.plan.name) }
                Text(facts.planTitle ?? "Plan")
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .emphasis(.subtle)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Open the plan this conversation produced")
        .plumeID(AccessibilityID.infoPanePlanRow)
    }

    // MARK: Side chat

    private var sideChat: some View {
        Button(action: onOpenSideChat) {
            HStack(spacing: InfoPaneLayout.columnSpacing) {
                InfoPaneIcon { Image(systemName: SideQuestionChip.symbol) }
                Text("Side chats")
                Text("\(facts.sideChatCount)")
                    .emphasis(.subtle)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .emphasis(.subtle)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Open the side chats")
        .plumeID(AccessibilityID.infoPaneSideChatRow)
    }

    // MARK: Where it runs

    @ViewBuilder
    private var folder: some View {
        if let folder = facts.folder {
            HStack(spacing: InfoPaneLayout.columnSpacing) {
                InfoPaneIcon { Image(systemName: "folder") }
                Text(folder)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .emphasis(.secondary)
        }
    }

    @ViewBuilder
    private var branch: some View {
        if let branch = facts.branch {
            HStack(spacing: InfoPaneLayout.columnSpacing) {
                InfoPaneIcon { Image(systemName: branch.isWorktree ? "tree" : "arrow.triangle.branch") }
                Text(branch.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if let ahead = branch.ahead, ahead > 0 { Text("↑\(ahead)") }
                if let behind = branch.behind, behind > 0 { Text("↓\(behind)") }
                if branch.isDirty {
                    Image(systemName: "circle.fill")
                        .imageScale(.small)
                        .help("Uncommitted changes")
                }
            }
            .emphasis(.secondary)
        }
    }

    @ViewBuilder
    private var pullRequest: some View {
        if let pullRequest = facts.pullRequest {
            let checkRollup: (PullRequest) -> CheckRollup = { pullRequest.checkRollup ?? $0.checkRollup() }
            let url = pullRequest.url
            Button {
                if let url { openURL(url) }
            } label: {
                HStack(spacing: InfoPaneLayout.columnSpacing) {
                    InfoPaneIcon {
                        if let forge = pullRequest.forge, forge.markImageName != nil {
                            ForgeMarkCell(forge: forge)
                        } else {
                            Image(systemName: "arrow.triangle.pull")
                        }
                    }
                    .emphasis(.secondary)
                    // Wider than the gaps between the status marks, so the
                    // link reads as an action rather than another status.
                    HStack(spacing: 8) {
                        PullRequestChip(
                            state: pullRequest.state,
                            checkRollup: checkRollup,
                            font: typography.caption.font,
                            fontSize: typography.caption.size,
                            imageScale: .medium
                        )
                        Image(systemName: "arrow.up.forward.square")
                            .emphasis(.secondary)
                            .opacity(isHoveringPullRequest && url != nil ? 1 : 0)
                            .animation(.easeInOut(duration: 0.15), value: isHoveringPullRequest)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(url == nil)
            .plumeHover { isHoveringPullRequest = $0 }
            .help(PullRequestChipContent.accessibilityText(for: pullRequest.state, checkRollup: checkRollup) ?? "")
            .plumeID(AccessibilityID.infoPanePullRequestRow, value: isHoveringPullRequest ? "hovered" : nil)
        }
    }
}

struct InfoPaneHeaderButton {
    let systemImage: String
    let help: String
    /// What the control server reads back, so a driver can tell the
    /// button's forms apart.
    let value: String
    let action: () -> Void
}

/// The pane's top row: a title on the leading edge, then the button that
/// collapses, pins or closes it, then the options menu.
struct InfoPaneHeader<Title: View>: View, ThemedView {
    @Environment(\.theme) var theme

    let button: InfoPaneHeaderButton?
    @ViewBuilder let title: Title

    @State private var settings = AppSettings.shared

    var body: some View {
        HStack(spacing: InfoPaneLayout.columnSpacing) {
            title
            Spacer(minLength: 0)
            if let button {
                Button(action: button.action) {
                    Image(systemName: button.systemImage)
                        .frame(width: InfoPaneLayout.iconColumnWidth)
                }
                .buttonStyle(.plain)
                .emphasis(.secondary)
                .help(button.help)
                .accessibilityLabel(button.help)
                .plumeID(AccessibilityID.infoPaneCollapseButton, value: button.value)
            }
            menu
        }
        .font(typography.caption.font)
    }

    private var menu: some View {
        Menu {
            Picker("Show As", selection: $settings.infoPanePresentation) {
                ForEach(InfoPanePresentation.allCases, id: \.self) { presentation in
                    Text(presentation.label).tag(presentation)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .emphasis(.secondary)
        .help("Info pane options")
        .plumeID(AccessibilityID.infoPaneMenu)
    }
}

/// The collapsed form: one icon per section with something to say, in a row.
struct InfoPaneCollapsedIcons: View, ThemedView {
    @Environment(\.theme) var theme

    let facts: InfoPaneFacts

    var body: some View {
        let sections = facts.collapsedSections
        HStack(spacing: 10) {
            if sections.isEmpty {
                Image(systemName: InfoPaneLayout.symbol)
                    .emphasis(.secondary)
            }
            ForEach(sections, id: \.self) { section in
                icon(for: section)
            }
        }
        .font(typography.caption.font)
    }

    @ViewBuilder
    private func icon(for section: InfoPaneSection) -> some View {
        switch section {
        case .subagents:
            HStack(spacing: 4) {
                Image(systemName: StatusSymbol.subagents.name)
                    .emphasis(.secondary)
                SubagentGlyphs(subagents: facts.liveSubagents)
            }
        case .backgroundTasks:
            HStack(spacing: 2) {
                Image(systemName: StatusSymbol.backgroundTasks.name)
                Text("\(facts.backgroundTasks.count)")
            }
            .emphasis(.secondary)
        case .plan:
            Image(systemName: StatusSymbol.plan.name)
                .emphasis(.secondary)
        case .pullRequest:
            if let pullRequest = facts.pullRequest {
                PullRequestChip(
                    state: pullRequest.state,
                    emphasis: .secondary,
                    forge: pullRequest.forge,
                    checkRollup: { pullRequest.checkRollup ?? $0.checkRollup() },
                    showsNumber: false,
                    font: typography.caption.font,
                    fontSize: typography.caption.size,
                    imageScale: .medium
                )
            }
        case .branch:
            Image(systemName: "tree")
                .emphasis(.secondary)
                .help("In a worktree")
        case .folder, .sideChat:
            EmptyView()
        }
    }
}

/// One status glyph per subagent, capped so a busy session can't push the
/// row past its container.
private struct SubagentGlyphs: View, ThemedView {
    @Environment(\.theme) var theme

    let subagents: [SubagentTranscript]

    private static let limit = 6

    var body: some View {
        HStack(spacing: 4) {
            ForEach(subagents.prefix(Self.limit)) { subagent in
                StatusBadge(status: subagent.status)
                    .imageScale(.small)
                    .help(subagent.title)
            }
            if subagents.count > Self.limit {
                Text("+\(subagents.count - Self.limit)")
                    .emphasis(.subtle)
            }
        }
    }
}

/// One cell of the pane's icon column.
struct InfoPaneIcon<Icon: View>: View {
    @ViewBuilder let icon: Icon

    var body: some View {
        icon.frame(width: InfoPaneLayout.iconColumnWidth, alignment: .center)
    }
}

private struct DisclosureChevron: View {
    let isExpanded: Bool

    var body: some View {
        Image(systemName: "chevron.down")
            .rotationEffect(.degrees(isExpanded ? 0 : 90))
    }
}
