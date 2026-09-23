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
            .plumeID(AccessibilityID.groupHeaderDisclosureButton)

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
                // A sidebar section header gets less trailing inset than its
                // rows, so the button pays the difference to line up with the
                // status icons below it.
                .padding(.trailing, 15)
            }
        }
        .contentShape(Rectangle())
        .plumeHover { isHovering = $0 }
    }
}
