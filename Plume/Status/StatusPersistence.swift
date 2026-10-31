import AppKit
import Foundation
import SwiftData

/// Writes status snapshots back to SwiftData and keeps the dock badge current.
///
/// Hook events are far too frequent to persist individually, so writes are
/// debounced; the badge only needs to be eventually right.
@MainActor
final class StatusPersistence {
    /// The latest one wins, as it does for the engine's observers.
    private(set) static weak var current: StatusPersistence?

    private let context: ModelContext
    private let engine: StatusEngine
    private var pending: [UUID: TaskStatus] = [:]
    private var pendingTabs: [UUID: TaskStatus] = [:]
    private var flushTask: Task<Void, Never>?

    private let debounce: Duration

    init(context: ModelContext, engine: StatusEngine = .shared, debounce: Duration = .seconds(2)) {
        self.context = context
        self.engine = engine
        self.debounce = debounce
        Self.current = self

        engine.onTaskStatusChanged = { [weak self] taskID, status in
            self?.record(taskID: taskID, status: status)
        }
        engine.setTabStatusObserver("StatusPersistence") { [weak self] _, tabID, status, _ in
            self?.record(tabID: tabID, status: status)
        }
    }

    private func record(taskID: UUID, status: TaskStatus) {
        pending[taskID] = status
        updateDockBadge()
        scheduleFlush()
    }

    private func record(tabID: UUID, status: TaskStatus) {
        pendingTabs[tabID] = status
        scheduleFlush()
    }

    private func scheduleFlush() {
        flushTask?.cancel()
        flushTask = Task { [debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            flush()
        }
    }

    func flush() {
        guard !pending.isEmpty || !pendingTabs.isEmpty else { return }
        let snapshot = pending
        let tabSnapshot = pendingTabs
        pending.removeAll()
        pendingTabs.removeAll()

        if !snapshot.isEmpty, let tasks = try? context.fetch(FetchDescriptor<WorkTask>()) {
            for task in tasks {
                if let status = snapshot[task.id], task.lastStatus != status {
                    task.lastStatus = status
                }
            }
        }
        if !tabSnapshot.isEmpty, let tabs = try? context.fetch(FetchDescriptor<TaskTab>()) {
            for tab in tabs {
                if let status = tabSnapshot[tab.id], tab.lastStatus != status {
                    tab.lastStatus = status
                }
            }
        }
        try? context.save()
    }

    private func updateDockBadge() {
        let count = engine.tasksNeedingInput
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }
}
