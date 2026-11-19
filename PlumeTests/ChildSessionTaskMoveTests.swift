import Foundation
import SwiftData
import Testing
@testable import Plume

/// Moving a tab to another task takes the children attached to it, in order
/// and still linked, and leaves detached ones behind. A child moves on its own
/// freely, and Move Next to Parent brings a detached child back to the end of
/// its parent's run, whatever pane or task the parent is in.
@MainActor
struct ChildSessionTaskMoveTests {
    private let context: ModelContext

    init() throws {
        let container = try ModelContainer(
            for: Schema([TaskGroup.self, WorkTask.self, TaskTab.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        context = ModelContext(container)
    }

    private struct Family {
        let task: WorkTask
        let parent: TaskTab
        let child: TaskTab
        let grandchild: TaskTab
        let secondChild: TaskTab
        let other: TaskTab
    }

    /// Strip order: parent, child, grandchild, secondChild, other.
    private func makeFamily() throws -> Family {
        let task = TaskStore.createTask(in: context, siblings: [])
        let parent = try #require(task.tabs.first)
        let child = TaskStore.addChildTab(to: task, parent: parent, in: context)
        let secondChild = TaskStore.addChildTab(to: task, parent: parent, in: context)
        let grandchild = TaskStore.addChildTab(to: task, parent: child, in: context)
        let other = TaskStore.addTab(to: task, kind: .terminal, in: context)
        return Family(task: task, parent: parent, child: child, grandchild: grandchild, secondChild: secondChild, other: other)
    }

    @Test func movingAParentTakesItsAttachedChildrenInOrder() throws {
        let family = try makeFamily()
        let destination = TaskStore.createTask(in: context, siblings: [family.task])
        let existing = try #require(destination.tabs.first)

        #expect(TaskStore.moveTab(family.parent, to: destination))

        let moved = [family.parent, family.child, family.grandchild, family.secondChild]
        #expect(destination.tabs(inPane: 0).map(\.id) == [existing.id] + moved.map(\.id))
        #expect(destination.tabs(inPane: 0).map(\.orderIndex) == [0, 1, 2, 3, 4])
        #expect(family.child.parentTabID == family.parent.id)
        #expect(family.grandchild.parentTabID == family.child.id)
        #expect(family.task.tabs(inPane: 0).map(\.id) == [family.other.id])
        #expect(family.task.tabs(inPane: 0).map(\.orderIndex) == [0])
        #expect(destination.selectedTabID == family.parent.id)
    }

    @Test func movingAParentLeavesDetachedChildrenBehind() throws {
        let family = try makeFamily()
        TaskStore.moveTab(family.secondChild, toPane: 0, at: 5, in: family.task)
        let destination = TaskStore.createTask(in: context, siblings: [family.task])
        let existing = try #require(destination.tabs.first)

        #expect(TaskStore.moveTab(family.parent, to: destination))

        #expect(destination.tabs(inPane: 0).map(\.id)
            == [existing, family.parent, family.child, family.grandchild].map(\.id))
        #expect(family.task.tabs(inPane: 0).map(\.id) == [family.other, family.secondChild].map(\.id))
        #expect(family.secondChild.parentTabID == family.parent.id)
    }

    @Test func aChildMovesToAnotherTaskOnItsOwn() throws {
        let family = try makeFamily()
        let destination = TaskStore.createTask(in: context, siblings: [family.task])

        #expect(TaskStore.canMoveToNewTask(family.grandchild))
        #expect(TaskStore.moveTab(family.child, to: destination))

        #expect(Array(destination.tabs(inPane: 0).map(\.id).suffix(2)) == [family.child, family.grandchild].map(\.id))
        #expect(family.task.tabs(inPane: 0).map(\.id) == [family.parent, family.secondChild, family.other].map(\.id))
        #expect(family.child.parentTabID == family.parent.id)
        #expect(TaskStore.openParent(of: family.child)?.id == family.parent.id)
        #expect(TaskStore.openChildren(of: family.parent).map(\.id) == [family.secondChild, family.child].map(\.id))
    }

    @Test func aGroupThatIsTheWholeTaskCannotMoveToANewTask() throws {
        let family = try makeFamily()
        #expect(TaskStore.canMoveToNewTask(family.parent))

        TaskStore.closeTab(family.other, in: context)

        #expect(!TaskStore.canMoveToNewTask(family.parent))
    }

    @Test func movingToANewTaskTakesTheAttachedChildren() throws {
        let family = try makeFamily()

        let newTask = try #require(TaskStore.splitTabIntoNewTask(family.parent, in: context, siblings: [family.task]))

        #expect(newTask.tabs(inPane: 0).map(\.id)
            == [family.parent, family.child, family.grandchild, family.secondChild].map(\.id))
        #expect(family.task.tabs(inPane: 0).map(\.id) == [family.other.id])
    }

    @Test func aChildInAnotherPaneIsNotCarried() throws {
        let family = try makeFamily()
        TaskStore.moveTab(family.secondChild, toPane: 0, at: 5, in: family.task)
        TaskStore.openInSplit(family.secondChild, side: .right, in: family.task)
        let destination = TaskStore.createTask(in: context, siblings: [family.task])

        TaskStore.moveTab(family.parent, to: destination)

        #expect(family.secondChild.task?.id == family.task.id)
        #expect(family.task.panes.map { $0.map(\.id) } == [[family.other.id], [family.secondChild.id]])
    }

    // MARK: - Detached marker

    @Test func aChildIsDetachedOnlyOutsideItsParentsRun() throws {
        let family = try makeFamily()
        #expect(!TaskStore.isDetachedChild(family.child))
        #expect(!TaskStore.isDetachedChild(family.grandchild))
        #expect(!TaskStore.isDetachedChild(family.parent))

        TaskStore.moveTab(family.secondChild, toPane: 0, at: 5, in: family.task)
        #expect(TaskStore.isDetachedChild(family.secondChild))

        TaskStore.openInSplit(family.secondChild, side: .right, in: family.task)
        #expect(TaskStore.isDetachedChild(family.secondChild))

        let elsewhere = TaskStore.createTask(in: context, siblings: [family.task])
        TaskStore.moveTab(family.child, to: elsewhere)
        #expect(TaskStore.isDetachedChild(family.child))
        #expect(!TaskStore.isDetachedChild(family.grandchild))

        TaskStore.closeTab(family.parent, in: context)
        #expect(!TaskStore.isDetachedChild(family.child))
    }

    @Test func aDetachedChildsSidebarHeaderSaysSo() {
        let header = TaskRowDetails.AgentHeader(tabID: UUID(), title: "fix", status: .working, isDetachedChild: true)
        #expect(header.controlValue(isFocused: true, isHovered: false) == "\(header.statusText); detached child; focused")
    }

    // MARK: - Move Next to Parent

    @Test func moveNextToParentIsOfferedOnlyToADetachedChildWithAnOpenParent() throws {
        let family = try makeFamily()
        #expect(!TaskStore.canMoveNextToParent(family.child))
        #expect(!TaskStore.canMoveNextToParent(family.other))

        TaskStore.moveTab(family.secondChild, toPane: 0, at: 5, in: family.task)
        #expect(TaskStore.canMoveNextToParent(family.secondChild))

        TaskStore.closeTab(family.parent, in: context)
        #expect(!TaskStore.canMoveNextToParent(family.secondChild))
    }

    @Test func moveNextToParentWithinAStripReattachesAtTheRunsEnd() throws {
        let family = try makeFamily()
        TaskStore.moveTab(family.child, toPane: 0, at: 5, in: family.task)
        TaskStore.selectTab(family.other, in: family.task)
        #expect(family.task.tabs(inPane: 0).map(\.id)
            == [family.parent, family.secondChild, family.other, family.child, family.grandchild].map(\.id))

        TaskStore.moveNextToParent(family.child)

        #expect(family.task.tabs(inPane: 0).map(\.id)
            == [family.parent, family.secondChild, family.child, family.grandchild, family.other].map(\.id))
        #expect(TaskStore.isAttachedToParent(family.child))
        #expect(TaskStore.isAttachedToParent(family.grandchild))
        #expect(family.task.selectedTabID == family.other.id)
    }

    @Test func moveNextToParentFromTheOtherPane() throws {
        let family = try makeFamily()
        TaskStore.moveTab(family.secondChild, toPane: 0, at: 5, in: family.task)
        TaskStore.openInSplit(family.secondChild, side: .right, in: family.task)
        let stays = TaskStore.addTab(to: family.task, kind: .terminal, pane: 1, in: context)

        TaskStore.moveNextToParent(family.secondChild)

        #expect(family.task.panes.map { $0.map(\.id) } == [
            [family.parent, family.child, family.grandchild, family.secondChild, family.other].map(\.id),
            [stays.id]
        ])
        #expect(TaskStore.isAttachedToParent(family.secondChild))
    }

    @Test func moveNextToParentFromAnotherTaskJoinsTheParentsPane() throws {
        let family = try makeFamily()
        TaskStore.openInSplit(family.parent, side: .right, in: family.task)
        let elsewhere = TaskStore.createTask(in: context, siblings: [family.task])
        TaskStore.moveTab(family.child, to: elsewhere)
        #expect(!TaskStore.isAttachedToParent(family.child))

        TaskStore.moveNextToParent(family.child)

        #expect(family.child.task?.id == family.task.id)
        #expect(family.task.panes.map { $0.map(\.id) } == [
            [family.other.id],
            [family.parent, family.secondChild, family.child, family.grandchild].map(\.id)
        ])
        #expect(family.task.panes[1].map(\.orderIndex) == [0, 1, 2, 3])
        #expect(TaskStore.isAttachedToParent(family.child))
        #expect(elsewhere.tabs.count == 1)
    }
}
