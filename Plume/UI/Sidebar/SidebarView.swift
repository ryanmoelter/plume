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
    let windowWidth: CGFloat

    @State private var renamingGroupID: UUID?
    @State private var taskPendingDeletion: WorkTask?
    @State private var deletionError: String?

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(groups) { group in
                    Section {
                        if group.isExpanded {
                            taskRows(in: tasksFor(group))
                        }
                    } header: {
                        GroupSectionHeader(
                            group: group,
                            isRenaming: renamingGroupID == group.id,
                            onDoneRenaming: { renamingGroupID = nil },
                            onCreateTask: { createTask(in: group) }
                        )
                        .accessibilityIdentifier(AccessibilityID.groupHeader)
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
                .onMove { offsets, destination in
                    TaskStore.moveGroups(groups, from: offsets, to: destination)
                }

                Section("Ungrouped") {
                    taskRows(in: ungroupedTasks)
                }
            }
            .listStyle(.sidebar)
            // Arrow keys came free with the list's selection; `.selectionDisabled`
            // on the rows takes them with it, so they are wired up by hand.
            .onMoveCommand { direction in
                switch direction {
                case .up: moveSelection(by: -1)
                case .down: moveSelection(by: 1)
                default: break
                }
            }
            .toolbar {
                ToolbarItem {
                    Menu {
                        Button("New Task") { createTask(in: nil) }
                            .accessibilityIdentifier(AccessibilityID.newTaskButton)
                        Button("New Group") {
                            let group = TaskStore.createGroup(in: context, existing: groups)
                            renamingGroupID = group.id
                        }
                        .accessibilityIdentifier(AccessibilityID.newGroupButton)
                    } label: {
                        Label("Add", systemImage: "plus")
                            .labelStyle(.iconOnly)
                    } primaryAction: {
                        createTask(in: nil)
                    }
                    .menuStyle(.borderlessButton)
                    .accessibilityIdentifier(AccessibilityID.newTaskButton)
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

            SidebarFooter(archiveShown: $archiveShown)
        }
        .themeTint(colorScheme: colorScheme)
        .navigationSplitViewColumnWidth(
            min: WindowMetrics.sidebarMinimumWidth,
            ideal: WindowMetrics.sidebarIdealWidth,
            max: WindowMetrics.sidebarMaximumWidth(windowWidth: windowWidth)
        )
        .confirmationDialog(
            "Delete “\(taskPendingDeletion?.title ?? "")”?",
            isPresented: Binding(
                get: { taskPendingDeletion != nil },
                set: { if !$0 { taskPendingDeletion = nil } }
            ),
            presenting: taskPendingDeletion
        ) { task in
            Button(BetaBadge.menuTitle("Delete Task and Remove Worktree"), role: .destructive) {
                deleteTask(task, removeWorktree: true, deleteBranch: false)
            }
            Button(BetaBadge.menuTitle("Delete Task, Remove Worktree and Branch"), role: .destructive) {
                deleteTask(task, removeWorktree: true, deleteBranch: true)
            }
            Button("Delete Task Only") {
                deleteTask(task)
            }
            Button("Cancel", role: .cancel) {}
        } message: { task in
            Text("This task uses the worktree at \(task.workingDirectoryPath ?? "") on branch \(task.branchName ?? "").\n\nBeta: worktree removal forces past a dirty tree, so uncommitted changes can be lost silently. This path hasn't been driven since it moved onto GitService.")
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
        guard removeWorktree,
              let repository = task.repoPath,
              let path = task.workingDirectoryPath
        else {
            finishDeleting(task)
            return
        }
        Task {
            do {
                try await GitService.shared.removeWorktree(
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
            finishDeleting(task)
        }
    }

    private func finishDeleting(_ task: WorkTask) {
        if selection == task.id { selection = nil }
        TaskStore.delete(task, in: context)
        taskPendingDeletion = nil
    }

    @ViewBuilder
    private func taskRows(in sectionTasks: [WorkTask]) -> some View {
        ForEach(sectionTasks) { task in
            TaskRowView(task: task, renamingTaskID: $renamingTaskID)
                .tag(task.id)
                .listRowBackground(SidebarSelectionFill(isSelected: selection == task.id))
                // The list's own selection is turned off because
                // `.listRowBackground` draws *behind* its fill, so the accent
                // rectangle would show on top of the wash as a second
                // selection state. Selection therefore comes from the tap.
                .selectionDisabled()
                // Not while renaming: the row's `TextField` needs the click
                // to place its cursor.
                .onTapGesture {
                    guard renamingTaskID != task.id else { return }
                    selection = task.id
                }
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

    /// Every task in the order the sidebar shows them, which is what the
    /// arrow keys walk.
    private var navigableTasks: [WorkTask] {
        groups.flatMap(tasksFor) + ungroupedTasks
    }

    private func moveSelection(by offset: Int) {
        let destination = SidebarKeyboardNavigation.destination(
            from: selection,
            in: navigableTasks.map(\.id),
            offset: offset
        )
        if let destination { selection = destination }
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
