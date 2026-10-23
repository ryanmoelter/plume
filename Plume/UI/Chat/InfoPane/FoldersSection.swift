import SwiftUI

/// What the Folders section does to the tab's `--add-dir` list.
struct InfoPaneFolderActions {
    let add: ([String]) -> Void
    let remove: (String) -> Void
    /// Opens the folder picker.
    let choose: () -> Void

    static let none = InfoPaneFolderActions(add: { _ in }, remove: { _ in }, choose: {})
}

/// The folders a conversation reaches: its working directory, the ones the
/// tab adds with `--add-dir`, and any the session reports on its own.
///
/// A lone working directory sits inline as one row; a second folder groups
/// them under a collapsible header.
struct FoldersSection: View, ThemedView {
    @Environment(\.theme) var theme

    /// The working directory's display name.
    let workingDirectoryName: String?
    let rows: [FolderRow]
    let canEdit: Bool
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
        // Folding the folder just added under a collapsed header would read
        // as the add failing.
        .onChange(of: isGrouped) { _, isGrouped in
            if isGrouped { settings.infoPaneFoldersExpanded = true }
        }
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
        .disabled(path == nil)
        .contextMenu {
            if let path {
                Button("Reveal in Finder") { FolderActions.reveal(path) }
                Button("Copy Path") { FolderActions.copyPath(path) }
            }
        }
        .help(path.map { "Working folder: \(FolderActions.abbreviated($0))" } ?? "")
        .plumeID(AccessibilityID.infoPaneFolderRow, label: name, value: "working directory") {
            if let path { FolderActions.reveal(path) }
        }
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
                        actions: actions
                    )
                }
            }
        }
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
        row.kind == .foreign || row.pending == .removesAfterTurn
    }

    private var note: String? {
        switch (row.kind, row.pending) {
        case (.workingDirectory, _): "working folder"
        case (_, .addsAfterTurn), (_, .removesAfterTurn): "after this turn"
        default: nil
        }
    }

    private var help: String {
        let path = FolderActions.abbreviated(row.path)
        switch (row.kind, row.pending) {
        case (.workingDirectory, _): return "Working folder: \(path)"
        case (.foreign, _): return "\(path)\nAdded outside \(AppIdentity.displayName), so it can't be removed here"
        case (_, .addsAfterTurn): return "\(path)\nApplies after this turn"
        case (_, .removesAfterTurn): return "\(path)\nRemoved after this turn"
        case (.added, .none): return path
        }
    }

    /// Read back by a driver, which cannot see the dimming.
    private var value: String {
        switch (row.kind, row.pending) {
        case (.workingDirectory, _): "working directory"
        case (.foreign, _): "foreign"
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
                    .plumeID(AccessibilityID.infoPaneFolderRemoveButton, label: path, value: "keep") { actions.add([path]) }
            } else {
                Button("Remove Folder") { actions.remove(path) }
                    .plumeID(AccessibilityID.infoPaneFolderRemoveButton, label: path, value: "remove") { actions.remove(path) }
            }
        }
    }
}
