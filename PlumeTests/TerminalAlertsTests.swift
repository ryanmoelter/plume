import Foundation
import Testing
@testable import Plume

/// A bell marks the chip until its tab is on screen, marks the task unread
/// until the tab is focused, and notifies only when the tab is off screen.
@MainActor
struct TerminalAlertsTests {
    private let task = UUID()
    private let tab = UUID()

    @Test func aBellInTheFocusedTabIsAlreadyHeard() {
        let audience = NotificationAudience(
            isAppActive: true, selectedTaskID: task, onScreenTabIDs: [tab], focusedTabID: tab
        )

        #expect(TerminalAlerts.response(toBellIn: tab, taskID: task, audience: audience)
            == .init(marksBell: false, marksUnread: false, notifies: false))
    }

    @Test func aBellInTheUnfocusedPaneIsUnreadButNotNotified() {
        let audience = NotificationAudience(
            isAppActive: true, selectedTaskID: task, onScreenTabIDs: [tab, UUID()], focusedTabID: UUID()
        )

        #expect(TerminalAlerts.response(toBellIn: tab, taskID: task, audience: audience)
            == .init(marksBell: false, marksUnread: true, notifies: false))
    }

    @Test func aBellInAnotherTaskMarksAndNotifies() {
        let audience = NotificationAudience(
            isAppActive: true, selectedTaskID: UUID(), onScreenTabIDs: [UUID()], focusedTabID: UUID()
        )

        #expect(TerminalAlerts.response(toBellIn: tab, taskID: task, audience: audience)
            == .init(marksBell: true, marksUnread: true, notifies: true))
    }

    @Test func aBellInTheFocusedTabWhilePlumeIsBehindMarksAndNotifies() {
        let audience = NotificationAudience(
            isAppActive: false, selectedTaskID: task, onScreenTabIDs: [tab], focusedTabID: tab
        )

        #expect(TerminalAlerts.response(toBellIn: tab, taskID: task, audience: audience)
            == .init(marksBell: true, marksUnread: true, notifies: true))
    }

    @Test func eachSourceKeepsItsOwnEntryPerTab() {
        let keys = Notifier.dedupeKeys(forTab: tab)

        #expect(Set(keys).count == 3)
        #expect(keys.contains(Notifier.dedupeKey(.bell, tabID: tab)))
        #expect(!keys.contains(Notifier.dedupeKey(.bell, tabID: UUID())))
    }
}

@MainActor
struct TaskRowInactivityTests {
    @Test(arguments: [TaskStatus.notStarted, .interrupted])
    func anIdleAgentTaskDims(status: TaskStatus) {
        #expect(TaskRowView.isInactive(status: status, tabKinds: [.agent, .terminal]))
    }

    @Test(arguments: [TaskStatus.notStarted, .interrupted])
    func aTaskOfPlainTerminalsNeverDims(status: TaskStatus) {
        #expect(!TaskRowView.isInactive(status: status, tabKinds: [.terminal, .terminal]))
    }

    @Test func aWorkingAgentTaskDoesNotDim() {
        #expect(!TaskRowView.isInactive(status: .working, tabKinds: [.agent]))
    }
}
