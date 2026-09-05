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

    /// Each tab's own status, before subagent activity is folded in. Read
    /// `status(forTab:)` for what the user should actually see.
    private(set) var tabStatuses: [UUID: TaskStatus] = [:]

    /// Tabs with at least one subagent still working. A main agent can end
    /// its turn while the subagents it spawned keep going, and calling that
    /// "done" invites the user back to a task that is still moving.
    private var tabsWithWorkingSubagents: Set<UUID> = []

    /// Called with a task ID when its aggregated status changes, so the
    /// snapshot can be persisted without this type depending on SwiftData.
    @ObservationIgnored var onTaskStatusChanged: ((UUID, TaskStatus) -> Void)?

    /// Called with the task and tab whenever a tab's own status changes.
    /// Both transports funnel through `setStatus`, so this is the one place a
    /// notification layer has to hook.
    @ObservationIgnored var onTabStatusChanged: ((UUID, UUID, TaskStatus) -> Void)?

    private var tabsByTask: [UUID: Set<UUID>] = [:]

    init() {}

    // MARK: - Reading

    /// A tab's status as the user should see it: its own, unless its
    /// subagents are still working and its own status would read as finished.
    func status(forTab id: UUID) -> TaskStatus {
        Self.effectiveStatus(
            own: ownStatus(forTab: id),
            subagentsWorking: tabsWithWorkingSubagents.contains(id)
        )
    }

    /// The tab's own status, ignoring its subagents.
    func ownStatus(forTab id: UUID) -> TaskStatus {
        tabStatuses[id] ?? .unset
    }

    /// Working subagents raise a settled tab to `working`. `needsInput`,
    /// `error` and `interrupted` outrank that: they need the user either way,
    /// and a subagent cannot clear them.
    static func effectiveStatus(own: TaskStatus, subagentsWorking: Bool) -> TaskStatus {
        guard subagentsWorking else { return own }
        switch own {
        case .unset, .idle, .done, .working: return .working
        case .needsInput, .error, .interrupted: return own
        }
    }

    func status(forTask id: UUID) -> TaskStatus {
        guard let tabs = tabsByTask[id] else { return .unset }
        return TaskStatus.aggregate(tabs.map { status(forTab: $0) })
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

        let previousTabStatus = self.status(forTab: tabID)
        let previousTaskStatus = self.status(forTask: taskID)
        tabStatuses[tabID] = status
        report(taskID: taskID, tabID: tabID, previousTabStatus: previousTabStatus, previousTaskStatus: previousTaskStatus)
    }

    /// Records whether a tab's conversation still has subagents working.
    /// Fed from `TranscriptStore`, which watches each subagent transcript.
    ///
    /// The task is resolved here because the transcript layer only knows tab
    /// IDs. A tab that never registered has no task to aggregate into, so its
    /// activity is dropped rather than inventing one.
    func setSubagentActivity(tabID: UUID, working: Bool) {
        guard let taskID = tabsByTask.first(where: { $0.value.contains(tabID) })?.key else { return }
        guard tabsWithWorkingSubagents.contains(tabID) != working else { return }

        let previousTabStatus = self.status(forTab: tabID)
        let previousTaskStatus = self.status(forTask: taskID)
        if working {
            tabsWithWorkingSubagents.insert(tabID)
        } else {
            tabsWithWorkingSubagents.remove(tabID)
        }
        report(taskID: taskID, tabID: tabID, previousTabStatus: previousTabStatus, previousTaskStatus: previousTaskStatus)
    }

    /// Announces effective status, so a notifier or snapshot never sees a
    /// `done` the subagents contradict.
    private func report(
        taskID: UUID,
        tabID: UUID,
        previousTabStatus: TaskStatus,
        previousTaskStatus: TaskStatus
    ) {
        let newTabStatus = status(forTab: tabID)
        if newTabStatus != previousTabStatus {
            onTabStatusChanged?(taskID, tabID, newTabStatus)
        }
        let newTaskStatus = status(forTask: taskID)
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
        tabsWithWorkingSubagents.remove(tabID)
        tabsByTask[taskID]?.remove(tabID)
        if tabsByTask[taskID]?.isEmpty == true {
            tabsByTask.removeValue(forKey: taskID)
        }
    }

    func reset() {
        tabStatuses.removeAll()
        tabsWithWorkingSubagents.removeAll()
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
