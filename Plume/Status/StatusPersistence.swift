import AppKit
import Foundation
import SwiftData

/// Writes status snapshots back to SwiftData and keeps the dock badge current.
///
/// Hook events are far too frequent to persist individually, so writes are
/// debounced; the badge only needs to be eventually right.
@MainActor
final class StatusPersistence {
    private let context: ModelContext
    private let engine: StatusEngine
    private var pending: [UUID: TaskStatus] = [:]
    private var flushTask: Task<Void, Never>?

    private let debounce: Duration

    init(context: ModelContext, engine: StatusEngine = .shared, debounce: Duration = .seconds(2)) {
        self.context = context
        self.engine = engine
        self.debounce = debounce

        engine.onTaskStatusChanged = { [weak self] taskID, status in
            self?.record(taskID: taskID, status: status)
        }
    }

    private func record(taskID: UUID, status: TaskStatus) {
        pending[taskID] = status
        updateDockBadge()

        flushTask?.cancel()
        flushTask = Task { [debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            flush()
        }
    }

    func flush() {
        guard !pending.isEmpty else { return }
        let snapshot = pending
        pending.removeAll()

        let descriptor = FetchDescriptor<WorkTask>()
        guard let tasks = try? context.fetch(descriptor) else { return }
        for task in tasks {
            if let status = snapshot[task.id], task.lastStatus != status {
                task.lastStatus = status
            }
        }
        try? context.save()
    }

    private func updateDockBadge() {
        let count = engine.tasksNeedingInput
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }
}
