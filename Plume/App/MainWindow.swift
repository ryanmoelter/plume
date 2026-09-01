import SwiftUI
import SwiftData

struct MainWindow: View {
    @Environment(\.modelContext) private var context
    @State private var selection: UUID?
    @State private var renamingTaskID: UUID?

    @Query(filter: #Predicate<WorkTask> { !$0.isArchived })
    private var tasks: [WorkTask]

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection, renamingTaskID: $renamingTaskID)
        } detail: {
            if let task = selectedTask {
                TaskDetailView(task: task)
            } else {
                ContentUnavailableView(
                    "No Task Selected",
                    systemImage: "sidebar.left",
                    description: Text("Select a task, or press ⌘N to create one.")
                )
            }
        }
        .focusedSceneValue(\.newTaskAction) {
            let ungrouped = tasks.filter { $0.group == nil }
            let task = TaskStore.createTask(in: context, siblings: ungrouped)
            selection = task.id
            renamingTaskID = task.id
        }
        .focusedSceneValue(\.taskCommands, selectedTask.map { task in
            TaskCommands(
                addTab: { kind in TaskStore.addTab(to: task, kind: kind, in: context) },
                selectTab: { index in
                    let tabs = task.orderedTabs
                    guard tabs.indices.contains(index) else { return }
                    task.selectedTabID = tabs[index].id
                },
                cycleTab: { offset in
                    let tabs = task.orderedTabs
                    guard !tabs.isEmpty,
                          let current = tabs.firstIndex(where: { $0.id == task.selectedTabID })
                    else { return }
                    let next = (current + offset + tabs.count) % tabs.count
                    task.selectedTabID = tabs[next].id
                },
                closeSelectedTab: {
                    guard let tab = task.orderedTabs.first(where: { $0.id == task.selectedTabID })
                    else { return }
                    TaskStore.closeTab(tab, in: context)
                }
            )
        })
        #if DEBUG
        .task { await SmokeHarness.runIfRequested(context: context, selection: $selection) }
        #endif
    }

    private var selectedTask: WorkTask? {
        guard let selection else { return nil }
        return tasks.first { $0.id == selection }
    }
}
