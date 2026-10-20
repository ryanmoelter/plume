import SwiftUI

struct GroupSectionHeader: View {
    @Bindable var group: TaskGroup
    let onCreateTask: () -> Void
    let onEdit: () -> Void

    @State private var isHovering = false
    @Environment(\.theme) private var theme

    private var labelStyle: AnyShapeStyle {
        group.tint.flatMap(theme.colors.color(for:)).map { AnyShapeStyle($0) }
            ?? AnyShapeStyle(Emphasis.secondary.textHierarchy)
    }

    var body: some View {
        HStack(spacing: 4) {
            Button {
                group.isExpanded.toggle()
            } label: {
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(group.isExpanded ? 90 : 0))
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .plumeID(AccessibilityID.groupHeaderDisclosureButton)

            SidebarIconTitle(
                icon: group.iconName.map { iconName in
                    Image(systemName: iconName)
                        .symbolRenderingMode(SidebarIcons.renderingMode(twoTone: AppSettings.shared.sidebarTwoToneIcons))
                        .fontWeight(SidebarMetrics.headerWeight)
                        .foregroundStyle(labelStyle)
                },
                iconMinWidth: SidebarMetrics.headerIconMinWidth,
                spacing: 4
            ) {
                Text(group.name)
                    .foregroundStyle(labelStyle)
                    .contentShape(Rectangle())
                    // Simultaneous, not exclusive: a plain `.onTapGesture`
                    // claims the mouse-down, and the header's drag never starts.
                    .simultaneousGesture(TapGesture().onEnded { group.isExpanded.toggle() })
            }

            Spacer(minLength: 0)

            if isHovering {
                Button(action: onCreateTask) {
                    Image(systemName: "plus")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .help("New task in this group")
                .accessibilityLabel("New task in group")
                .plumeID(AccessibilityID.groupHeaderNewTaskButton, label: group.name)

                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .help("Edit this group")
                .accessibilityLabel("Edit group")
                .plumeID(AccessibilityID.groupHeaderEditButton, label: group.name)
            }
        }
        .contentShape(Rectangle())
        .plumeHover { isHovering = $0 }
    }
}
