import SwiftUI

/// The destination as one path, `[group] No group ▾  [folder] Plume / Project
/// folder ▾`: the group, then the project and its workspace under a single
/// folder icon. Each segment is its own menu.
struct HomeDestinationPath: View, ThemedView {
    enum GroupSeparator {
        /// Space alone, for a row of controls.
        case gap
        /// A `›`, for a strip that reads as one path.
        case chevron
    }

    let model: HomeComposerModel
    var groupSeparator = GroupSeparator.gap
    @Environment(\.theme) var theme

    var body: some View {
        let menus = HomeDestinationMenus(model: model)
        HStack(spacing: 2) {
            HomeDestinationSegment(systemImage: "square.stack", title: model.groupTitle, showsIndicator: true) {
                menus.groupItems
            }
            .plumeID(
                AccessibilityID.homeComposerGroupMenu, value: model.groupTitle,
                setValue: model.chooseGroup(named:)
            )
            switch groupSeparator {
            case .gap:
                Spacer().frame(width: dimensions.panelContentInset)
            case .chevron:
                Text("›").emphasis(.subtle)
            }
            HomeDestinationSegment(systemImage: "folder", title: model.projectTitle, showsIndicator: false) {
                menus.projectItems
            }
            .plumeID(
                AccessibilityID.homeComposerProjectMenu, value: model.projectTitle,
                setValue: model.chooseProject(named:)
            )
            Text("/").emphasis(.subtle)
            HomeDestinationSegment(systemImage: nil, title: model.workspaceTitle, showsIndicator: true) {
                menus.workspaceItems
            }
            .plumeID(
                AccessibilityID.homeComposerWorkspaceMenu, value: model.workspaceTitle,
                setValue: model.chooseWorkspace(named:)
            )
        }
        .font(typography.caption.font)
        .fixedSize()
    }
}

/// Reads as text until hovered, so the path reads as one line while each
/// segment still shows it opens its own menu.
private struct HomeDestinationSegment<Items: View>: View, ThemedView {
    let systemImage: String?
    let title: String
    let showsIndicator: Bool
    @ViewBuilder let items: () -> Items
    @Environment(\.theme) var theme
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        Menu {
            items()
        } label: {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
                    .lineLimit(1)
                if showsIndicator {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
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
        .help(title)
        .plumeHover { isHovered = $0 }
    }
}
