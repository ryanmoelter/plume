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
        #expect(StatusNotifier.body(for: .needsInput) != nil)
        #expect(StatusNotifier.body(for: .done) != nil)
        #expect(StatusNotifier.body(for: .error) != nil)

        #expect(StatusNotifier.body(for: .working) == nil)
        #expect(StatusNotifier.body(for: .idle) == nil)
        #expect(StatusNotifier.body(for: .unset) == nil)
    }
}

@MainActor
struct StatusEngineTabCallbackTests {
    @Test func everyTabStatusChangeReportsItsTaskAndTab() {
        let engine = StatusEngine()
        let (task, tab) = (UUID(), UUID())
        var seen: [(UUID, UUID, TaskStatus)] = []
        engine.onTabStatusChanged = { seen.append(($0, $1, $2)) }

        engine.apply(HookEvent(hookEventName: "Notification"), taskID: task, tabID: tab)

        #expect(seen.count == 1)
        #expect(seen.first?.0 == task)
        #expect(seen.first?.1 == tab)
        #expect(seen.first?.2 == .needsInput)
    }

    /// `setStatus` returns early on an unchanged status, so a repeated
    /// `Notification` must not notify twice.
    @Test func anUnchangedStatusReportsNothing() {
        let engine = StatusEngine()
        let (task, tab) = (UUID(), UUID())
        engine.apply(HookEvent(hookEventName: "Notification"), taskID: task, tabID: tab)

        var seen = 0
        engine.onTabStatusChanged = { _, _, _ in seen += 1 }
        engine.apply(HookEvent(hookEventName: "Notification"), taskID: task, tabID: tab)

        #expect(seen == 0)
    }
}
