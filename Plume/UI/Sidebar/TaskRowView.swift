import SwiftUI

struct TaskRowView: View {
    @Bindable var task: WorkTask
    /// Set by the context menu's Rename; creation no longer opens the editor.
    @Binding var renamingTaskID: UUID?

    @FocusState private var titleFocused: Bool
    /// The directory this row currently holds watches on, so a path change
    /// releases the one it took rather than whatever the task points at now.
    @State private var watchedDirectory: String?

    private var isEditing: Bool { renamingTaskID == task.id }

    /// Live status once the engine knows the task; the persisted snapshot
    /// covers the window before any agent has run this launch.
    private var status: TaskStatus {
        let live = StatusEngine.shared.status(forTask: task.id)
        return live == .unset ? task.lastStatus : live
    }

    private var pullRequestState: PullRequestFetchState? {
        PullRequestStore.shared.state(for: task.workingDirectoryPath)
    }

    private var detailLines: [TaskRowDetails.Line] {
        TaskRowDetails.lines(
            status: status,
            branch: task.branchName,
            workingDirectory: task.workingDirectoryPath,
            pullRequest: pullRequestState
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
                        .truncationMode(.tail)
                }

                ForEach(Array(detailLines.enumerated()), id: \.offset) { _, line in
                    switch line {
                    case .text(let text):
                        Text(text)
                            .font(.caption)
                            .emphasis(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    case .pullRequest(let state):
                        PullRequestChip(state: state) {
                            PullRequestStore.shared.checkRollup(for: task.workingDirectoryPath, of: $0)
                        }
                    }
                }
            }
            Spacer(minLength: 4)
            StatusBadge(status: status)
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(AccessibilityID.taskRow)
        .onChange(of: task.workingDirectoryPath, initial: true) { _, current in
            watch(current)
        }
        // The row keeps its own git watch: a task whose chat tab is closed
        // still needs a branch, and the refcount makes the overlap free.
        .onChange(of: GitStateStore.shared.state(for: watchedDirectory), initial: true) { _, gitState in
            if let watchedDirectory {
                PullRequestStore.shared.apply(gitState: gitState, for: watchedDirectory)
            }
        }
        .onDisappear { watch(nil) }
    }

    private func watch(_ directory: String?) {
        guard directory != watchedDirectory else { return }
        if let watchedDirectory {
            GitStateStore.shared.release(watchedDirectory)
            PullRequestStore.shared.release(watchedDirectory)
        }
        if let directory {
            GitStateStore.shared.watch(directory)
            PullRequestStore.shared.watch(directory)
        }
        watchedDirectory = directory
    }

    private var accessibilityLabel: String {
        ([TitleStore.shared.displayTitle(for: task)]
            + detailLines.compactMap(TaskRowDetails.accessibilityText)).joined(separator: ", ")
    }

    /// Clearing the name is how the user goes back to showing the agent's own
    /// title, so an emptied field is left empty.
    private func endEditing() {
        task.title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        renamingTaskID = nil
    }
}
