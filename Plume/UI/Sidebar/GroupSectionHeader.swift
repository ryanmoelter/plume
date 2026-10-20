import SwiftUI

struct GroupSectionHeader: View {
    @Bindable var group: TaskGroup
    let isRenaming: Bool
    let onDoneRenaming: () -> Void
    let onCreateTask: () -> Void
    let onEdit: () -> Void

    @FocusState private var focused: Bool
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

            if let iconName = group.iconName {
                Image(systemName: iconName)
                    .fontWeight(SidebarMetrics.headerWeight)
                    .foregroundStyle(labelStyle)
            }

            Group {
                if isRenaming {
                    TextField("Group name", text: $group.name)
                        .textFieldStyle(.plain)
                        .focused($focused)
                        .onSubmit(onDoneRenaming)
                        .onChange(of: focused) { _, isFocused in
                            if !isFocused { onDoneRenaming() }
                        }
                        .onAppear { focused = true }
                } else {
                    Text(group.name)
                        .foregroundStyle(labelStyle)
                        .contentShape(Rectangle())
                        // Simultaneous, not exclusive: a plain
                        // `.onTapGesture` claims the mouse-down, and the
                        // header's drag never starts.
                        .simultaneousGesture(TapGesture().onEnded { group.isExpanded.toggle() })
                }
            }

            Spacer(minLength: 0)

            if isHovering {
                Button(action: onCreateTask) {
                    Image(systemName: "plus")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .help("New task in this group")
                .plumeID(AccessibilityID.groupHeaderNewTaskButton)

                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .help("Edit this group")
                .plumeID(AccessibilityID.groupHeaderEditButton, label: group.name)
            }
        }
        .contentShape(Rectangle())
        .plumeHover { isHovering = $0 }
    }
}
