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
    /// The task a dragged tab is currently over, so its row can ring itself.
    @State private var tabDropTargetID: UUID?
    @State private var pendingRemoval: PendingRemoval?
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
                        .plumeID(AccessibilityID.groupHeader, label: group.name)
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
                            .plumeID(AccessibilityID.newTaskButton)
                        Button("New Group") {
                            let group = TaskStore.createGroup(in: context, existing: groups)
                            renamingGroupID = group.id
                        }
                        .plumeID(AccessibilityID.newGroupButton)
                    } label: {
                        Label("Add", systemImage: "plus")
                            .labelStyle(.iconOnly)
                    } primaryAction: {
                        createTask(in: nil)
                    }
                    .menuStyle(.borderlessButton)
                    .plumeID(AccessibilityID.newTaskButton)
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
            "Delete “\(pendingRemoval?.task.title ?? "")”?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            presenting: pendingRemoval
        ) { removal in
            Button("Delete Task and Remove Worktree", role: .destructive) {
                deleteTask(removal.task, removeWorktree: true, deleteBranch: false)
            }
            Button("Delete Task, Remove Worktree and Branch", role: .destructive) {
                deleteTask(removal.task, removeWorktree: true, deleteBranch: true)
            }
            Button("Delete Task Only") {
                deleteTask(removal.task)
            }
            Button("Cancel", role: .cancel) {}
        } message: { removal in
            Text(removal.message)
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

    /// A worktree removal awaiting confirmation. `dirtySummary` is filled in
    /// only once the async uncommitted-changes check resolves, so the dialog
    /// never presents until its copy is final — its text must not change
    /// while the user is looking at it.
    private struct PendingRemoval: Identifiable {
        let task: WorkTask
        let dirtySummary: String?

        var id: UUID { task.id }

        var message: String {
            let base = "This task uses the worktree at \(task.workingDirectoryPath ?? "") on branch \(task.branchName ?? "")."
            guard let dirtySummary else { return base }
            return "\(base)\n\n\(dirtySummary)\n\nRemoving the worktree discards this work, and it cannot be recovered."
        }
    }

    /// Checks for uncommitted work before presenting the confirmation, so the
    /// one dialog's copy is settled before it ever appears rather than
    /// mutating under the user once the check resolves.
    private func confirmRemoval(of task: WorkTask) {
        guard let path = task.workingDirectoryPath else {
            pendingRemoval = PendingRemoval(task: task, dirtySummary: nil)
            return
        }
        Task {
            let changes = await GitService.shared.uncommittedChanges(in: path)
            pendingRemoval = PendingRemoval(
                task: task,
                dirtySummary: changes.isEmpty ? nil : Self.describe(changes)
            )
        }
    }

    /// Porcelain status as a sentence and a short list. The codes mean nothing
    /// to a reader deciding whether to lose the work, so only the paths show.
    private static func describe(_ changes: [String]) -> String {
        let paths = changes.map { $0.dropFirst(3) }.map(String.init)
        let count = paths.count
        let noun = count == 1 ? "file has" : "files have"
        let shown = paths.prefix(5).map { "• \($0)" }.joined(separator: "\n")
        let more = count > 5 ? "\n• and \(count - 5) more" : ""
        return "\(count) \(noun) uncommitted changes:\n\(shown)\(more)"
    }

    /// Removing the worktree is best-effort: if git refuses, the task stays so
    /// the user can resolve it rather than losing track of the directory. Its
    /// tabs are closed by then either way — they have to go before git touches
    /// the directory, and there is no reopening them if it declines.
    private func deleteTask(_ task: WorkTask, removeWorktree: Bool = false, deleteBranch: Bool = false) {
        guard removeWorktree,
              let repository = task.repoPath,
              let path = task.workingDirectoryPath
        else {
            finishDeleting(task)
            return
        }
        // Every tab's shell and agent has its working directory inside the
        // tree git is about to delete, so they go first. Removal awaits, and a
        // process left running across that wait holds a cwd that no longer
        // exists — and can still write into the directory as it is removed.
        for tab in task.tabs {
            TaskStore.forgetTab(tab)
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
                pendingRemoval = nil
                return
            }
            finishDeleting(task)
        }
    }

    private func finishDeleting(_ task: WorkTask) {
        if selection == task.id { selection = nil }
        TaskStore.delete(task, in: context)
        pendingRemoval = nil
    }

    @ViewBuilder
    private func taskRows(in sectionTasks: [WorkTask]) -> some View {
        ForEach(sectionTasks) { task in
            TaskRowView(task: task, isSelected: selection == task.id, onSelect: { select(task) }, renamingTaskID: $renamingTaskID)
                .tag(task.id)
                .listRowBackground(SidebarSelectionFill(isSelected: selection == task.id))
                // The list's own selection is turned off because
                // `.listRowBackground` draws *behind* its fill, so the accent
                // rectangle would show on top of the wash as a second
                // selection state. Selection therefore comes from the tap.
                .selectionDisabled()
                // Simultaneous, not exclusive: a plain `.onTapGesture` claims
                // the mouse-down, and the list's reorder drag never starts.
                //
                // Not while renaming: the row's `TextField` needs the click
                // to place its cursor.
                .simultaneousGesture(TapGesture().onEnded { select(task) })
                .contextMenu {
                    Button("Rename") { renamingTaskID = task.id }
                    taskContextMenu(for: task)
                }
                .dropDestination(for: String.self) { draggedIDs, _ in
                    tabDropTargetID = nil
                    return dropTab(draggedIDs, onto: task)
                } isTargeted: { targeted in
                    if targeted {
                        tabDropTargetID = task.id
                    } else if tabDropTargetID == task.id {
                        tabDropTargetID = nil
                    }
                }
                .overlay {
                    if tabDropTargetID == task.id {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(.tint, lineWidth: 2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                    }
                }
        }
        .onMove { offsets, destination in
            TaskStore.move(sectionTasks, from: offsets, to: destination)
        }
    }

    // MARK: - Cross-task tab drop

    /// Accepts a tab chip dragged from `TabStripView` (payload is the tab's
    /// `UUID` string) and moves it into `task`. Only the SwiftData
    /// relationship and ordering change — never touches the surface registry
    /// keyed by the tab's id.
    @discardableResult
    private func dropTab(_ draggedIDStrings: [String], onto task: WorkTask) -> Bool {
        guard let idString = draggedIDStrings.first, let draggedID = UUID(uuidString: idString) else {
            return false
        }
        guard let tab = tasks.flatMap(\.tabs).first(where: { $0.id == draggedID }) else { return false }
        guard tab.task?.id != task.id else { return false }
        TaskStore.moveTab(tab, to: task)
        return true
    }

    private func select(_ task: WorkTask) {
        guard renamingTaskID != task.id else { return }
        selection = task.id
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
        if !task.hasNeverStarted {
            Button("Archive") { TaskStore.archive(task) }
                .plumeID(AccessibilityID.taskArchiveButton)
        }
        Divider()
        Button("Delete", role: .destructive) {
            // A worktree task owns a branch and a directory on disk, so
            // deleting it asks before touching either.
            if task.workspaceKind == .worktree {
                confirmRemoval(of: task)
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
