import Foundation
import SwiftData
import Testing
@testable import Plume

/// A child's finished turn becomes a note to its parent only when the parent
/// started that turn, with its brief or a message, even one merged with
/// what the user typed. A turn the user drove in the child sends nothing.
/// The parent here has no session to wake, so a note it gets waits for its
/// user's next message, which is where these tests read it.
@MainActor
struct ChildSessionTurnReportTests {
    private let context: ModelContext

    init() throws {
        context = ModelContext(try ModelContainer(
            for: Schema([TaskGroup.self, WorkTask.self, TaskTab.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        ))
    }

    private struct Family {
        let parent: HeadlessSession
        let child: HeadlessSession
        /// The coordinator holds tabs weakly.
        let tabs: [TaskTab]
    }

    private func family() throws -> Family {
        let task = TaskStore.createTask(in: context, siblings: [])
        let parentTab = try #require(task.tabs.first)
        let childTab = TaskStore.addTab(to: task, kind: .agent, in: context)
        childTab.parentTabID = parentTab.id
        try context.save()
        let parent = HeadlessSession(tabID: parentTab.id, taskID: task.id)
        let child = HeadlessSession(tabID: childTab.id, taskID: task.id)
        child.queuedMessageDelivery = { .endOfTurn }
        child.debugLineSink = { _ in }
        ChildSessionCoordinator.shared.attach(to: parent, task: task, tab: parentTab)
        ChildSessionCoordinator.shared.attach(to: child, task: task, tab: childTab)
        return Family(parent: parent, child: child, tabs: [parentTab, childTab])
    }

    private func forget(_ family: Family) {
        family.tabs.forEach { ChildSessionCoordinator.shared.tabForgotten($0.id) }
    }

    private func finishTurn(_ session: HeadlessSession) {
        session.handle(StreamJSONDecoder.decode(
            line: #"{"type":"result","subtype":"success","is_error":false,"result":"DONE"}"#
        )!)
    }

    private func heldForParent(_ family: Family) -> String? {
        family.parent.userMessagePreamble?()?.wire.plainText
    }

    @Test func aTurnTheUserDroveInTheChildSendsNoNote() throws {
        let family = try family()
        defer { forget(family) }

        family.child.submit(text: "typed")
        finishTurn(family.child)

        #expect(heldForParent(family) == nil)
    }

    @Test func aTurnTheParentsMessageStartedSendsANote() throws {
        let family = try family()
        defer { forget(family) }

        family.child.submitFromHost(blocks: [.text("brief")], origin: .fromParent(text: "brief"))
        finishTurn(family.child)

        #expect(heldForParent(family)?.contains(#""event":"turn_finished""#) == true)
    }

    @Test func aTurnWokenByTheChildsOwnChildrenSendsNoNote() throws {
        let family = try family()
        defer { forget(family) }

        family.child.submitFromHost(blocks: [.text("grandchild notes")], origin: .notes([]))
        finishTurn(family.child)

        #expect(heldForParent(family) == nil)
    }
}
