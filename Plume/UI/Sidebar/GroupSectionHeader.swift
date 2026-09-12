import SwiftUI

struct GroupSectionHeader: View {
    @Bindable var group: TaskGroup
    let isRenaming: Bool
    let onDoneRenaming: () -> Void
    let onCreateTask: () -> Void

    @FocusState private var focused: Bool
    @State private var isHovering = false

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
            .accessibilityIdentifier(AccessibilityID.groupHeaderDisclosureButton)

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
                        .contentShape(Rectangle())
                        .onTapGesture { group.isExpanded.toggle() }
                }
            }

            Spacer(minLength: 0)

            if isHovering {
                Button(action: onCreateTask) {
                    Image(systemName: "plus")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AccessibilityID.groupHeaderNewTaskButton)
                .padding(.trailing, 4)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }
}
