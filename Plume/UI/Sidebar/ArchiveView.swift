import SwiftData
import SwiftUI

/// Lists archived tasks and lets the user bring them back or delete them for
/// good. `MainWindow`'s query filters `isArchived` tasks out, so this is the
/// only way to see them again.
struct ArchiveView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query(filter: #Predicate<WorkTask> { $0.isArchived }, sort: \WorkTask.orderIndex)
    private var archivedTasks: [WorkTask]

    var body: some View {
        VStack(spacing: 0) {
            List(archivedTasks) { task in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(TitleStore.shared.displayTitle(for: task))
                        if let path = task.workingDirectoryPath {
                            Text(path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                    Spacer()
                    Button("Unarchive") { task.isArchived = false }
                    Button("Delete", role: .destructive) { TaskStore.delete(task, in: context) }
                }
            }
            .overlay {
                if archivedTasks.isEmpty {
                    ContentUnavailableView(
                        "No Archived Tasks",
                        systemImage: "archivebox",
                        description: Text("Tasks you archive from the sidebar show up here.")
                    )
                }
            }

            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 420, height: 360)
        .navigationTitle("Archive")
    }
}
