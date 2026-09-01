import SwiftUI
import SwiftData

struct MainWindow: View {
    @Environment(\.modelContext) private var context
    @State private var selection: UUID?

    @Query(filter: #Predicate<WorkTask> { !$0.isArchived })
    private var tasks: [WorkTask]

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
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
            selection = TaskStore.createTask(in: context, siblings: ungrouped).id
        }
    }

    private var selectedTask: WorkTask? {
        guard let selection else { return nil }
        return tasks.first { $0.id == selection }
    }
}
