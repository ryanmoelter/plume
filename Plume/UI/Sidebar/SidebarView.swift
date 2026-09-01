import SwiftUI
import SwiftData

struct SidebarView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.colorScheme) private var colorScheme
    @Binding var selection: UUID?

    @Query(filter: #Predicate<WorkTask> { !$0.isArchived }, sort: \WorkTask.orderIndex)
    private var tasks: [WorkTask]
    @Query(sort: \TaskGroup.orderIndex)
    private var groups: [TaskGroup]

    @Binding var renamingTaskID: UUID?
    @Binding var archiveShown: Bool

    @State private var renamingGroupID: UUID?
    @State private var taskPendingDeletion: WorkTask?
    @State private var deletionError: String?

    var body: some View {
        List(selection: $selection) {
            ForEach(groups) { group in
                Section {
                    taskRows(in: tasksFor(group))
                } header: {
                    GroupSectionHeader(
                        group: group,
                        isRenaming: renamingGroupID == group.id,
                        onDoneRenaming: { renamingGroupID = nil }
                    )
                    .contextMenu {
                        Button("Rename Group") { renamingGroupID = group.id }
                        Button("New Task in Group") { createTask(in: group) }
                        Divider()
                        Button("Delete Group", role: .destructive) {
                            TaskStore.deleteGroup(group, in: context)
                        }
                    }
                }
            }

            Section("Ungrouped") {
                taskRows(in: ungroupedTasks)
            }
        }
        .listStyle(.sidebar)
        .themeTint(colorScheme: colorScheme)
        .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("New Task") { createTask(in: nil) }
                    Button("New Group") {
                        let group = TaskStore.createGroup(in: context, existing: groups)
                        renamingGroupID = group.id
                    }
                } label: {
                    Label("Add", systemImage: "plus")
                } primaryAction: {
                    createTask(in: nil)
                }
            }
            ToolbarItem {
                Button {
                    archiveShown = true
                } label: {
                    Label("Archive", systemImage: "archivebox")
                }
                .help("Show archived tasks")
            }
        }
        .overlay {
            if tasks.isEmpty {
                ContentUnavailableView {
                    Label("No Tasks", systemImage: "square.stack.3d.up")
                } description: {
                    Text("Press ⌘N to start a task.")
                }
                .themeTint(colorScheme: colorScheme)
            }
        }
        .confirmationDialog(
            "Delete “\(taskPendingDeletion?.title ?? "")”?",
            isPresented: Binding(
                get: { taskPendingDeletion != nil },
                set: { if !$0 { taskPendingDeletion = nil } }
            ),
            presenting: taskPendingDeletion
        ) { task in
            Button("Delete Task and Remove Worktree", role: .destructive) {
                deleteTask(task, removeWorktree: true, deleteBranch: false)
            }
            Button("Delete Task, Remove Worktree and Branch", role: .destructive) {
                deleteTask(task, removeWorktree: true, deleteBranch: true)
            }
            Button("Delete Task Only") {
                deleteTask(task)
            }
            Button("Cancel", role: .cancel) {}
        } message: { task in
            Text("This task uses the worktree at \(task.workingDirectoryPath ?? "") on branch \(task.branchName ?? "").")
        }
        .alert("Could Not Remove Worktree", isPresented: Binding(
            get: { deletionError != nil },
            set: { if !$0 { deletionError = nil } }
        )) {
            Button("OK") { deletionError = nil }
        } message: {
            Text(deletionError ?? "")
        }
    }

    /// Removing the worktree is best-effort: if git refuses, the task stays so
    /// the user can resolve it rather than losing track of the directory.
    private func deleteTask(_ task: WorkTask, removeWorktree: Bool = false, deleteBranch: Bool = false) {
        if removeWorktree, let repository = task.repoPath, let path = task.workingDirectoryPath {
            do {
                try WorkspaceProvisioner.removeWorktree(
                    repository: repository,
                    path: path,
                    branch: task.branchName,
                    deleteBranch: deleteBranch
                )
            } catch {
                deletionError = error.localizedDescription
                taskPendingDeletion = nil
                return
            }
        }
        if selection == task.id { selection = nil }
        TaskStore.delete(task, in: context)
        taskPendingDeletion = nil
    }

    @ViewBuilder
    private func taskRows(in sectionTasks: [WorkTask]) -> some View {
        ForEach(sectionTasks) { task in
            TaskRowView(task: task, renamingTaskID: $renamingTaskID)
                .tag(task.id)
                .contextMenu {
                    Button("Rename") { renamingTaskID = task.id }
                    taskContextMenu(for: task)
                }
        }
        .onMove { offsets, destination in
            TaskStore.move(sectionTasks, from: offsets, to: destination)
        }
    }

    @ViewBuilder
    private func taskContextMenu(for task: WorkTask) -> some View {
        if !groups.isEmpty || task.group != nil {
            Menu("Move to") {
                ForEach(groups) { group in
                    Button(group.name) {
                        TaskStore.move(task, to: group, siblings: tasksFor(group))
                    }
                    .disabled(task.group?.id == group.id)
                }
                Button("Ungrouped") {
                    TaskStore.move(task, to: nil, siblings: ungroupedTasks)
                }
                .disabled(task.group == nil)
            }
        }
        Button("Archive") { task.isArchived = true }
        Divider()
        Button("Delete", role: .destructive) {
            // A worktree task owns a branch and a directory on disk, so
            // deleting it asks before touching either.
            if task.workspaceKind == .worktree {
                taskPendingDeletion = task
            } else {
                deleteTask(task)
            }
        }
    }

    private func tasksFor(_ group: TaskGroup) -> [WorkTask] {
        tasks.filter { $0.group?.id == group.id }
    }

    private var ungroupedTasks: [WorkTask] {
        tasks.filter { $0.group == nil }
    }

    private func createTask(in group: TaskGroup?) {
        let siblings = group.map(tasksFor) ?? ungroupedTasks
        let task = TaskStore.createTask(
            in: context, group: group, siblings: siblings, defaultsToRecentFolder: true
        )
        selection = task.id
    }
}

private struct GroupSectionHeader: View {
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
