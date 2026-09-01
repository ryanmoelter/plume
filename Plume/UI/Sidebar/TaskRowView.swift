import SwiftUI

struct TaskRowView: View {
    @Bindable var task: WorkTask
    /// Newly created tasks start in edit mode so ⌘N flows straight into typing
    /// a name.
    @Binding var renamingTaskID: UUID?

    @FocusState private var titleFocused: Bool

    private var isEditing: Bool { renamingTaskID == task.id }

    /// Live status once the engine knows the task; the persisted snapshot
    /// covers the window before any agent has run this launch.
    private var status: TaskStatus {
        let live = StatusEngine.shared.status(forTask: task.id)
        return live == .unset ? task.lastStatus : live
    }

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
            StatusBadge(status: status)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(task.title), \(status.rawValue)")
    }

    /// An empty name would leave an unlabelled row, so it reverts.
    private func endEditing() {
        if task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            task.title = "New Task"
        }
        renamingTaskID = nil
    }
}
