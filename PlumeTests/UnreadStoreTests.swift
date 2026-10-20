import Foundation
import Testing
@testable import Plume

/// A tab is unread once its turn ends off screen, and stays so until the user
/// views it or the tab moves on to another status. It follows the effective
/// status, so a turn whose subagents still work is not unread yet.
@MainActor
struct UnreadStoreTests {
    private let task = UUID()
    private let tab = UUID()

    private func observed(audience: NotificationAudience) -> (UnreadStore, StatusEngine) {
        let engine = StatusEngine(backgroundTasks: BackgroundTaskTracker())
        let store = UnreadStore()
        store.observe(engine) { audience }
        return (store, engine)
    }

    private var looking: NotificationAudience {
        NotificationAudience(isAppActive: true, selectedTaskID: task, onScreenTabIDs: [tab])
    }

    @Test func aTurnEndingOffScreenIsUnread() {
        let (store, engine) = observed(audience: .inactive)
        engine.setStatus(.working, taskID: task, tabID: tab)
        engine.setStatus(.awaitingReply, taskID: task, tabID: tab)

        #expect(store.isUnread(tabID: tab))
    }

    @Test func aTurnEndingOnScreenIsNot() {
        let (store, engine) = observed(audience: looking)
        engine.setStatus(.working, taskID: task, tabID: tab)
        engine.setStatus(.awaitingReply, taskID: task, tabID: tab)

        #expect(!store.isUnread(tabID: tab))
    }

    @Test func aTurnEndingInTheUnfocusedPaneIsNot() {
        let focused = UUID()
        let (store, engine) = observed(
            audience: NotificationAudience(isAppActive: true, selectedTaskID: task, onScreenTabIDs: [focused, tab])
        )
        engine.setStatus(.working, taskID: task, tabID: tab)
        engine.setStatus(.awaitingReply, taskID: task, tabID: tab)

        #expect(!store.isUnread(tabID: tab))
    }

    @Test func viewingASplitClearsBothPanes() {
        let other = UUID()
        let store = UnreadStore()
        store.record(.awaitingReply, tabID: tab, isOnScreen: false)
        store.record(.awaitingReply, tabID: other, isOnScreen: false)

        store.markViewed(NotificationAudience(isAppActive: true, selectedTaskID: task, onScreenTabIDs: [tab, other]))

        #expect(!store.hasUnread(among: [tab, other]))
    }

    @Test func theSelectedTabInABackgroundedAppIsUnread() {
        var audience = looking
        audience.isAppActive = false
        let (store, engine) = observed(audience: audience)
        engine.setStatus(.awaitingReply, taskID: task, tabID: tab)

        #expect(store.isUnread(tabID: tab))
    }

    @Test func workingSubagentsDeferTheMark() {
        let (store, engine) = observed(audience: .inactive)
        engine.setStatus(.working, taskID: task, tabID: tab)
        engine.setSubagentActivity(tabID: tab, working: true)
        engine.setStatus(.awaitingReply, taskID: task, tabID: tab)
        #expect(!store.isUnread(tabID: tab))

        engine.setSubagentActivity(tabID: tab, working: false)
        #expect(store.isUnread(tabID: tab))
    }

    @Test func workingAgainDropsTheMark() {
        let (store, engine) = observed(audience: .inactive)
        engine.setStatus(.awaitingReply, taskID: task, tabID: tab)

        engine.setStatus(.working, taskID: task, tabID: tab)

        #expect(!store.isUnread(tabID: tab))
    }

    @Test func viewingTheTabClearsIt() {
        let store = UnreadStore()
        store.record(.awaitingReply, tabID: tab, isOnScreen: false)

        store.markViewed(looking)

        #expect(!store.isUnread(tabID: tab))
    }

    @Test func selectingItWhileTheAppIsInactiveDoesNot() {
        let store = UnreadStore()
        store.record(.awaitingReply, tabID: tab, isOnScreen: false)
        var audience = looking
        audience.isAppActive = false

        store.markViewed(audience)

        #expect(store.isUnread(tabID: tab))
    }

    @Test func viewingAnotherTabLeavesIt() {
        let store = UnreadStore()
        store.record(.awaitingReply, tabID: tab, isOnScreen: false)

        store.markViewed(NotificationAudience(isAppActive: true, selectedTaskID: task, onScreenTabIDs: [UUID()]))

        #expect(store.isUnread(tabID: tab))
    }

    @Test func forgettingTheTabDropsIt() {
        let store = UnreadStore()
        store.record(.awaitingReply, tabID: tab, isOnScreen: false)

        store.forget(tabID: tab)

        #expect(!store.hasUnread(among: [tab]))
    }

    @Test func theNotifierKeepsFiringAlongside() {
        let (store, engine) = observed(audience: .inactive)
        var notified: [TaskStatus] = []
        engine.setTabStatusObserver("test") { _, _, status, _ in notified.append(status) }

        engine.setStatus(.awaitingReply, taskID: task, tabID: tab)

        #expect(notified == [.awaitingReply])
        #expect(store.isUnread(tabID: tab))
    }

    @Test(arguments: [TaskStatus.planApproval, .questionAsked, .permissionNeeded, .needsTerminalInput])
    func aTabWantingTheUserOutranksTheDot(status: TaskStatus) {
        #expect(!UnreadStore.showsUnread(taskStatus: status, hasUnreadTab: true))
    }

    @Test(arguments: [TaskStatus.awaitingReply, .working, .waitingOnSubagents, .error, .interrupted])
    func theDotOutranksEverythingElse(status: TaskStatus) {
        #expect(UnreadStore.showsUnread(taskStatus: status, hasUnreadTab: true))
        #expect(!UnreadStore.showsUnread(taskStatus: status, hasUnreadTab: false))
    }
}
