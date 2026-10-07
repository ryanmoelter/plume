import SwiftUI

/// The info pane's sections — subagents, background tasks, the plan, and where
/// the conversation runs — shared by every presentation.
struct InfoPaneContent: View, ThemedView {
    @Environment(\.theme) var theme

    enum Style {
        case side
        case inline
    }

    let facts: InfoPaneFacts
    let style: Style
    let onOpenSubagent: (SubagentTranscript) -> Void
    let onOpenPlan: () -> Void
    /// Set where the pane can switch between its full and icon-only forms.
    var collapseToggle: CollapseToggle?

    struct CollapseToggle {
        let isCollapsed: Bool
        let action: () -> Void
    }

    @State private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            ForEach(facts.sections, id: \.self) { section in
                self.section(section)
            }
        }
        .font(typography.caption.font)
        .plumeID(AccessibilityID.infoPane, value: style == .side ? "side" : "inline")
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Info")
                .font(typography.caption.font.weight(.semibold))
                .emphasis(.secondary)
            Spacer(minLength: 0)
            if let collapseToggle {
                Button(action: collapseToggle.action) {
                    Image(systemName: collapseToggle.isCollapsed ? "pin" : "chevron.right.2")
                }
                .buttonStyle(.plain)
                .emphasis(.secondary)
                .help(collapseToggle.isCollapsed ? "Keep the pane expanded" : "Collapse to icons")
                .accessibilityLabel(collapseToggle.isCollapsed ? "Expand" : "Collapse")
                .plumeID(AccessibilityID.infoPaneCollapseButton, value: collapseToggle.isCollapsed ? "collapsed" : "expanded")
            }
            menu
        }
    }

    private var menu: some View {
        Menu {
            Picker("Show As", selection: $settings.infoPanePresentation) {
                ForEach(InfoPanePresentation.allCases, id: \.self) { presentation in
                    Text(presentation.label).tag(presentation)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Toggle("Show Completed Subagents", isOn: $settings.infoPaneShowsCompletedSubagents)
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

    @ViewBuilder
    private func section(_ section: InfoPaneSection) -> some View {
        switch section {
        case .subagents: subagents
        case .backgroundTasks: backgroundTasks
        case .plan: plan
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
                settings.infoPaneSubagentsExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Label("Subagents", systemImage: StatusSymbol.subagents.name)
                    Text("\(facts.liveSubagents.count + facts.completedSubagents.count)")
                        .emphasis(.subtle)
                    Spacer(minLength: 0)
                    if !isExpanded { subagentGlyphs }
                }
                .emphasis(.secondary)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .plumeID(AccessibilityID.infoPaneSubagentsToggle, value: isExpanded ? "expanded" : "collapsed")

            if isExpanded {
                ForEach(facts.liveSubagents) { subagentRow($0) }
                if !facts.completedSubagents.isEmpty {
                    Text("Completed")
                        .emphasis(.subtle)
                        .padding(.top, 4)
                        .padding(.horizontal, 8)
                    ForEach(facts.completedSubagents) { subagentRow($0) }
                }
            }
        }
        // The rows inset themselves for their hover wash; pulling them out
        // lines their text up with the other sections.
        .padding(.horizontal, -8)
    }

    private func subagentRow(_ subagent: SubagentTranscript) -> some View {
        SubagentRow(subagent: subagent, tabID: facts.tabID) { onOpenSubagent(subagent) }
            .id(subagent.id)
    }

    private var subagentGlyphs: some View {
        HStack(spacing: 4) {
            ForEach(facts.liveSubagents + facts.completedSubagents) { subagent in
                StatusBadge(status: subagent.status)
                    .imageScale(.small)
                    .help(subagent.title)
            }
        }
    }

    // MARK: Background tasks

    private var backgroundTasks: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Background", systemImage: "clock.arrow.circlepath")
                .emphasis(.secondary)
            ForEach(facts.backgroundTasks) { entry in
                HStack(spacing: 6) {
                    Text(entry.description ?? entry.kind.label)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    ElapsedLabel(since: entry.startedAt)
                        .emphasis(.subtle)
                }
                .padding(.leading, 22)
                .plumeID(AccessibilityID.infoPaneBackgroundTask, label: entry.description ?? entry.kind.label)
            }
        }
    }

    // MARK: Plan

    private var plan: some View {
        Button(action: onOpenPlan) {
            HStack(spacing: 6) {
                Label(facts.planTitle ?? "Plan", systemImage: StatusSymbol.plan.name)
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

    // MARK: Where it runs

    @ViewBuilder
    private var folder: some View {
        if let folder = facts.folder {
            Label(folder, systemImage: "folder")
                .lineLimit(1)
                .truncationMode(.middle)
                .emphasis(.secondary)
        }
    }

    @ViewBuilder
    private var branch: some View {
        if let branch = facts.branch {
            HStack(spacing: 6) {
                Label(branch.name, systemImage: branch.isWorktree ? "tree" : "arrow.triangle.branch")
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
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.pull")
                    .emphasis(.secondary)
                PullRequestChip(state: pullRequest.state, checkRollup: checkRollup)
                Spacer(minLength: 0)
            }
            .help(PullRequestChipContent.accessibilityText(for: pullRequest.state, checkRollup: checkRollup) ?? "")
        }
    }
}

/// The side pane shrunk to icons: one mark per section that has something to
/// say.
struct InfoPaneIconColumn: View, ThemedView {
    @Environment(\.theme) var theme

    let facts: InfoPaneFacts

    private static let maxSubagentBadges = 6

    var body: some View {
        VStack(spacing: 10) {
            ForEach(facts.sections, id: \.self) { section in
                icon(for: section)
            }
        }
        .font(typography.caption.font)
        .frame(width: InfoPaneLayout.iconColumnContentWidth)
    }

    @ViewBuilder
    private func icon(for section: InfoPaneSection) -> some View {
        switch section {
        case .subagents:
            VStack(spacing: 4) {
                let subagents = facts.liveSubagents + facts.completedSubagents
                Image(systemName: StatusSymbol.subagents.name)
                    .emphasis(.secondary)
                ForEach(subagents.prefix(Self.maxSubagentBadges)) { subagent in
                    StatusBadge(status: subagent.status)
                        .imageScale(.small)
                }
                if subagents.count > Self.maxSubagentBadges {
                    Text("+\(subagents.count - Self.maxSubagentBadges)")
                        .emphasis(.subtle)
                }
            }
        case .backgroundTasks:
            VStack(spacing: 2) {
                Image(systemName: "clock.arrow.circlepath")
                Text("\(facts.backgroundTasks.count)")
            }
            .emphasis(.secondary)
        case .plan:
            Image(systemName: StatusSymbol.plan.name)
                .emphasis(.secondary)
        case .folder:
            Image(systemName: "folder")
                .emphasis(.secondary)
        case .branch:
            Image(systemName: facts.branch?.isWorktree == true ? "tree" : "arrow.triangle.branch")
                .emphasis(.secondary)
        case .pullRequest:
            if let pullRequest = facts.pullRequest {
                PullRequestChip(
                    state: pullRequest.state,
                    checkRollup: { pullRequest.checkRollup ?? $0.checkRollup() },
                    summaryOnly: true
                )
            }
        }
    }
}
