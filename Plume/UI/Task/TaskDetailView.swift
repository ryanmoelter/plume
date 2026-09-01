import SwiftUI
import SwiftData

/// Placeholder detail pane. The tab strip and terminal surfaces land in
/// Phase 1/2; this shows the persisted structure so CRUD is verifiable now.
struct TaskDetailView: View {
    @Environment(\.modelContext) private var context
    @Bindable var task: WorkTask

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextField("Task title", text: $task.title)
                .textFieldStyle(.plain)
                .font(.largeTitle)

            LabeledContent("Workspace") {
                Text(workspaceDescription)
                    .foregroundStyle(task.workspaceKind == .unset ? .secondary : .primary)
            }
            LabeledContent("Group", value: task.group?.name ?? "Ungrouped")
            LabeledContent("Created", value: task.createdAt.formatted(date: .abbreviated, time: .shortened))

            Divider()

            HStack {
                Text("Tabs").font(.headline)
                Spacer()
                Button("Agent") { TaskStore.addTab(to: task, kind: .agent, in: context) }
                Button("Terminal") { TaskStore.addTab(to: task, kind: .terminal, in: context) }
            }

            ForEach(task.orderedTabs) { tab in
                HStack {
                    Image(systemName: tab.kind == .agent ? "sparkles" : "terminal")
                    Text(tab.displayTitle)
                    if task.selectedTabID == tab.id {
                        Text("selected").foregroundStyle(.secondary).font(.caption)
                    }
                    Spacer()
                    Button("Close") { TaskStore.closeTab(tab, in: context) }
                        .buttonStyle(.borderless)
                }
                .contentShape(.rect)
                .onTapGesture { task.selectedTabID = tab.id }
            }

            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var workspaceDescription: String {
        switch task.workspaceKind {
        case .unset: "Not set"
        case .directory: task.workingDirectoryPath ?? "Not set"
        case .worktree: task.branchName.map { "\($0) — \(task.workingDirectoryPath ?? "")" } ?? "Not set"
        }
    }
}
