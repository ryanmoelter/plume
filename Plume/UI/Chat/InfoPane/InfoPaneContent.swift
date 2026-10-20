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
    let linearActions: InfoPaneLinearActions
    /// Held by the presentation, which outlives this view as the side pane
    /// opens and closes.
    @Binding var showsCompleted: Bool

    @State private var settings = AppSettings.shared
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            InfoPaneHeader(button: headerButton) {
                Text("Info")
                    .font(typography.caption.font.weight(.semibold))
                    .emphasis(.secondary)
            }
            .padding(.bottom, InfoPaneLayout.rowVerticalPadding)
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
        case .artifacts: artifacts
        case .sideChat: sideChat
        case .folder: folder
        case .branch: branch
        case .pullRequest: pullRequest
        case .linearIssues: LinearIssuesSection(linear: facts.linear, actions: linearActions)
        }
    }

    // MARK: Subagents

    private var subagents: some View {
        let isExpanded = settings.infoPaneSubagentsExpanded
        return VStack(alignment: .leading, spacing: 0) {
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
            }
            .buttonStyle(InfoPaneRowButtonStyle())
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
        VStack(alignment: .leading, spacing: 0) {
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
            }
            .buttonStyle(InfoPaneRowButtonStyle())
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

    private var backgroundTasks: some View {
        let isGrouped = facts.backgroundTasks.count > 1
        return Group {
            if !isGrouped, let entry = facts.backgroundTasks.first {
                HStack(spacing: InfoPaneLayout.columnSpacing) {
                    InfoPaneIcon { Image(systemName: StatusSymbol.backgroundTasks.name) }
                        .emphasis(.secondary)
                    backgroundTaskRow(entry)
                }
                .padding(.vertical, InfoPaneLayout.rowVerticalPadding)
            } else {
                backgroundTaskSection
            }
        }
        .animation(InfoPaneLayout.sectionAnimation, value: isGrouped)
        // Folding a lone task's row under a collapsed header would read as
        // the task vanishing, so a section that just formed opens.
        .onChange(of: isGrouped) { _, isGrouped in
            if isGrouped { settings.infoPaneBackgroundTasksExpanded = true }
        }
    }

    private var backgroundTaskSection: some View {
        let isExpanded = settings.infoPaneBackgroundTasksExpanded
        return VStack(alignment: .leading, spacing: 0) {
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
            }
            .buttonStyle(InfoPaneRowButtonStyle())
            .plumeID(AccessibilityID.infoPaneBackgroundTasksToggle, value: isExpanded ? "expanded" : "collapsed")

            if isExpanded {
                ForEach(facts.backgroundTasks) { entry in
                    HStack(spacing: InfoPaneLayout.columnSpacing) {
                        InfoPaneIcon { Image(systemName: StatusSymbol.backgroundTasks.name).hidden() }
                        backgroundTaskRow(entry)
                    }
                    .padding(.vertical, InfoPaneLayout.rowVerticalPadding)
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
                    .emphasis(.secondary)
                Text(facts.planTitle ?? "Plan")
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .foregroundStyle(colors.selection)
            }
        }
        .buttonStyle(InfoPaneRowButtonStyle())
        .help("Open the plan this conversation produced")
        .plumeID(AccessibilityID.infoPanePlanRow)
    }

    // MARK: Artifacts

    private var artifacts: some View {
        let isGrouped = facts.artifacts.count > 1
        return Group {
            if !isGrouped, let artifact = facts.artifacts.first {
                artifactRow(artifact, showsIcon: true)
            } else {
                artifactSection
            }
        }
        .animation(InfoPaneLayout.sectionAnimation, value: isGrouped)
        .onChange(of: isGrouped) { _, isGrouped in
            if isGrouped { settings.infoPaneArtifactsExpanded = true }
        }
    }

    private var artifactSection: some View {
        let isExpanded = settings.infoPaneArtifactsExpanded
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(InfoPaneLayout.sectionAnimation) { settings.infoPaneArtifactsExpanded.toggle() }
            } label: {
                HStack(spacing: InfoPaneLayout.columnSpacing) {
                    InfoPaneIcon { Image(systemName: ArtifactSymbol.outline) }
                    Text("Artifacts")
                    Text("\(facts.artifacts.count)")
                        .emphasis(.subtle)
                    DisclosureChevron(isExpanded: isExpanded)
                    Spacer(minLength: 0)
                }
                .emphasis(.secondary)
            }
            .buttonStyle(InfoPaneRowButtonStyle())
            .plumeID(AccessibilityID.infoPaneArtifactsToggle, value: isExpanded ? "expanded" : "collapsed")

            if isExpanded {
                ForEach(facts.artifacts) { artifactRow($0, showsIcon: false) }
            }
        }
    }

    private func artifactRow(_ artifact: ConversationArtifact, showsIcon: Bool) -> some View {
        let title = artifact.title ?? "Untitled artifact"
        return Button {
            ChatLinkOpener.open(.web(artifact.url))
        } label: {
            HStack(spacing: InfoPaneLayout.columnSpacing) {
                InfoPaneIcon { Image(systemName: ArtifactSymbol.outline) }
                    .emphasis(.secondary)
                    .opacity(showsIcon ? 1 : 0)
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                LinkOpenIcon()
            }
        }
        .buttonStyle(InfoPaneRowButtonStyle())
        .help(artifact.url.absoluteString)
        .plumeID(AccessibilityID.infoPaneArtifactRow, label: title, value: artifact.url.absoluteString) {
            ChatLinkOpener.open(.web(artifact.url))
        }
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
                    .foregroundStyle(colors.selection)
            }
        }
        .buttonStyle(InfoPaneRowButtonStyle())
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
            .padding(.vertical, InfoPaneLayout.rowVerticalPadding)
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
            .padding(.vertical, InfoPaneLayout.rowVerticalPadding)
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
                    PullRequestChip(
                        state: pullRequest.state,
                        checkRollup: checkRollup,
                        font: typography.caption.font,
                        fontSize: typography.caption.size,
                        imageScale: .medium
                    )
                    Spacer(minLength: 4)
                    if url != nil {
                        LinkOpenIcon()
                    }
                }
            }
            .buttonStyle(InfoPaneRowButtonStyle())
            .disabled(url == nil)
            .help(PullRequestChipContent.accessibilityText(for: pullRequest.state, checkRollup: checkRollup) ?? "")
            .plumeID(AccessibilityID.infoPanePullRequestRow)
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
/// collapses, pins or closes it.
struct InfoPaneHeader<Title: View>: View, ThemedView {
    @Environment(\.theme) var theme

    let button: InfoPaneHeaderButton?
    @ViewBuilder let title: Title

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
        }
        .font(typography.caption.font)
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
        case .artifacts:
            HStack(spacing: 2) {
                Image(systemName: ArtifactSymbol.outline)
                Text("\(facts.artifacts.count)")
            }
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
        case .linearIssues:
            HStack(spacing: 2) {
                LinearLogo()
                Text("\(facts.linear?.issues.count ?? 0)")
            }
            .emphasis(.secondary)
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

/// A clickable pane row: insets that give its hover wash room, pulled back
/// out so the row's icon and text stay on the pane's columns.
private struct InfoPaneRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration)
    }

    private struct RowBody: View, ThemedView {
        @Environment(\.theme) var theme
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false
        let configuration: ButtonStyleConfiguration

        var body: some View {
            let showsWash = isEnabled && (isHovering || configuration.isPressed)
            configuration.label
                .padding(.horizontal, SubagentRow.Columns.washInset)
                .padding(.vertical, InfoPaneLayout.rowVerticalPadding)
                .contentShape(.rect(cornerRadius: 6))
                .background(showsWash ? colors.surfaceTint : Color.clear, in: .rect(cornerRadius: 6))
                .plumeHover { isHovering = $0 }
                .padding(.horizontal, -SubagentRow.Columns.washInset)
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
