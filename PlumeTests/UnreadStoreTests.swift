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
        NotificationAudience(isAppActive: true, selectedTaskID: task, onScreenTabIDs: [tab], focusedTabID: tab)
    }

    private func split(focused: UUID, other: UUID) -> NotificationAudience {
        NotificationAudience(isAppActive: true, selectedTaskID: task, onScreenTabIDs: [focused, other], focusedTabID: focused)
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

    @Test func aTurnEndingInTheUnfocusedPaneIsUnreadButNotNotified() {
        let audience = split(focused: UUID(), other: tab)
        let (store, engine) = observed(audience: audience)
        engine.setStatus(.working, taskID: task, tabID: tab)
        engine.setStatus(.awaitingReply, taskID: task, tabID: tab)

        #expect(store.isUnread(tabID: tab))
        #expect(!NotificationSuppression.shouldNotify(tabID: tab, taskID: task, audience: audience))
    }

    @Test func aTurnEndingInTheFocusedPaneIsNot() {
        let (store, engine) = observed(audience: split(focused: tab, other: UUID()))
        engine.setStatus(.working, taskID: task, tabID: tab)
        engine.setStatus(.awaitingReply, taskID: task, tabID: tab)

        #expect(!store.isUnread(tabID: tab))
    }

    @Test func viewingASplitClearsOnlyTheFocusedPane() {
        let other = UUID()
        let store = UnreadStore()
        store.record(.awaitingReply, tabID: tab, isSeen: false)
        store.record(.awaitingReply, tabID: other, isSeen: false)

        store.markViewed(split(focused: tab, other: other))

        #expect(!store.isUnread(tabID: tab))
        #expect(store.isUnread(tabID: other))
    }

    @Test func focusingTheOtherPaneClearsIt() {
        let other = UUID()
        let store = UnreadStore()
        store.record(.awaitingReply, tabID: other, isSeen: false)
        store.markViewed(split(focused: tab, other: other))

        store.markViewed(split(focused: other, other: tab))

        #expect(!store.isUnread(tabID: other))
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
        store.record(.awaitingReply, tabID: tab, isSeen: false)

        store.markViewed(looking)

        #expect(!store.isUnread(tabID: tab))
    }

    @Test func selectingItWhileTheAppIsInactiveDoesNot() {
        let store = UnreadStore()
        store.record(.awaitingReply, tabID: tab, isSeen: false)
        var audience = looking
        audience.isAppActive = false

        store.markViewed(audience)

        #expect(store.isUnread(tabID: tab))
    }

    @Test func viewingAnotherTabLeavesIt() {
        let store = UnreadStore()
        store.record(.awaitingReply, tabID: tab, isSeen: false)

        let shown = UUID()
        store.markViewed(NotificationAudience(isAppActive: true, selectedTaskID: task, onScreenTabIDs: [shown], focusedTabID: shown))

        #expect(store.isUnread(tabID: tab))
    }

    @Test func forgettingTheTabDropsIt() {
        let store = UnreadStore()
        store.record(.awaitingReply, tabID: tab, isSeen: false)

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

    @Test func aReadTurnCanBeMarkedUnread() {
        let (store, engine) = observed(audience: looking)
        engine.setStatus(.awaitingReply, taskID: task, tabID: tab)

        #expect(store.tabsToMarkUnread([tab: .awaitingReply]) == [tab])
    }

    @Test(arguments: [TaskStatus.notStarted, .working, .waitingOnSubagents, .questionAsked, .interrupted, .error])
    func onlyAFinishedTurnCanBeMarkedUnread(status: TaskStatus) {
        #expect(UnreadStore().tabsToMarkUnread([tab: status]).isEmpty)
    }

    @Test func anUnreadTurnCannotBeMarkedAgain() {
        let store = UnreadStore()
        store.record(.awaitingReply, tabID: tab, isSeen: false)

        #expect(store.tabsToMarkUnread([tab: .awaitingReply]).isEmpty)
    }

    @Test func aTaskMarksTheTabThatFinishedLast() {
        let earlier = UUID()
        let store = UnreadStore()
        store.record(.awaitingReply, tabID: tab, isSeen: true)
        store.record(.awaitingReply, tabID: earlier, isSeen: true)
        store.record(.working, tabID: tab, isSeen: true)
        store.record(.awaitingReply, tabID: tab, isSeen: true)

        #expect(store.tabsToMarkUnread([tab: .awaitingReply, earlier: .awaitingReply, UUID(): .notStarted]) == [tab])
    }

    @Test func aTaskWithNoRecordedFinishMarksEveryReadTab() {
        let other = UUID()

        let marked = UnreadStore().tabsToMarkUnread([tab: .awaitingReply, other: .awaitingReply])

        #expect(Set(marked) == [tab, other])
    }

    @Test func aTaskStillWorkingCannotBeMarkedUnread() {
        #expect(UnreadStore().tabsToMarkUnread([tab: .awaitingReply, UUID(): .working]).isEmpty)
    }

    /// Only the next view clears a mark set on the focused tab; the tab
    /// staying on screen does not.
    @Test func markingTheFocusedTabUnreadLastsUntilItIsViewedAgain() {
        let (store, engine) = observed(audience: looking)
        engine.setStatus(.awaitingReply, taskID: task, tabID: tab)

        store.markUnread([tab])
        #expect(store.isUnread(tabID: tab))

        store.markViewed(looking)
        #expect(!store.isUnread(tabID: tab))
    }

    @Test func markingUnreadInAnUnfocusedPaneClearsOnFocusingIt() {
        let focused = UUID()
        let store = UnreadStore()
        store.record(.awaitingReply, tabID: tab, isSeen: true)
        store.markUnread([tab])

        store.markViewed(split(focused: focused, other: tab))
        #expect(store.isUnread(tabID: tab))

        store.markViewed(split(focused: tab, other: focused))
        #expect(!store.isUnread(tabID: tab))
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

    @Test func markingReadClearsOnlyTheNamedTabs() {
        let store = UnreadStore()
        let other = UUID()
        store.markUnread([tab, other])

        store.markRead([tab])

        #expect(!store.isUnread(tabID: tab))
        #expect(store.isUnread(tabID: other))
    }
}
