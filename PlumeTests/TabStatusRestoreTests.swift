import Testing
import Foundation
import SwiftData
@testable import Plume

/// Each tab persists its last status and comes back at launch with
/// `afterRelaunch` applied, dormant, and without notifying.
@MainActor
struct TabStatusRestoreTests {
    @Test(arguments: TaskStatus.allCases)
    func aRestoredTabReadsItsPersistedStatusAfterRelaunch(persisted: TaskStatus) {
        let engine = StatusEngine(backgroundTasks: BackgroundTaskTracker())
        let (task, tab) = (UUID(), UUID())

        engine.restore(tabID: tab, taskID: task, lastStatus: persisted)

        #expect(engine.status(forTab: tab) == persisted.afterRelaunch)
        #expect(engine.isDormant(tabID: tab))
    }

    @Test func aRestoredStatusIsNeverNotifiable() {
        let engine = StatusEngine(backgroundTasks: BackgroundTaskTracker())
        var reports: [(TaskStatus, Bool)] = []
        engine.setTabStatusObserver("test") { _, _, status, notifiable in reports.append((status, notifiable)) }

        engine.restore(tabID: UUID(), taskID: UUID(), lastStatus: .error)
        engine.restore(tabID: UUID(), taskID: UUID(), lastStatus: .questionAsked)

        #expect(reports.map(\.0) == [.error, .interrupted])
        #expect(reports.allSatisfy { !$0.1 })
    }

    /// The old transcript's subagents were in flight when the app quit, so
    /// they never raise a restored tab.
    @Test func aRestoredStatusStaysPutUntilALiveReport() {
        let engine = StatusEngine(backgroundTasks: BackgroundTaskTracker())
        let (task, tab) = (UUID(), UUID())
        engine.restore(tabID: tab, taskID: task, lastStatus: .questionAsked)

        engine.setSubagentActivity(tabID: tab, working: true)
        #expect(engine.status(forTab: tab) == .interrupted)
        #expect(engine.activeTabs.isEmpty)

        engine.setStatus(.working, taskID: task, tabID: tab)
        #expect(!engine.isDormant(tabID: tab))
        #expect(engine.status(forTab: tab) == .working)
    }

    /// Restored tabs aggregate the way live ones do, and an interrupted or
    /// errored task keeps full strength in the sidebar.
    @Test func aTaskOfRestoredTabsAggregatesAndDoesNotDim() {
        let engine = StatusEngine(backgroundTasks: BackgroundTaskTracker())
        let task = UUID()
        engine.restore(tabID: UUID(), taskID: task, lastStatus: .working)
        engine.restore(tabID: UUID(), taskID: task, lastStatus: .planApproval)
        #expect(engine.status(forTask: task) == .interrupted)
        #expect(!TaskRowView.isInactive(status: engine.status(forTask: task), tabKinds: [.agent]))

        engine.restore(tabID: UUID(), taskID: task, lastStatus: .error)
        #expect(engine.status(forTask: task) == .error)
        #expect(!TaskRowView.isInactive(status: engine.status(forTask: task), tabKinds: [.agent]))
    }

    @Test func aTaskWhoseTabsAllRestoreAsNotStartedStillDims() {
        let engine = StatusEngine(backgroundTasks: BackgroundTaskTracker())
        let task = UUID()
        engine.restore(tabID: UUID(), taskID: task, lastStatus: .working)
        engine.restore(tabID: UUID(), taskID: task, lastStatus: .awaitingReply)

        #expect(engine.status(forTask: task) == .notStarted)
        #expect(TaskRowView.isInactive(status: .notStarted, tabKinds: [.agent]))
    }

    /// An errored chat wants the user after a relaunch; an interrupted one
    /// lists with the conversations not yet started.
    @Test func homeCountsARestoredErrorAsNeedingTheUser() {
        #expect(HomeFeed.needsYou(status: TaskStatus.error.afterRelaunch, isUnread: false))
        #expect(!HomeFeed.needsYou(status: TaskStatus.questionAsked.afterRelaunch, isUnread: false))
    }

    /// `MainWindow` drains a terminal tab's hook log before restoring it, so
    /// the last run's finished turn replays first.
    @Test(arguments: [TaskStatus.awaitingReply, .error, .questionAsked])
    func aReplayedFinishedTurnLeavesNoUnreadMarkOnceRestored(persisted: TaskStatus) {
        let engine = StatusEngine(backgroundTasks: BackgroundTaskTracker())
        let unread = UnreadStore()
        unread.observe(engine) { .inactive }
        let (task, tab) = (UUID(), UUID())

        for name in ["SessionStart", "UserPromptSubmit", "Stop", "SessionEnd"] {
            engine.apply(HookEvent(hookEventName: name), taskID: task, tabID: tab)
        }
        engine.restore(tabID: tab, taskID: task, lastStatus: persisted)

        #expect(engine.status(forTab: tab) == persisted.afterRelaunch)
        #expect(!unread.isUnread(tabID: tab))
    }

    @Test func closingACodexTerminalReportsNoStatusButItsExitDoes() {
        #expect(CodexTerminalMonitor.statusAfterStop(failed: true, reportsStatus: false) == nil)
        #expect(CodexTerminalMonitor.statusAfterStop(failed: false, reportsStatus: false) == nil)
        #expect(CodexTerminalMonitor.statusAfterStop(failed: true, reportsStatus: true) == .error)
        #expect(CodexTerminalMonitor.statusAfterStop(failed: false, reportsStatus: true) == .awaitingReply)
    }

    // MARK: - Persistence

    @Test func aTabsStatusRoundTripsThroughTheStore() throws {
        let context = ModelContext(try ModelContainer(
            for: Schema([TaskGroup.self, WorkTask.self, TaskTab.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        ))
        let task = WorkTask(title: "Task", orderIndex: 0)
        context.insert(task)
        let tab = TaskTab(kind: .agent, orderIndex: 0, task: task)
        context.insert(tab)
        try context.save()

        let engine = StatusEngine(backgroundTasks: BackgroundTaskTracker())
        let persistence = StatusPersistence(context: context, engine: engine, debounce: .seconds(60))
        engine.setStatus(.permissionNeeded, taskID: task.id, tabID: tab.id)
        #expect(tab.lastStatus == .notStarted)
        persistence.flush()

        #expect(tab.lastStatus == .permissionNeeded)
        #expect(task.lastStatus == .permissionNeeded)

        let relaunched = StatusEngine(backgroundTasks: BackgroundTaskTracker())
        relaunched.restore(tabID: tab.id, taskID: task.id, lastStatus: tab.lastStatus)
        #expect(relaunched.status(forTab: tab.id) == .interrupted)
    }

    @Test func anUnknownPersistedValueReadsAsNotStarted() {
        let tab = TaskTab(kind: .agent, orderIndex: 0)
        #expect(tab.lastStatus == .notStarted)
        tab.lastStatusRaw = "needsInput"
        #expect(tab.lastStatus == .needsTerminalInput)
    }
}
