import SwiftUI

struct GroupSectionHeader: View {
    @Bindable var group: TaskGroup
    let isRenaming: Bool
    let onDoneRenaming: () -> Void
    let onCreateTask: () -> Void

    @FocusState private var focused: Bool
    @State private var isHovering = false
    @Environment(\.theme) private var theme

    private var labelStyle: AnyShapeStyle {
        let tintColor = group.tint.flatMap(theme.colors.color(for:))
        return .role(tintColor ?? .clear, when: tintColor != nil, otherwise: .secondary)
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
                .plumeID(AccessibilityID.groupHeaderNewTaskButton)
            }
        }
        .contentShape(Rectangle())
        .plumeHover { isHovering = $0 }
    }
}
