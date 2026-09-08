import SwiftUI

struct TaskRowView: View {
    @Bindable var task: WorkTask
    /// Set by the context menu's Rename; creation no longer opens the editor.
    @Binding var renamingTaskID: UUID?

    @FocusState private var titleFocused: Bool
    /// What this row currently holds watches on, so a directory leaving the
    /// set releases the watch it took rather than whatever the task points at
    /// now.
    @State private var watched = DirectoryWatchSet()

    private var isEditing: Bool { renamingTaskID == task.id }

    /// Live status once the engine knows the task; the persisted snapshot
    /// covers the window before any agent has run this launch.
    private var status: TaskStatus {
        let live = StatusEngine.shared.status(forTask: task.id)
        return live == .unset ? task.lastStatus : live
    }

    /// One group per distinct directory the task's agent tabs are open in. A
    /// terminal's cwd follows `cd`, so including terminal tabs would make the
    /// list shift as the user moves around a shell.
    private var directories: [String] {
        TaskRowDetails.distinctDirectories(
            agentTabDirectories: task.orderedTabs
                .filter { $0.kind == .agent }
                .map { TabDirectoryStore.shared.directory(for: $0) },
            taskDirectory: task.workingDirectoryPath
        )
    }

    private func group(for directory: String) -> TaskRowDetails.DirectoryGroup {
        TaskRowDetails.DirectoryGroup(
            directory: directory,
            branch: branch(for: directory),
            pullRequest: PullRequestStore.shared.state(for: directory),
            checkout: CheckoutFactsStore.shared.facts(for: directory)
        )
    }

    /// The task's own branch covers the window before git answers. It is the
    /// right guess for any of the task's directories, not only its own folder:
    /// a row scrolled into view has no state yet, and showing nothing there
    /// reads as a task with no branch rather than one still loading.
    private func branch(for directory: String) -> String? {
        GitStateStore.shared.state(for: directory)?.branch ?? task.branchName
    }

    private var detailLines: [TaskRowDetails.Line] {
        TaskRowDetails.lines(groups: directories.map(group(for:)))
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
                    case .branch(let branch, let isWorktree, let companion):
                        HStack(spacing: 4) {
                            if isWorktree {
                                Image(systemName: "arrow.branch")
                                    .font(.caption)
                                    .imageScale(.small)
                                    .emphasis(.subtle)
                            }
                            Text(branch)
                                .font(.caption)
                                .emphasis(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if let companion {
                                PullRequestChip(state: companion)
                            }
                        }
                    case .pullRequest(let directory, let state):
                        PullRequestChip(state: state) {
                            PullRequestStore.shared.checkRollup(for: directory, of: $0)
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
        // Adding or closing an agent tab changes how many groups the row
        // shows, so its height eases rather than snapping the rows below it.
        .animatedHeight()
        .onChange(of: directories, initial: true) { _, current in
            watch(Set(current))
            // From a lifecycle event, never `body` — the store writes when the
            // lookup lands, which would invalidate the render that asked.
            for directory in current { CheckoutFactsStore.shared.load(directory) }
        }
        // Turning the setting off releases the pull request watch rather than
        // only hiding the chip, so no further request is made. The git watch
        // stays either way — the row still needs a branch.
        .onChange(of: AppSettings.shared.showsPullRequestStatus) { _, _ in
            watch(Set(directories))
        }
        // The row keeps its own git watch: a task whose chat tab is closed
        // still needs a branch, and the refcount makes the overlap free.
        .onChange(of: gitStates, initial: true) { _, states in
            for (directory, state) in states {
                PullRequestStore.shared.apply(gitState: state, for: directory)
            }
        }
        .onDisappear { watch([]) }
    }

    /// Keyed rather than a bare array so a directory leaving the set cannot
    /// shift another's state onto the wrong key.
    private var gitStates: [String: GitState?] {
        watched.git.reduce(into: [:]) { $0[$1] = GitStateStore.shared.state(for: $1) }
    }

    /// Diffed rather than blindly retaken: both stores are refcounted, so
    /// releasing what left and taking only what arrived is what keeps the
    /// counts balanced.
    private func watch(_ directories: Set<String>) {
        let wantsPullRequests = AppSettings.shared.showsPullRequestStatus
        let change = watched.change(to: directories, watchesPullRequests: wantsPullRequests)
        guard !change.isEmpty else { return }

        for directory in change.gitToRelease { GitStateStore.shared.release(directory) }
        for directory in change.pullRequestsToRelease { PullRequestStore.shared.release(directory) }
        for directory in change.gitToWatch { GitStateStore.shared.watch(directory) }
        for directory in change.pullRequestsToWatch { PullRequestStore.shared.watch(directory) }
        watched.apply(change)
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
