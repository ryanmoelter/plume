import SwiftUI

/// Variant C: the destination as a path, `Group / Project / worktree`, where
/// each segment is its own menu and reads as plain text until hovered.
struct HomeDestinationBreadcrumb: View, ThemedView {
    let model: HomeComposerModel
    @Environment(\.theme) var theme

    var body: some View {
        let menus = HomeDestinationMenus(model: model)
        HStack(spacing: 2) {
            BreadcrumbSegment(title: model.groupTitle) { menus.groupItems }
                .plumeID(
                    AccessibilityID.homeComposerGroupMenu, value: model.groupTitle,
                    setValue: model.chooseGroup(named:)
                )
            separator
            BreadcrumbSegment(title: model.projectTitle) { menus.projectItems }
                .plumeID(
                    AccessibilityID.homeComposerProjectMenu, value: model.projectTitle,
                    setValue: model.chooseProject(named:)
                )
            separator
            BreadcrumbSegment(title: model.workspaceTitle.lowercased()) { menus.workspaceItems }
                .plumeID(
                    AccessibilityID.homeComposerWorkspaceMenu, value: model.workspaceTitle,
                    setValue: model.chooseWorkspace(named:)
                )
        }
        .font(typography.caption.font)
    }

    private var separator: some View {
        Text("/").emphasis(.subtle)
    }
}

private struct BreadcrumbSegment<Items: View>: View, ThemedView {
    let title: String
    @ViewBuilder let items: () -> Items
    @Environment(\.theme) var theme
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        Menu {
            items()
        } label: {
            HStack(spacing: 3) {
                Text(title)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .imageScale(.small)
                    .opacity(isHovered ? 1 : 0)
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
        .plumeHover { isHovered = $0 }
    }
}
