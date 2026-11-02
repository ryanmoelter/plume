import SwiftUI

/// The destination as one path, `[group] No group ▾  [folder] Plume ▾
/// / Project root ▾  [tree] main ▾  ⑂ main`: the group, then the project, its
/// subfolder and its worktree as the new conversation screen names them. Each
/// segment is its own menu.
struct HomeDestinationPath: View, ThemedView {
    let model: HomeComposerModel
    @Environment(\.theme) var theme

    var body: some View {
        let menus = HomeDestinationMenus(model: model)
        HStack(spacing: 2) {
            groupSegment(menus)
            gap
            HomeDestinationSegment(glyph: .symbol("folder"), title: model.projectTitle, help: projectHelp) {
                menus.projectItems
            }
            .plumeID(
                AccessibilityID.homeComposerProjectMenu, value: model.projectTitle,
                setValue: model.chooseProject(named:)
            )
            if model.offersSubfolders {
                HomeDestinationSegment(glyph: .pathSeparator, title: model.subfolderTitle, help: subfolderHelp) {
                    menus.subfolderItems
                }
                .font(ProjectSubfolder.labelStyle(typography.caption, subfolder: model.destination.subfolder).font)
                .plumeID(
                    AccessibilityID.homeComposerSubfolderMenu, value: model.subfolderTitle,
                    setValue: model.chooseSubfolder(named:)
                )
            }
            if model.offersWorktrees {
                gap
                HomeDestinationSegment(glyph: .symbol("tree"), title: model.workspaceTitle, help: worktreeHelp) {
                    menus.workspaceItems
                }
                .plumeID(
                    AccessibilityID.homeComposerWorkspaceMenu, value: model.workspaceTitle,
                    setValue: model.chooseWorkspace(named:)
                )
                if let branch = model.workspaceBranch {
                    // The branch the worktree has out, not the worktree itself.
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.triangle.branch")
                            .imageScale(.small)
                        Text(branch)
                            .lineLimit(1)
                    }
                    .emphasis(.secondary)
                    .padding(.leading, 2)
                    .help("Branch: \(branch)")
                    // Truncates before any menu does.
                    .layoutPriority(-1)
                }
            }
        }
        .font(typography.caption.font)
        .fixedSize(horizontal: false, vertical: true)
        .task(id: model.destination.projectPath) {
            await model.loadWorktrees()
        }
        .task(id: model.subfolderCheckout) {
            await model.loadSubfolders()
        }
    }

    /// A chosen group shows its sidebar icon and color; "No group", and a
    /// group with neither, keep the stack icon and the path's own color.
    private func groupSegment(_ menus: HomeDestinationMenus) -> some View {
        let group = model.group
        return HomeDestinationSegment(
            glyph: .symbol(group?.iconName ?? "square.stack"),
            title: model.groupTitle,
            tint: group?.tintRaw.flatMap(SidebarTint.init(rawValue:)).flatMap(colors.color(for:)),
            isSidebarIcon: group?.iconName != nil
        ) {
            menus.groupItems
        }
        .plumeID(
            AccessibilityID.homeComposerGroupMenu, value: model.groupTitle,
            setValue: model.chooseGroup(named:)
        )
    }

    private var gap: some View {
        Spacer().frame(width: dimensions.panelContentInset)
    }

    private var projectHelp: String {
        guard let path = model.destination.projectPath else { return model.projectTitle }
        return "Working folder: \(Self.abbreviated(path))"
    }

    private var subfolderHelp: String {
        guard let checkout = model.subfolderCheckout else { return "Subfolder: \(model.subfolderTitle)" }
        let path = ProjectSubfolder.directory(checkoutRoot: checkout, subfolder: model.destination.subfolder)
        return "Subfolder \(model.subfolderTitle): \(Self.abbreviated(path))"
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
    let glyph: MenuLabelGlyph
    let title: String
    var help: String?
    /// Colors the glyph and title, as the sidebar colors a group's header.
    var tint: Color?
    /// Draws the glyph in the sidebar's rendering mode, for an icon the user
    /// picked there.
    var isSidebarIcon = false
    @ViewBuilder let items: () -> Items
    @Environment(\.theme) var theme
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        Menu {
            items()
        } label: {
            HStack(spacing: 4) {
                glyph.view
                    .symbolRenderingMode(
                        isSidebarIcon ? SidebarIcons.renderingMode(twoTone: AppSettings.shared.sidebarTwoToneIcons) : nil
                    )
                    .foregroundStyle(titleStyle)
                Text(title)
                    .lineLimit(1)
                    .foregroundStyle(titleStyle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .fixedSize()
            }
            .emphasis(.primary)
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
        .fixedSize(horizontal: false, vertical: true)
        .help(help ?? title)
        .plumeHover { isHovered = $0 }
    }

    private var titleStyle: AnyShapeStyle {
        tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(Emphasis.primary.textHierarchy)
    }
}
