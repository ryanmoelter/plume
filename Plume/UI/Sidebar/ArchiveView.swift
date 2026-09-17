import SwiftData
import SwiftUI

/// Lists archived tasks and lets the user bring them back or delete them for
/// good. `MainWindow`'s query filters `isArchived` tasks out, so this is the
/// only way to see them again.
struct ArchiveView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query(filter: #Predicate<WorkTask> { $0.isArchived })
    private var archivedTasks: [WorkTask]

    /// Most recently archived first. `archivedAt` is nil for tasks archived
    /// before this field existed, which fall to the bottom rather than
    /// scrambling in among dated ones.
    private var sortedTasks: [WorkTask] {
        archivedTasks.sorted { lhs, rhs in
            switch (lhs.archivedAt, rhs.archivedAt) {
            case let (l?, r?): l > r
            case (nil, nil): lhs.orderIndex < rhs.orderIndex
            case (nil, _): false
            case (_, nil): true
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // `List` already virtualizes rows via NSTableView; rows here are
            // uniform and cheap, so there's no case for a LazyVStack, which
            // carries its own scroll-hang risk (docs/chat-list-hang.md).
            List(sortedTasks) { task in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(TitleStore.shared.displayTitle(for: task))
                            .lineLimit(2)
                            .truncationMode(.tail)
                        if let path = task.workingDirectoryPath {
                            Text(path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                    Spacer()
                    Button {
                        TaskStore.unarchive(task)
                    } label: {
                        Image(systemName: "tray.and.arrow.up")
                    }
                    .buttonStyle(.borderless)
                    .help("Unarchive")
                    .accessibilityIdentifier(AccessibilityID.archivedTaskUnarchiveButton)
                    Button(role: .destructive) {
                        TaskStore.delete(task, in: context)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Delete")
                }
                .padding(.vertical, 4)
            }
            .overlay {
                if sortedTasks.isEmpty {
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
