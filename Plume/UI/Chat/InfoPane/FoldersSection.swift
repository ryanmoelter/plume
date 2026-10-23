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

    var note: String {
        switch blockers.first {
        case .turn: "Applies after this turn"
        case .unstartedFork: "Applies after this fork's first turn"
        case .unsettledRewind: "Applies after the next turn"
        case .subagents: "Applies when subagents finish"
        case .sideQuestion: "Applies when the side question is answered"
        case .backgroundTasks: "Applies when background tasks finish"
        case nil: "Applies in a moment"
        }
    }

    var restartNowHelp: String {
        let stopped = blockers.filter(\.canBeCutShort).map { blocker in
            switch blocker {
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
        let isGrouped = rows.count > 1 || rows.contains { $0.kind != .workingDirectory }
        Group {
            if isGrouped {
                groupedSection
            } else {
                inlineRow
            }
        }
        .animation(InfoPaneLayout.sectionAnimation, value: isGrouped)
    }

    private var workingDirectory: FolderRow? {
        rows.first { $0.kind == .workingDirectory }
    }

    @ViewBuilder
    private var inlineRow: some View {
        let path = workingDirectory?.path
        let name = workingDirectoryName ?? workingDirectory?.name ?? ""
        Button {
            if let path { FolderActions.reveal(path) }
        } label: {
            HStack(spacing: InfoPaneLayout.columnSpacing) {
                InfoPaneIcon { Image(systemName: "folder") }
                Text(name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if canEdit { OverlaidControlSpace() }
            }
            .emphasis(.secondary)
        }
        .buttonStyle(InfoPaneRowButtonStyle(suppressesWash: isHoveringAdd))
        .plumeID(AccessibilityID.infoPaneFolderRow, label: name, value: "working directory") {
            if let path { FolderActions.reveal(path) }
        }
        .disabled(path == nil)
        .contextMenu {
            if let path {
                Button("Reveal in Finder") { FolderActions.reveal(path) }
                Button("Copy Path") { FolderActions.copyPath(path) }
            }
        }
        .help(path.map { "Working folder: \(FolderActions.abbreviated($0))" } ?? "")
        .overlay(alignment: .trailing) {
            if canEdit { addButton }
        }
    }

    private var groupedSection: some View {
        let isExpanded = settings.infoPaneFoldersExpanded
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(InfoPaneLayout.sectionAnimation) { settings.infoPaneFoldersExpanded.toggle() }
            } label: {
                HStack(spacing: InfoPaneLayout.columnSpacing) {
                    InfoPaneIcon { Image(systemName: "folder") }
                    Text("Folders")
                    Text("\(rows.count)")
                        .emphasis(.subtle)
                    DisclosureChevron(isExpanded: isExpanded)
                    Spacer(minLength: 0)
                    if canEdit { OverlaidControlSpace() }
                }
                .emphasis(.secondary)
            }
            .buttonStyle(InfoPaneRowButtonStyle(suppressesWash: isHoveringAdd))
            .plumeID(AccessibilityID.infoPaneFoldersToggle, value: isExpanded ? "expanded" : "collapsed")
            .overlay(alignment: .trailing) {
                if canEdit { addButton }
            }

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

    private var addButton: some View {
        Button(action: actions.choose) {
            Image(systemName: "plus")
                .frame(width: InfoPaneLayout.iconColumnWidth)
                .modifier(OverlaidControlWash(isHovering: isHoveringAdd))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.colors.selection)
        .plumeHover { isHoveringAdd = $0 }
        .help("Let this conversation reach another folder")
        .plumeID(AccessibilityID.infoPaneFoldersAddButton, invoke: actions.choose)
    }
}

private struct FolderRowView: View, ThemedView {
    @Environment(\.theme) var theme

    let row: FolderRow
    let displayName: String
    let canEdit: Bool
    let restartNote: String?
    let actions: InfoPaneFolderActions

    @State private var isHoveringMenu = false

    var body: some View {
        Button(action: reveal) {
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
                OverlaidControlSpace()
            }
            .emphasis(isDimmed ? .subtle : .secondary)
        }
        .buttonStyle(InfoPaneRowButtonStyle(suppressesWash: isHoveringMenu))
        .opacity(row.pending == .removesAfterTurn ? 0.6 : 1)
        .contextMenu { menuItems }
        .help(help)
        .plumeID(AccessibilityID.infoPaneFolderRow, label: row.path, value: value, invoke: reveal)
        .overlay(alignment: .trailing) { actionsMenu }
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

    private var actionsMenu: some View {
        Menu { menuItems } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(theme.colors.selection)
        .frame(width: InfoPaneLayout.iconColumnWidth)
        .modifier(OverlaidControlWash(isHovering: isHoveringMenu))
        .plumeHover { isHoveringMenu = $0 }
        .help("Folder actions")
        .plumeID(AccessibilityID.infoPaneFolderRowMenu, label: row.path)
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
