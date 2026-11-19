import Foundation

/// Remembers the last task the sidebar selected, so Home's composer can start
/// on its group and project.
///
/// Kept out of `AppSettings`, which holds preferences the Settings window
/// offers — this is restored window state, and nobody sets it deliberately.
///
/// The write to user defaults waits until selection has been still for
/// `writeDelay`. Every write posts a change notification that AppKit answers
/// by rebuilding the merged domain on the main thread, at a cost that grows
/// with its key count, in the middle of the task switch that caused it.
@MainActor
final class LastOpenTask {
    static let shared = LastOpenTask()

    private static let key = "lastSelectedTaskID"

    private let defaults: UserDefaults
    private let writeDelay: Duration
    private(set) var lastTask: UUID?
    private var written: UUID?
    private var pendingWrite: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, writeDelay: Duration = .seconds(2)) {
        self.defaults = defaults
        self.writeDelay = writeDelay
        lastTask = defaults.string(forKey: Self.key).flatMap(UUID.init(uuidString:))
        written = lastTask
    }

    /// Choosing Home, or clearing the selection, leaves the last task in place.
    func record(_ selection: SidebarSelection?) {
        guard case .task(let id) = selection, id != lastTask else { return }
        lastTask = id
        pendingWrite?.cancel()
        pendingWrite = Task { [weak self, writeDelay] in
            try? await Task.sleep(for: writeDelay)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    func flush() {
        pendingWrite?.cancel()
        pendingWrite = nil
        guard let lastTask, lastTask != written else { return }
        defaults.set(lastTask.uuidString, forKey: Self.key)
        written = lastTask
    }
}
