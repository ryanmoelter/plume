import SwiftUI
import SwiftData

struct SidebarView: View {
    @Environment(\.modelContext) private var context
    @Binding var selection: UUID?

    @Query(filter: #Predicate<WorkTask> { !$0.isArchived }, sort: \WorkTask.orderIndex)
    private var tasks: [WorkTask]
    @Query(sort: \TaskGroup.orderIndex)
    private var groups: [TaskGroup]

    @State private var renamingGroupID: UUID?

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
    }

    @ViewBuilder
    private func taskRows(in sectionTasks: [WorkTask]) -> some View {
        ForEach(sectionTasks) { task in
            TaskRowView(task: task)
                .tag(task.id)
                .contextMenu {
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
            if selection == task.id { selection = nil }
            TaskStore.delete(task, in: context)
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
        let task = TaskStore.createTask(in: context, group: group, siblings: siblings)
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
