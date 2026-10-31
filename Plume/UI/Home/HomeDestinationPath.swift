import SwiftUI

/// The destination as one path, `[group] No group ▾  [folder] Plume ▾
/// [tree] main ▾  ⑂ main`: the group, then the project and its worktree as
/// the new conversation screen names them. Each segment is its own menu.
struct HomeDestinationPath: View, ThemedView {
    enum GroupSeparator {
        /// Space alone, for a row of controls.
        case gap
        /// A `›`, for a strip that reads as one path.
        case chevron
    }

    let model: HomeComposerModel
    var groupSeparator = GroupSeparator.gap
    /// Off where the row is short of room; the worktree's tooltip still
    /// names it.
    var showsBranch = true
    @Environment(\.theme) var theme

    var body: some View {
        let menus = HomeDestinationMenus(model: model)
        HStack(spacing: 2) {
            HomeDestinationSegment(systemImage: "square.stack", title: model.groupTitle) {
                menus.groupItems
            }
            .plumeID(
                AccessibilityID.homeComposerGroupMenu, value: model.groupTitle,
                setValue: model.chooseGroup(named:)
            )
            switch groupSeparator {
            case .gap:
                gap
            case .chevron:
                Text("›").emphasis(.subtle)
            }
            HomeDestinationSegment(systemImage: "folder", title: model.projectTitle, help: projectHelp) {
                menus.projectItems
            }
            .plumeID(
                AccessibilityID.homeComposerProjectMenu, value: model.projectTitle,
                setValue: model.chooseProject(named:)
            )
            if model.offersWorktrees {
                gap
                HomeDestinationSegment(systemImage: "tree", title: model.workspaceTitle, help: worktreeHelp) {
                    menus.workspaceItems
                }
                .plumeID(
                    AccessibilityID.homeComposerWorkspaceMenu, value: model.workspaceTitle,
                    setValue: model.chooseWorkspace(named:)
                )
                if showsBranch, let branch = model.workspaceBranch {
                    // The branch the worktree has out, not the worktree itself.
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.triangle.branch")
                            .imageScale(.small)
                        Text(branch)
                            .lineLimit(1)
                    }
                    .emphasis(.subtle)
                    .padding(.leading, 2)
                    .help("Branch: \(branch)")
                }
            }
        }
        .font(typography.caption.font)
        .fixedSize()
        .task(id: model.destination.projectPath) {
            await model.loadWorktrees()
        }
    }

    private var gap: some View {
        Spacer().frame(width: dimensions.panelContentInset)
    }

    private var projectHelp: String {
        guard let path = model.destination.projectPath else { return model.projectTitle }
        return "Working folder: \(Self.abbreviated(path))"
    }

    private var worktreeHelp: String {
        let name = model.workspaceTitle
        guard let branch = model.workspaceBranch else { return "Worktree: \(name)" }
        return "Worktree \(name), on \(branch)"
    }

    static func abbreviated(_ path: String) -> String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

/// Reads as text until hovered, so the path reads as one line while each
/// segment still shows it opens its own menu.
private struct HomeDestinationSegment<Items: View>: View, ThemedView {
    let systemImage: String
    let title: String
    var help: String?
    @ViewBuilder let items: () -> Items
    @Environment(\.theme) var theme
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        Menu {
            items()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                Text(title)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .emphasis(isHovered ? .primary : .secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background {
                RoundedRectangle(cornerRadius: 5)
                    .fill(isHovered ? Color.chatSurface(.backgroundTint, colorScheme: colorScheme) : .clear)
            }
            .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(help ?? title)
        .plumeHover { isHovered = $0 }
    }
}
