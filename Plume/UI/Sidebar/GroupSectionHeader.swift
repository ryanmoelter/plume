import SwiftUI

struct GroupSectionHeader: View {
    @Bindable var group: TaskGroup
    let isRenaming: Bool
    let onDoneRenaming: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
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
            }
        }
    }
}
