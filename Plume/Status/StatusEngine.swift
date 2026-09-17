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

    /// Tabs restored from disk with no process behind them. Their transcripts
    /// still describe whatever was in flight when the app last quit, so until
    /// a live session reports, nothing read from those files may claim the tab
    /// is doing anything.
    private var dormantTabs: Set<UUID> = []

    /// Called with a task ID when its aggregated status changes, so the
    /// snapshot can be persisted without this type depending on SwiftData.
    @ObservationIgnored var onTaskStatusChanged: ((UUID, TaskStatus) -> Void)?

    /// Called with the task and tab whenever a tab's own status changes.
    /// Both transports funnel through `setStatus`, so this is the one place a
    /// notification layer has to hook.
    @ObservationIgnored var onTabStatusChanged: ((UUID, UUID, TaskStatus) -> Void)?

    /// When each working tab started working, for the elapsed time the
    /// sidebar shows. Kept here rather than on the session so it covers both
    /// transports, and dropped as soon as a tab stops working so a stale
    /// start can never be read.
    private var workStartedAt: [UUID: Date] = [:]

    private var tabsByTask: [UUID: Set<UUID>] = [:]

    @ObservationIgnored private let backgroundTasks: BackgroundTaskTracker

    init(backgroundTasks: BackgroundTaskTracker = .shared) {
        self.backgroundTasks = backgroundTasks
    }

    // MARK: - Reading

    /// A tab's status as the user should see it: its own, unless its
    /// subagents are still working and its own status would read as finished.
    func status(forTab id: UUID) -> TaskStatus {
        Self.effectiveStatus(
            own: ownStatus(forTab: id),
            subagentsWorking: tabsWithWorkingSubagents.contains(id),
            dormant: dormantTabs.contains(id)
        )
    }

    /// Whether a tab was restored from disk with no process behind it. Its
    /// transcripts describe what was in flight when the app quit, so nothing
    /// read from them is happening now.
    func isDormant(tabID: UUID) -> Bool {
        dormantTabs.contains(tabID)
    }

    /// The tab's own status, ignoring its subagents.
    func ownStatus(forTab id: UUID) -> TaskStatus {
        tabStatuses[id] ?? .notStarted
    }

    /// Working subagents raise a settled tab to `working`. Every state that
    /// wants the user outranks that, along with `error` and `interrupted`:
    /// they need the user either way, and a subagent cannot answer for them.
    ///
    /// A tab never holds `done` — only a subagent reaches it — so it is left
    /// alone rather than raised.
    ///
    /// Restored tabs are dormant and never raised at all: their subagents'
    /// "working" is the state the transcript was left in, not a live process.
    static func effectiveStatus(own: TaskStatus, subagentsWorking: Bool, dormant: Bool = false) -> TaskStatus {
        guard !dormant else { return own }
        guard subagentsWorking else { return own }
        switch own {
        case .notStarted, .awaitingReply, .working:
            return .working
        case .planApproval, .questionAsked, .permissionNeeded, .needsTerminalInput,
             .error, .interrupted, .done:
            return own
        }
    }

    func status(forTask id: UUID) -> TaskStatus {
        guard let tabs = tabsByTask[id] else { return .notStarted }
        return TaskStatus.aggregate(tabs.map { status(forTab: $0) })
    }

    var tasksNeedingInput: Int {
        tabsByTask.keys.count { status(forTask: $0).wantsAttention }
    }

    /// Every tab doing something, with the task it belongs to.
    ///
    /// `KeepAwakeCoordinator` reads this to decide whether the Mac may sleep.
    /// Waiting states are included and filtered there, because whether they
    /// count depends on Remote Control, which this type knows nothing about.
    var activeTabs: [(taskID: UUID, tabID: UUID, status: TaskStatus)] {
        tabsByTask.flatMap { taskID, tabs in
            tabs.compactMap { tabID -> (UUID, UUID, TaskStatus)? in
                let status = status(forTab: tabID)
                guard status == .working || status.wantsAttention else { return nil }
                return (taskID, tabID, status)
            }
        }
    }

    /// Every tab with a background task still running, with the task it
    /// belongs to. A tab whose task never registered is dropped, the way
    /// `setSubagentActivity` drops one.
    var backgroundTaskTabs: [(taskID: UUID, tabID: UUID, kind: BackgroundTaskTracker.Kind)] {
        backgroundTasks.tabsWithBackgroundTasks.compactMap { tabID, kind in
            guard let taskID = tabsByTask.first(where: { $0.value.contains(tabID) })?.key else { return nil }
            return (taskID, tabID, kind)
        }
    }

    // MARK: - Writing

    func apply(_ event: HookEvent, taskID: UUID, tabID: UUID) {
        // A `/clear` ends a session while the agent keeps running, so the
        // usual "session ended means the turn is over" reading is wrong here.
        guard !event.endsClearedSession else { return }
        guard let status = Self.status(for: event.kind) else { return }
        setStatus(status, taskID: taskID, tabID: tabID)
    }

    /// The PTY child exiting means no agent is running, whatever the last
    /// hook said.
    func handleSurfaceExit(taskID: UUID, tabID: UUID, processAlive: Bool) {
        setStatus(processAlive ? .error : .awaitingReply, taskID: taskID, tabID: tabID)
    }

    /// Registers a tab restored from disk. It has no process behind it and
    /// will not get one until the user sends a message, so it reads as
    /// `notStarted` and stays deaf to anything its old transcript says.
    func restore(tabID: UUID, taskID: UUID) {
        setStatus(.notStarted, taskID: taskID, tabID: tabID)
        dormantTabs.insert(tabID)
    }

    func setStatus(_ status: TaskStatus, taskID: UUID, tabID: UUID) {
        tabsByTask[taskID, default: []].insert(tabID)
        dormantTabs.remove(tabID)
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

    /// When the tab started the work it is doing now, or nil if it is not
    /// working. Reset every time work starts, so the clock times this stretch
    /// rather than the tab's whole life.
    func workStarted(forTab id: UUID) -> Date? {
        workStartedAt[id]
    }

    /// The oldest running clock among a task's tabs, so a collapsed task
    /// reports the work that has been going longest.
    func workStarted(forTask id: UUID) -> Date? {
        tabsByTask[id]?.compactMap { workStartedAt[$0] }.min()
    }

    /// Announces effective status, so a notifier or snapshot never sees a
    /// finished turn the subagents contradict.
    private func report(
        taskID: UUID,
        tabID: UUID,
        previousTabStatus: TaskStatus,
        previousTaskStatus: TaskStatus
    ) {
        let newTabStatus = status(forTab: tabID)
        if newTabStatus != previousTabStatus {
            // Keyed off the effective status, so working subagents start the
            // clock too and a tab that stops working never keeps a stale one.
            if newTabStatus == .working {
                workStartedAt[tabID] = Date()
            } else {
                workStartedAt.removeValue(forKey: tabID)
            }
            onTabStatusChanged?(taskID, tabID, newTabStatus)
        }
        let newTaskStatus = status(forTask: taskID)
        if newTaskStatus != previousTaskStatus {
            onTaskStatusChanged?(taskID, newTaskStatus)
        }
    }

    /// Registers a tab so its task aggregates correctly before any event
    /// arrives.
    func register(tabID: UUID, taskID: UUID, status: TaskStatus = .notStarted) {
        tabsByTask[taskID, default: []].insert(tabID)
        if tabStatuses[tabID] == nil {
            tabStatuses[tabID] = status
        }
    }

    func forget(tabID: UUID, taskID: UUID) {
        backgroundTasks.forget(tabID: tabID)
        tabStatuses.removeValue(forKey: tabID)
        tabsWithWorkingSubagents.remove(tabID)
        dormantTabs.remove(tabID)
        workStartedAt.removeValue(forKey: tabID)
        tabsByTask[taskID]?.remove(tabID)
        if tabsByTask[taskID]?.isEmpty == true {
            tabsByTask.removeValue(forKey: taskID)
        }
    }

    func reset() {
        backgroundTasks.reset()
        tabStatuses.removeAll()
        tabsWithWorkingSubagents.removeAll()
        dormantTabs.removeAll()
        workStartedAt.removeAll()
        tabsByTask.removeAll()
    }

    /// Nil means the event carries no status meaning and is ignored.
    ///
    /// A notification is the terminal transport's only way to say the agent
    /// wants the user, and it never says why — hence the unnamed status. The
    /// headless transport names its reason instead, in `HeadlessSession`.
    static func status(for kind: HookEvent.Kind) -> TaskStatus? {
        switch kind {
        case .sessionStart, .userPromptSubmit, .preToolUse, .postToolUse:
            .working
        case .notification:
            .needsTerminalInput
        case .stop, .subagentStop, .sessionEnd:
            .awaitingReply
        case .unknown:
            nil
        }
    }
}
