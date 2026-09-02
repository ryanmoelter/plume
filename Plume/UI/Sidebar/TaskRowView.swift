import SwiftUI

struct TaskRowView: View {
    @Bindable var task: WorkTask
    /// Set by the context menu's Rename; creation no longer opens the editor.
    @Binding var renamingTaskID: UUID?

    @FocusState private var titleFocused: Bool

    private var isEditing: Bool { renamingTaskID == task.id }

    /// Live status once the engine knows the task; the persisted snapshot
    /// covers the window before any agent has run this launch.
    private var status: TaskStatus {
        let live = StatusEngine.shared.status(forTask: task.id)
        return live == .unset ? task.lastStatus : live
    }

    private var detailLines: [String] {
        TaskRowDetails.lines(
            status: status,
            branch: task.branchName,
            workingDirectory: task.workingDirectoryPath
        )
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
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
                    Text(TitleStore.shared.displayTitle(for: task))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                ForEach(detailLines, id: \.self) { line in
                    Text(line)
                        .font(.caption)
                        .emphasis(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            StatusBadge(status: status)
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        ([TitleStore.shared.displayTitle(for: task)] + detailLines).joined(separator: ", ")
    }

    /// Clearing the name is how the user goes back to showing the agent's own
    /// title, so an emptied field is left empty.
    private func endEditing() {
        task.title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        renamingTaskID = nil
    }
}
