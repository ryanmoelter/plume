import SwiftUI
import SwiftData

struct SidebarView: View {
    @Environment(\.modelContext) private var context
    @Binding var selection: UUID?

    @Query(filter: #Predicate<WorkTask> { !$0.isArchived }, sort: \WorkTask.orderIndex)
    private var tasks: [WorkTask]
    @Query(sort: \TaskGroup.orderIndex)
    private var groups: [TaskGroup]

    @Binding var archiveShown: Bool
    /// Both delete and archive can touch a Plume-owned worktree, so
    /// `MainWindow` owns the shared confirmation dialog and this view only
    /// asks it to run one.
    let requestArchive: (WorkTask) -> Void
    let requestDelete: (WorkTask) -> Void

    /// The group just created, whose popover opens with its name selected.
    @State private var newGroupID: UUID?
    /// The group or task whose appearance popover is open.
    @State private var appearanceEditingID: UUID?
    @Environment(\.theme) private var theme
    /// Each row and header's height, so a drop can tell which half it is over.
    @State private var dropTargetHeights: [UUID: CGFloat] = [:]
    /// Only ever set true. Setting a `FocusState` false resigns whatever is
    /// first responder at that moment.
    @FocusState private var isListFocused: Bool
    @State private var linkingLinearTask: WorkTask?

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(groups) { group in
                            groupHeader(group)
                                .padding(.top, group.id == groups.first?.id ? 0 : SidebarMetrics.headerTopSpacing)
                            if group.isExpanded {
                                taskRows(in: tasksFor(group))
                            }
                        }

                        Text("Ungrouped")
                            .sidebarSectionHeader()
                            .padding(.top, groups.isEmpty ? 0 : SidebarMetrics.headerTopSpacing)
                        taskRows(in: ungroupedTasks)
                    }
                    .padding(.horizontal, SidebarMetrics.listHorizontalInset)
                    .padding(.bottom, SidebarMetrics.rowVerticalPadding)
                }
                .onChange(of: selection) { _, id in
                    guard let task = tasks.first(where: { $0.id == id }) else { return }
                    withAnimation { proxy.scrollTo(task.sidebarRowID) }
                }
            }
            // Hand-built because `List(.sidebar)` paints its own accent
            // highlight on a row selected from code or right-clicked, with no
            // way to turn it off. The arrow keys and Delete need focus, so a
            // row claims it on tap.
            .focusable()
            .focused($isListFocused)
            .focusEffectDisabled()
            .onMoveCommand { direction in
                switch direction {
                case .up: moveSelection(by: -1)
                case .down: moveSelection(by: 1)
                default: break
                }
            }
            .onDeleteCommand {
                guard let task = tasks.first(where: { $0.id == selection }) else { return }
                switch KeyboardRemoval.verbForDeleteKey(hasNeverStarted: task.hasNeverStarted) {
                case .archive: requestArchive(task)
                case .delete: requestDelete(task)
                }
            }
            .toolbar {
                ToolbarItem {
                    Menu {
                        Button("New Task") { createTask(in: nil) }
                            .plumeID(AccessibilityID.newTaskButton)
                        Button("New Group") {
                            let group = TaskStore.createGroup(in: context, existing: groups)
                            newGroupID = group.id
                            appearanceEditingID = group.id
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
                }
            }

            SidebarFooter(archiveShown: $archiveShown)
        }
        .sheet(item: $linkingLinearTask) { task in
            LinkLinearIssueSheet(task: task)
        }
    }

    private func groupHeader(_ group: TaskGroup) -> some View {
        GroupSectionHeader(
            group: group,
            onCreateTask: { createTask(in: group) },
            onEdit: { appearanceEditingID = group.id }
        )
        .sidebarSectionHeader()
        .plumeID(AccessibilityID.groupHeader, label: group.name)
        .popover(isPresented: isEditingAppearance(of: group.id), arrowEdge: .trailing) {
            GroupAppearancePopover(group: group, selectsName: newGroupID == group.id)
        }
        .contextMenu {
            Button("Edit…") { appearanceEditingID = group.id }
                .plumeID(AccessibilityID.groupEditButton, label: group.name)
            Button("New Task in Group") { createTask(in: group) }
            Divider()
            Button("Delete Group", role: .destructive) {
                TaskStore.deleteGroup(group, in: context)
            }
        }
        .sidebarDragAndDrop(
            .group(group.id),
            target: .group(group.id),
            heights: $dropTargetHeights
        ) { handleDrop($0, $1, onto: group) }
    }

    @ViewBuilder
    private func taskRows(in sectionTasks: [WorkTask]) -> some View {
        ForEach(sectionTasks, id: \.sidebarRowID) { task in
            TaskRowView(
                task: task,
                isSelected: selection == task.id,
                onSelect: { select(task) }
            )
                .sidebarRow(isSelected: selection == task.id, tintBar: tintBar(for: task), washTint: washTint(for: task))
                // Simultaneous, not exclusive: a plain `.onTapGesture` claims
                // the mouse-down, and the row's drag never starts.
                .simultaneousGesture(TapGesture().onEnded { select(task) })
                .simultaneousGesture(TapGesture(count: 2).onEnded { appearanceEditingID = task.id })
                .popover(isPresented: isEditingAppearance(of: task.id), arrowEdge: .trailing) {
                    TaskAppearancePopover(task: task)
                }
                .contextMenu {
                    Button("Edit…") { appearanceEditingID = task.id }
                        .plumeID(AccessibilityID.taskEditButton, label: TitleStore.shared.displayTitle(for: task))
                    taskContextMenu(for: task)
                }
                .sidebarDragAndDrop(
                    .task(task.id),
                    target: .task(task.id),
                    heights: $dropTargetHeights
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
        guard let tab = tasks.flatMap(\.liveTabs).first(where: { $0.id == tabID }),
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
        selection = task.id
        isListFocused = true
    }

    private func tintBar(for task: WorkTask) -> Color? {
        SidebarTaskAppearance(task: task, settings: .shared).barTint
            .flatMap(theme.colors.color(for:))
    }

    private func washTint(for task: WorkTask) -> Color? {
        SidebarTint.effective(for: task).flatMap(theme.colors.color(for:))
    }

    private func isEditingAppearance(of id: UUID) -> Binding<Bool> {
        Binding(
            get: { appearanceEditingID == id },
            set: { isPresented in
                if !isPresented, appearanceEditingID == id {
                    appearanceEditingID = nil
                    newGroupID = nil
                }
            }
        )
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
        MarkAsUnreadButton(tabIDs: task.liveTabs.map(\.id), label: TitleStore.shared.displayTitle(for: task))
        if !task.hasNeverStarted {
            Button("Archive") { requestArchive(task) }
                .plumeID(AccessibilityID.taskArchiveButton)
        }
        if let tab = TaskRemoteControl.toggleableTab(in: task) {
            TaskRemoteControlToggle(tabID: tab.id)
        }
        linearMenuItems(for: task)
        Divider()
        Button("Delete", role: .destructive) { requestDelete(task) }
    }

    @ViewBuilder
    private func linearMenuItems(for task: WorkTask) -> some View {
        if AppSettings.shared.showsLinearIssues {
            Button("Pin Linear Issue…") { linkingLinearTask = task }
                .plumeID(AccessibilityID.taskLinkLinearIssueMenuItem, label: TitleStore.shared.displayTitle(for: task))
                .disabled(!LinearStore.shared.isConfigured)
            let working = LinearStore.shared.links(for: task, branches: task.linearBranches).filter { $0.role == .working }
            if !working.isEmpty {
                Menu("Unpin Linear Issue") {
                    ForEach(working) { issue in
                        Button("Unpin \(issue.identifier)") {
                            TaskStore.unlinkLinearIssue(issue.identifier, from: task)
                        }
                    }
                }
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

/// A task row's identity in the sidebar. Scoped to the row's section because
/// a `LazyVStack` keeps showing a row whose id moves from one of its
/// `ForEach`es to another, and stops updating it.
struct SidebarTaskRowID: Hashable {
    let groupID: UUID?
    let taskID: UUID
}

extension WorkTask {
    var sidebarRowID: SidebarTaskRowID {
        SidebarTaskRowID(groupID: group?.id, taskID: id)
    }
}
