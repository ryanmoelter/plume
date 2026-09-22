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
    /// Both delete and archive can touch a Plume-owned worktree, so
    /// `MainWindow` owns the shared confirmation dialog and this view only
    /// asks it to run one.
    let requestArchive: (WorkTask) -> Void
    let requestDelete: (WorkTask) -> Void

    @State private var renamingGroupID: UUID?
    @State private var dropIndicator: SidebarDropIndicator?
    /// Each row and header's height, so a drop can tell which half it is over.
    @State private var dropTargetHeights: [UUID: CGFloat] = [:]

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
                        .background {
                            SidebarSelectionFill(isSelected: dropIndicator == .init(target: .group(group.id), placement: .into))
                        }
                        .sidebarDragAndDrop(
                            .group(group.id),
                            target: .group(group.id),
                            heights: $dropTargetHeights,
                            indicator: $dropIndicator
                        ) { handleDrop($0, $1, onto: group) }
                    }
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
        .navigationSplitViewColumnWidth(
            min: WindowMetrics.sidebarMinimumWidth,
            ideal: WindowMetrics.sidebarIdealWidth,
            max: WindowMetrics.sidebarMaximumWidth(windowWidth: windowWidth)
        )
    }

    @ViewBuilder
    private func taskRows(in sectionTasks: [WorkTask]) -> some View {
        ForEach(sectionTasks) { task in
            TaskRowView(task: task, isSelected: selection == task.id, onSelect: { select(task) }, renamingTaskID: $renamingTaskID)
                .tag(task.id)
                // A tab dragged over the row previews the selection it would
                // get, since dropping it there selects the tab in this task.
                .listRowBackground(SidebarSelectionFill(
                    isSelected: selection == task.id
                        || dropIndicator == .init(target: .task(task.id), placement: .into)
                ))
                // The list's own selection is turned off because
                // `.listRowBackground` draws *behind* its fill, so the accent
                // rectangle would show on top of the wash as a second
                // selection state. Selection therefore comes from the tap.
                .selectionDisabled()
                // Simultaneous, not exclusive: a plain `.onTapGesture` claims
                // the mouse-down, and the row's drag never starts.
                //
                // Not while renaming: the row's `TextField` needs the click
                // to place its cursor.
                .simultaneousGesture(TapGesture().onEnded { select(task) })
                .contextMenu {
                    Button("Rename") { renamingTaskID = task.id }
                    taskContextMenu(for: task)
                }
                .sidebarDragAndDrop(
                    .task(task.id),
                    target: .task(task.id),
                    heights: $dropTargetHeights,
                    indicator: $dropIndicator
                ) { handleDrop($0, $1, onto: task) }
        }
    }

    // MARK: - Drag and drop

    private func handleDrop(_ item: SidebarDragItem, _ placement: SidebarDropPlacement, onto task: WorkTask) {
        switch item {
        case .tab(let id):
            dropTab(id, onto: task)
        case .task(let id):
            moveTask(id, placement, relativeTo: task)
        case .group:
            break
        }
    }

    private func handleDrop(_ item: SidebarDragItem, _ placement: SidebarDropPlacement, onto group: TaskGroup) {
        switch item {
        case .task(let id):
            guard let task = tasks.first(where: { $0.id == id }), task.group?.id != group.id else { return }
            TaskStore.move(task, to: group, siblings: tasksFor(group))
        case .group(let id):
            guard let move = SidebarDropRules.move(id, placement, group.id, in: groups.map(\.id)) else { return }
            TaskStore.moveGroups(groups, from: IndexSet(integer: move.from), to: move.to)
        case .tab:
            break
        }
    }

    /// Moves a tab into `task`. Only the SwiftData relationship and ordering
    /// change — never the surface registry keyed by the tab's id.
    private func dropTab(_ tabID: UUID, onto task: WorkTask) {
        guard let tab = tasks.flatMap(\.tabs).first(where: { $0.id == tabID }),
              tab.task?.id != task.id
        else { return }
        TaskStore.moveTab(tab, to: task)
    }

    /// Puts the dragged task before or after `target`, joining `target`'s
    /// group first when it comes from another one.
    private func moveTask(_ id: UUID, _ placement: SidebarDropPlacement, relativeTo target: WorkTask) {
        guard let dragged = tasks.first(where: { $0.id == id }) else { return }
        var section = target.group.map(tasksFor) ?? ungroupedTasks
        if dragged.group?.id != target.group?.id {
            TaskStore.move(dragged, to: target.group, siblings: section)
            section.append(dragged)
        }
        guard let move = SidebarDropRules.move(id, placement, target.id, in: section.map(\.id)) else { return }
        TaskStore.move(section, from: IndexSet(integer: move.from), to: move.to)
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
            Button("Archive") { requestArchive(task) }
                .plumeID(AccessibilityID.taskArchiveButton)
        }
        Divider()
        Button("Delete", role: .destructive) { requestDelete(task) }
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
