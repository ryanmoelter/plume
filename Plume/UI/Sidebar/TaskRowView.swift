import SwiftUI

struct TaskRowView: View {
    @Bindable var task: WorkTask
    @FocusState private var titleFocused: Bool
    @State private var isEditing = false

    var body: some View {
        HStack(spacing: 6) {
            if isEditing {
                TextField("Task name", text: $task.title)
                    .textFieldStyle(.plain)
                    .focused($titleFocused)
                    .onSubmit { isEditing = false }
                    .onChange(of: titleFocused) { _, focused in
                        if !focused { isEditing = false }
                    }
            } else {
                Text(task.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            StatusBadge(status: task.lastStatus)
        }
        .contentShape(.rect)
        .onChange(of: isEditing) { _, editing in
            if editing { titleFocused = true }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(task.title), \(task.lastStatus.rawValue)")
    }

    func beginEditing() {
        isEditing = true
    }
}
