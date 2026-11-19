import AppKit

/// Settles which tab a click on a task's sidebar row selects.
///
/// A nested line's tap and the row's own tap both see one click, since both
/// are simultaneous gestures, and SwiftUI promises no order between them. The
/// nested line claims the click's event; the row's tab choice waits one main
/// queue hop, which still lands in the same frame, and yields to a claim on
/// its event.
@MainActor
enum TaskRowClick {
    private static var claimed: (taskID: UUID, timestamp: TimeInterval)?

    static func claim(taskID: UUID) {
        guard let timestamp = NSApp.currentEvent?.timestamp else { return }
        claimed = (taskID, timestamp)
    }

    static func rowClicked(_ task: WorkTask) {
        let timestamp = NSApp.currentEvent?.timestamp
        DispatchQueue.main.async {
            if let timestamp, let claimed, claimed.taskID == task.id, claimed.timestamp == timestamp { return }
            TaskStore.selectRowClickTab(of: task)
        }
    }
}
