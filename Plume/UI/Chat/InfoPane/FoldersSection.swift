import SwiftUI

/// What the Folders section does to the tab's `--add-dir` list.
struct InfoPaneFolderActions {
    let add: ([String]) -> Void
    let remove: (String) -> Void
    let choose: () -> Void
    /// Applies a waiting change without waiting any longer.
    let restartNow: () -> Void

    static let none = InfoPaneFolderActions(add: { _ in }, remove: { _ in }, choose: {}, restartNow: {})
}

/// A folder change the running session has yet to pick up.
struct FolderRestartFacts: Equatable {
    typealias Blocker = HeadlessSession.RestartBlocker

    var blockers: [Blocker]
    var canRestartNow: Bool
    /// The last attempt could not relaunch, so the next idle moment retries.
    var hasFailed = false

    var note: String {
        switch blockers.first {
        case .turn: "Applies after this turn"
        case .unstartedFork: "Applies after this fork's first turn"
        case .unsettledRewind: "Applies after the next turn"
        case .delivery: "Applies once your message is delivered"
        case .subagents: "Applies when subagents finish"
        case .sideQuestion: "Applies when the side question is answered"
        case .backgroundTasks: "Applies when background tasks finish"
        case nil: hasFailed ? "Applies after the next turn" : "Applies in a moment"
        }
    }

    var restartNowHelp: String {
        let stopped = blockers.filter(\.canBeCutShort).map { blocker in
            switch blocker {
            case .delivery: "resending your message to the new session"
            case .subagents: "stopping the subagents"
            case .sideQuestion: "dropping the side question"
            case .backgroundTasks: "stopping the background tasks"
            case .turn, .unstartedFork, .unsettledRewind: ""
            }
        }
        return "Apply the folder change now, " + stopped.formatted(.list(type: .and))
    }
}

/// The folders a conversation reaches: its working directory and the ones
/// the tab adds with `--add-dir`.
///
/// A lone working directory sits inline as one row; a second folder groups
/// them under a collapsible header.
struct FoldersSection: View, ThemedView {
    @Environment(\.theme) var theme

    /// The working directory's display name.
    let workingDirectoryName: String?
    let rows: [FolderRow]
    let canEdit: Bool
    let restart: FolderRestartFacts?
    let actions: InfoPaneFolderActions

    @State private var settings = AppSettings.shared
    @State private var isHoveringAdd = false

    var body: some View {
        InfoPaneGroup(
            isGrouped: rows.count > 1 || rows.contains { $0.kind != .workingDirectory },
            expand: { settings.infoPaneFoldersExpanded = true }
        ) {
            inlineRow
        } grouped: {
            groupedSection
        }
    }

    private var workingDirectory: FolderRow? {
        rows.first { $0.kind == .workingDirectory }
    }

    /// Clicking the lone row opens the add-folder menu; revealing it in
    /// Finder stays on the context menu.
    @ViewBuilder
    private var inlineRow: some View {
        let path = workingDirectory?.path
        let name = workingDirectoryName ?? workingDirectory?.name ?? ""
        let label = HStack(spacing: InfoPaneLayout.columnSpacing) {
            InfoPaneIcon { Image(systemName: "folder") }
            Text(name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if canEdit { addCue }
        }
        Group {
            if canEdit {
                Menu { addFolderMenuItems } label: { label }
                    .modifier(InfoPaneRowMenuChrome())
                    .plumeID(AccessibilityID.infoPaneFolderRow, label: name, value: "working directory")
            } else {
                label
                    .padding(.vertical, InfoPaneLayout.rowVerticalPadding)
                    .plumeID(AccessibilityID.infoPaneFolderRow, label: name, value: "working directory")
            }
        }
        .contextMenu {
            if let path {
                Button("Reveal in Finder") { FolderActions.reveal(path) }
                Button("Copy Path") { FolderActions.copyPath(path) }
            }
        }
        .help(path.map { "Working folder: \(FolderActions.abbreviated($0))" } ?? "")
    }

    private var groupedSection: some View {
        let isExpanded = settings.infoPaneFoldersExpanded
        return InfoPaneBracketedSection(isExpanded: isExpanded) {
            InfoPaneSectionHeader(
                title: "Folders",
                icon: .symbol("folder"),
                count: rows.count,
                isExpanded: isExpanded,
                accessibilityID: AccessibilityID.infoPaneFoldersToggle,
                suppressesWash: isHoveringAdd,
                reservesTrailingControl: canEdit,
                action: toggleExpanded
            )
            .overlay(alignment: .trailing) {
                if canEdit { addMenu }
            }
        } rows: {
            if isExpanded {
                ForEach(rows) { row in
                    FolderRowView(
                        row: row,
                        displayName: row.kind == .workingDirectory ? workingDirectoryName ?? row.name : row.name,
                        canEdit: canEdit,
                        restartNote: restart?.note,
                        actions: actions
                    )
                }
            }
            // Shown collapsed too: a change that has not applied yet is the
            // section's news.
            if let restart {
                restartRow(restart)
            }
        }
    }

    private var addMenu: some View {
        Menu { addFolderMenuItems } label: {
            RowMenuLabel(systemImage: "plus", isHovering: isHoveringAdd)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(theme.colors.selection)
        .plumeHover { isHoveringAdd = $0 }
        .help("Let this conversation reach another folder")
        .plumeID(AccessibilityID.infoPaneFoldersAddMenu)
        .padding(-OverlaidControlWash.inset)
    }

    private func toggleExpanded() {
        withAnimation(InfoPaneLayout.sectionAnimation) { settings.infoPaneFoldersExpanded.toggle() }
    }

    private var addFolderMenuItems: some View {
        AddFolderMenuItems(
            linked: rows.map(\.path),
            workingDirectory: workingDirectory?.path,
            add: { actions.add([$0]) },
            choose: actions.choose
        )
    }

    private func restartRow(_ restart: FolderRestartFacts) -> some View {
        HStack(spacing: InfoPaneLayout.columnSpacing) {
            InfoPaneIcon { Image(systemName: "clock").emphasis(.subtle) }
            Text(restart.note)
                .lineLimit(2)
                .emphasis(.subtle)
            Spacer(minLength: 4)
            if restart.canRestartNow {
                Button("Restart Now", action: actions.restartNow)
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.colors.selection)
                    .help(restart.restartNowHelp)
                    .plumeID(AccessibilityID.infoPaneFoldersRestartNowButton, invoke: actions.restartNow)
            }
        }
        .padding(.vertical, InfoPaneLayout.rowVerticalPadding)
    }

    private var addCue: some View {
        Image(systemName: "plus")
            .frame(width: InfoPaneLayout.iconColumnWidth)
            .foregroundStyle(theme.colors.selection)
    }
}

/// A pane row that is a menu: the whole row opens it, with the row's own
/// hover wash.
///
/// `.button` keeps the custom label; `.borderlessButton` would redraw it as
/// an AppKit popup title.
struct InfoPaneRowMenuChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .menuStyle(.button)
            .buttonStyle(InfoPaneRowButtonStyle())
            .menuIndicator(.hidden)
    }
}

private struct FolderRowView: View, ThemedView {
    @Environment(\.theme) var theme

    let row: FolderRow
    let displayName: String
    let canEdit: Bool
    let restartNote: String?
    let actions: InfoPaneFolderActions

    var body: some View {
        Menu { menuItems } label: {
            HStack(spacing: InfoPaneLayout.columnSpacing) {
                InfoPaneIcon { Image(systemName: "folder").hidden() }
                Text(displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let note {
                    Text(note)
                        .lineLimit(1)
                        .fixedSize()
                        .emphasis(.subtle)
                }
                Spacer(minLength: 4)
                Image(systemName: "ellipsis")
                    .frame(width: InfoPaneLayout.iconColumnWidth)
                    .foregroundStyle(theme.colors.selection)
            }
            .emphasis(isDimmed ? .subtle : .primary)
        }
        .modifier(InfoPaneRowMenuChrome())
        .opacity(row.pending == .removesAfterTurn ? 0.6 : 1)
        .contextMenu { menuItems }
        .help(help)
        .plumeID(AccessibilityID.infoPaneFolderRow, label: row.path, value: value)
    }

    private var isDimmed: Bool {
        row.pending == .removesAfterTurn
    }

    private var note: String? {
        switch (row.kind, row.pending) {
        case (.workingDirectory, _): "working folder"
        case (_, .addsAfterTurn): "pending"
        case (_, .removesAfterTurn): "removing"
        default: nil
        }
    }

    private var help: String {
        let path = FolderActions.abbreviated(row.path)
        switch (row.kind, row.pending) {
        case (.workingDirectory, _): return "Working folder: \(path)"
        case (_, .addsAfterTurn): return restartNote.map { "\(path)\n\($0)" } ?? path
        case (_, .removesAfterTurn): return "\(path)\nRemoved once the change applies"
        case (.added, .none): return path
        }
    }

    /// Read back by a driver, which cannot see the dimming.
    private var value: String {
        switch (row.kind, row.pending) {
        case (.workingDirectory, _): "working directory"
        case (_, .addsAfterTurn): "adds after turn"
        case (_, .removesAfterTurn): "removes after turn"
        case (.added, .none): "added"
        }
    }

    private func reveal() {
        FolderActions.reveal(row.path)
    }

    @ViewBuilder
    private var menuItems: some View {
        let path = row.path
        Button("Reveal in Finder", action: reveal)
            .plumeID(AccessibilityID.infoPaneFolderRevealButton, label: path, invoke: reveal)
        Button("Copy Path") { FolderActions.copyPath(path) }
            .plumeID(AccessibilityID.infoPaneFolderCopyButton, label: path) { FolderActions.copyPath(path) }
        if canEdit, row.kind == .added {
            Divider()
            if row.pending == .removesAfterTurn {
                Button("Keep Folder") { actions.add([path]) }
                    .plumeID(AccessibilityID.infoPaneFolderKeepButton, label: path) { actions.add([path]) }
            } else {
                Button("Remove Folder") { actions.remove(path) }
                    .plumeID(AccessibilityID.infoPaneFolderRemoveButton, label: path) { actions.remove(path) }
            }
        }
    }
}
