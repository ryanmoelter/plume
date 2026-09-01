import SwiftUI

struct TaskRowView: View {
    @Bindable var task: WorkTask
    /// Newly created tasks start in edit mode so ⌘N flows straight into typing
    /// a name.
    @Binding var renamingTaskID: UUID?

    @FocusState private var titleFocused: Bool

    private var isEditing: Bool { renamingTaskID == task.id }

    var body: some View {
        HStack(spacing: 6) {
            if isEditing {
                TextField("Task name", text: $task.title)
                    .textFieldStyle(.plain)
                    .focused($titleFocused)
                    .onSubmit(endEditing)
                    .onChange(of: titleFocused) { _, focused in
                        if !focused { endEditing() }
                    }
                    .onAppear { titleFocused = true }
            } else {
                Text(task.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            StatusBadge(status: task.lastStatus)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(task.title), \(task.lastStatus.rawValue)")
    }

    /// An empty name would leave an unlabelled row, so it reverts.
    private func endEditing() {
        if task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            task.title = "New Task"
        }
        renamingTaskID = nil
    }
}
