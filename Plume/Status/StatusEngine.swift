import Foundation
import Observation

/// Live status for every agent tab, derived from hook events.
///
/// Status lives here rather than in SwiftData because events arrive far too
/// often to persist each one; only a debounced snapshot is written back.
@MainActor
@Observable
final class StatusEngine {
    static let shared = StatusEngine()

    private(set) var tabStatuses: [UUID: TaskStatus] = [:]

    /// Called with a task ID when its aggregated status changes, so the
    /// snapshot can be persisted without this type depending on SwiftData.
    @ObservationIgnored var onTaskStatusChanged: ((UUID, TaskStatus) -> Void)?

    private var tabsByTask: [UUID: Set<UUID>] = [:]

    init() {}

    // MARK: - Reading

    func status(forTab id: UUID) -> TaskStatus {
        tabStatuses[id] ?? .unset
    }

    func status(forTask id: UUID) -> TaskStatus {
        guard let tabs = tabsByTask[id] else { return .unset }
        return TaskStatus.aggregate(tabs.map { tabStatuses[$0] ?? .unset })
    }

    var tasksNeedingInput: Int {
        tabsByTask.keys.count { status(forTask: $0) == .needsInput }
    }

    // MARK: - Writing

    func apply(_ event: HookEvent, taskID: UUID, tabID: UUID) {
        // A `/clear` ends a session while the agent keeps running, so the
        // usual "session ended means idle" reading is wrong here.
        guard !event.endsClearedSession else { return }
        guard let status = Self.status(for: event.kind) else { return }
        setStatus(status, taskID: taskID, tabID: tabID)
    }

    /// The PTY child exiting means no agent is running, whatever the last
    /// hook said.
    func handleSurfaceExit(taskID: UUID, tabID: UUID, processAlive: Bool) {
        setStatus(processAlive ? .error : .idle, taskID: taskID, tabID: tabID)
    }

    func setStatus(_ status: TaskStatus, taskID: UUID, tabID: UUID) {
        tabsByTask[taskID, default: []].insert(tabID)
        guard tabStatuses[tabID] != status else { return }

        let previousTaskStatus = self.status(forTask: taskID)
        tabStatuses[tabID] = status
        let newTaskStatus = self.status(forTask: taskID)

        if newTaskStatus != previousTaskStatus {
            onTaskStatusChanged?(taskID, newTaskStatus)
        }
    }

    /// Registers a tab so its task aggregates correctly before any event
    /// arrives.
    func register(tabID: UUID, taskID: UUID, status: TaskStatus = .unset) {
        tabsByTask[taskID, default: []].insert(tabID)
        if tabStatuses[tabID] == nil {
            tabStatuses[tabID] = status
        }
    }

    func forget(tabID: UUID, taskID: UUID) {
        tabStatuses.removeValue(forKey: tabID)
        tabsByTask[taskID]?.remove(tabID)
        if tabsByTask[taskID]?.isEmpty == true {
            tabsByTask.removeValue(forKey: taskID)
        }
    }

    func reset() {
        tabStatuses.removeAll()
        tabsByTask.removeAll()
    }

    /// Nil means the event carries no status meaning and is ignored.
    static func status(for kind: HookEvent.Kind) -> TaskStatus? {
        switch kind {
        case .sessionStart, .userPromptSubmit, .preToolUse, .postToolUse:
            .working
        case .notification:
            .needsInput
        case .stop, .subagentStop:
            .done
        case .sessionEnd:
            .idle
        case .unknown:
            nil
        }
    }
}
