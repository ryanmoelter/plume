import Foundation
import Testing
@testable import Plume

struct NotificationSuppressionTests {
    private let task = UUID()
    private let tab = UUID()

    private func audience(
        active: Bool = true, task: UUID?, tab: UUID?
    ) -> NotificationAudience {
        NotificationAudience(isAppActive: active, selectedTaskID: task, selectedTabID: tab)
    }

    @Test func theTabTheUserIsWatchingIsNotNotified() {
        #expect(!NotificationSuppression.shouldNotify(
            tabID: tab, taskID: task, audience: audience(task: task, tab: tab)
        ))
    }

    @Test func anotherTabInTheSameTaskIsNotified() {
        #expect(NotificationSuppression.shouldNotify(
            tabID: tab, taskID: task, audience: audience(task: task, tab: UUID())
        ))
    }

    @Test func anotherTaskIsNotified() {
        #expect(NotificationSuppression.shouldNotify(
            tabID: tab, taskID: task, audience: audience(task: UUID(), tab: tab)
        ))
    }

    /// A tab can be selected while Plume sits behind another app, and then
    /// nobody has seen it.
    @Test func aSelectedTabIsStillNotifiedWhenPlumeIsNotFrontmost() {
        #expect(NotificationSuppression.shouldNotify(
            tabID: tab, taskID: task, audience: audience(active: false, task: task, tab: tab)
        ))
    }

    @Test func noSelectionMeansNothingIsOnScreen() {
        #expect(NotificationSuppression.shouldNotify(
            tabID: tab, taskID: task, audience: .inactive
        ))
    }
}

@MainActor
struct BellStoreTests {
    @Test func aBellRungOffScreenLeavesAMark() {
        let store = BellStore()
        let tab = UUID()

        store.recordBell(tabID: tab, isOnScreen: false)

        #expect(store.hasUnseenBell(tabID: tab))
    }

    @Test func aBellRungOnScreenIsAlreadySeen() {
        let store = BellStore()
        let tab = UUID()

        store.recordBell(tabID: tab, isOnScreen: true)

        #expect(!store.hasUnseenBell(tabID: tab))
    }

    @Test func viewingTheTabClearsTheMark() {
        let store = BellStore()
        let tab = UUID()
        store.recordBell(tabID: tab, isOnScreen: false)

        store.markSeen(tabID: tab)

        #expect(!store.hasUnseenBell(tabID: tab))
    }

    @Test func marksAreTrackedPerTab() {
        let store = BellStore()
        let (rung, quiet) = (UUID(), UUID())

        store.recordBell(tabID: rung, isOnScreen: false)

        #expect(store.hasUnseenBell(tabID: rung))
        #expect(!store.hasUnseenBell(tabID: quiet))
    }
}

struct StatusNotifierBodyTests {
    @Test func onlyStatusesWorthInterruptingForHaveABody() {
        #expect(StatusNotifier.body(for: .planApproval, notifiesOnTurnEnd: false) != nil)
        #expect(StatusNotifier.body(for: .questionAsked, notifiesOnTurnEnd: false) != nil)
        #expect(StatusNotifier.body(for: .permissionNeeded, notifiesOnTurnEnd: false) != nil)
        #expect(StatusNotifier.body(for: .needsTerminalInput, notifiesOnTurnEnd: false) != nil)
        #expect(StatusNotifier.body(for: .error, notifiesOnTurnEnd: false) != nil)

        #expect(StatusNotifier.body(for: .working, notifiesOnTurnEnd: false) == nil)
        #expect(StatusNotifier.body(for: .notStarted, notifiesOnTurnEnd: false) == nil)
        #expect(StatusNotifier.body(for: .interrupted, notifiesOnTurnEnd: false) == nil)
    }

    /// Every reason the agent can want the user names what it wants, so no
    /// two of them read the same.
    @Test func eachReasonReadsDifferently() {
        let bodies = [TaskStatus.planApproval, .questionAsked, .permissionNeeded, .needsTerminalInput]
            .compactMap { StatusNotifier.body(for: $0, notifiesOnTurnEnd: false) }
        #expect(Set(bodies).count == 4)
    }

    @Test func aFinishedTurnNotifiesOnlyWhenAskedTo() {
        #expect(StatusNotifier.body(for: .awaitingReply, notifiesOnTurnEnd: false) == nil)
        #expect(StatusNotifier.body(for: .awaitingReply, notifiesOnTurnEnd: true) != nil)
    }

    /// The setting covers the finished turn alone — a state that wants an
    /// answer notifies either way.
    @Test func theTurnEndSettingLeavesTheOtherStatusesAlone() {
        for status in TaskStatus.allCases where status != .awaitingReply {
            #expect(
                StatusNotifier.body(for: status, notifiesOnTurnEnd: false)
                    == StatusNotifier.body(for: status, notifiesOnTurnEnd: true),
                "\(status)"
            )
        }
    }
}

@MainActor
struct StatusEngineTabCallbackTests {
    @Test func everyTabStatusChangeReportsItsTaskAndTab() {
        let engine = StatusEngine()
        let (task, tab) = (UUID(), UUID())
        var seen: [(UUID, UUID, TaskStatus)] = []
        engine.onTabStatusChanged = { task, tab, status, _ in seen.append((task, tab, status)) }

        engine.apply(HookEvent(hookEventName: "Notification"), taskID: task, tabID: tab)

        #expect(seen.count == 1)
        #expect(seen.first?.0 == task)
        #expect(seen.first?.1 == tab)
        #expect(seen.first?.2 == .needsTerminalInput)
    }

    /// `setStatus` returns early on an unchanged status, so a repeated
    /// `Notification` must not notify twice.
    @Test func anUnchangedStatusReportsNothing() {
        let engine = StatusEngine()
        let (task, tab) = (UUID(), UUID())
        engine.apply(HookEvent(hookEventName: "Notification"), taskID: task, tabID: tab)

        var seen = 0
        engine.onTabStatusChanged = { _, _, _, _ in seen += 1 }
        engine.apply(HookEvent(hookEventName: "Notification"), taskID: task, tabID: tab)

        #expect(seen == 0)
    }

    /// A hook event is the agent reporting on a turn the user started, so it
    /// keeps the right to interrupt them.
    @Test func aHookEventIsNotifiable() {
        let engine = StatusEngine()
        var notifiable: [Bool] = []
        engine.onTabStatusChanged = { _, _, _, flag in notifiable.append(flag) }

        engine.apply(HookEvent(hookEventName: "Notification"), taskID: UUID(), tabID: UUID())

        #expect(notifiable == [true])
    }

    /// Restoring a tab is the app rediscovering a state, not the agent
    /// reaching one.
    @Test func restoringATabIsNotNotifiable() {
        let engine = StatusEngine()
        let (task, tab) = (UUID(), UUID())
        engine.setStatus(.working, taskID: task, tabID: tab)

        var notifiable: [Bool] = []
        engine.onTabStatusChanged = { _, _, _, flag in notifiable.append(flag) }
        engine.restore(tabID: tab, taskID: task)

        #expect(notifiable == [false])
    }
}
