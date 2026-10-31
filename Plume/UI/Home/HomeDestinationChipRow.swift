import SwiftUI

/// Variant A: a menu chip each for group, project and workspace.
struct HomeDestinationChipRow: View, ThemedView {
    let model: HomeComposerModel
    @Environment(\.theme) var theme

    var body: some View {
        let menus = HomeDestinationMenus(model: model)
        HStack(spacing: dimensions.panelContentInset * 2) {
            chip(systemImage: "square.stack", title: model.groupTitle) { menus.groupItems }
                .plumeID(
                    AccessibilityID.homeComposerGroupMenu, value: model.groupTitle,
                    setValue: model.chooseGroup(named:)
                )
            chip(systemImage: "folder", title: model.projectTitle) { menus.projectItems }
                .plumeID(
                    AccessibilityID.homeComposerProjectMenu, value: model.projectTitle,
                    setValue: model.chooseProject(named:)
                )
            chip(systemImage: model.destination.workspace.systemImage, title: model.workspaceTitle) {
                menus.workspaceItems
            }
            .plumeID(
                AccessibilityID.homeComposerWorkspaceMenu, value: model.workspaceTitle,
                setValue: model.chooseWorkspace(named:)
            )
        }
        .font(typography.caption.font)
    }

    private func chip(systemImage: String, title: String, @ViewBuilder items: () -> some View) -> some View {
        Menu {
            items()
        } label: {
            ComposerSegmentLabel(
                systemImage: systemImage,
                text: title,
                indicator: .menu,
                foreground: colors.foreground.opacity(colors.emphasis[.secondary]),
                height: dimensions.composerControlHeight
            )
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(title)
    }
}
