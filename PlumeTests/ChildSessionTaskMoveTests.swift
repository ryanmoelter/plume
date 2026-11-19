import Foundation
import SwiftData
import Testing
@testable import Plume

/// Moving a tab to another task takes its whole group of child sessions,
/// in order and still linked, and refuses a child whose parent stays behind.
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

    private func makeFamily() throws -> Family {
        let task = TaskStore.createTask(in: context, siblings: [])
        let parent = try #require(task.tabs.first)
        let child = TaskStore.addChildTab(to: task, parent: parent, in: context)
        let secondChild = TaskStore.addChildTab(to: task, parent: parent, in: context)
        let grandchild = TaskStore.addChildTab(to: task, parent: child, in: context)
        let other = TaskStore.addTab(to: task, kind: .terminal, in: context)
        return Family(task: task, parent: parent, child: child, grandchild: grandchild, secondChild: secondChild, other: other)
    }

    @Test func movingAParentTakesItsDescendantsInOrder() throws {
        let family = try makeFamily()
        let destination = TaskStore.createTask(in: context, siblings: [family.task])
        let existing = try #require(destination.tabs.first)

        #expect(TaskStore.moveTab(family.parent, to: destination))

        let moved = [family.parent, family.child, family.grandchild, family.secondChild]
        #expect(destination.tabs(inPane: 0).map(\.id) == [existing.id] + moved.map(\.id))
        #expect(destination.tabs(inPane: 0).map(\.orderIndex) == [0, 1, 2, 3, 4])
        #expect(family.child.parentTabID == family.parent.id)
        #expect(family.grandchild.parentTabID == family.child.id)
        #expect(family.secondChild.parentTabID == family.parent.id)
        #expect(family.task.tabs(inPane: 0).map(\.id) == [family.other.id])
        #expect(family.task.tabs(inPane: 0).map(\.orderIndex) == [0])
        #expect(destination.selectedTabID == family.parent.id)
    }

    @Test func movingAMiddleChildWithoutItsParentIsRefused() throws {
        let family = try makeFamily()
        let destination = TaskStore.createTask(in: context, siblings: [family.task])

        #expect(!TaskStore.canLeaveTask(family.child))
        #expect(!TaskStore.moveTab(family.child, to: destination))
        #expect(!TaskStore.canMoveToNewTask(family.grandchild))
        #expect(TaskStore.splitTabIntoNewTask(family.grandchild, in: context, siblings: [family.task, destination]) == nil)
        #expect(family.task.tabs(inPane: 0).map(\.id)
            == [family.parent, family.child, family.grandchild, family.secondChild, family.other].map(\.id))
        #expect(destination.tabs.count == 1)
    }

    @Test func aChildWhoseParentIsGoneMovesAlone() throws {
        let family = try makeFamily()
        let destination = TaskStore.createTask(in: context, siblings: [family.task])
        family.secondChild.parentTabID = UUID()

        #expect(TaskStore.moveTab(family.secondChild, to: destination))
        #expect(family.secondChild.task?.id == destination.id)
    }

    @Test func aGroupThatIsTheWholeTaskCannotMoveToANewTask() throws {
        let family = try makeFamily()
        #expect(TaskStore.canMoveToNewTask(family.parent))

        TaskStore.closeTab(family.other, in: context)

        #expect(!TaskStore.canMoveToNewTask(family.parent))
    }

    @Test func movingToANewTaskTakesTheGroup() throws {
        let family = try makeFamily()

        let newTask = try #require(TaskStore.splitTabIntoNewTask(family.parent, in: context, siblings: [family.task]))

        #expect(newTask.tabs(inPane: 0).map(\.id)
            == [family.parent, family.child, family.grandchild, family.secondChild].map(\.id))
        #expect(family.task.tabs(inPane: 0).map(\.id) == [family.other.id])
    }

    @Test func theSubtreeReachesADescendantInAnotherPane() throws {
        let family = try makeFamily()
        family.grandchild.paneIndex = 1

        let subtree = TaskStore.taskSubtree(of: family.parent, in: family.task)

        #expect(subtree.map(\.id) == [family.parent, family.child, family.grandchild, family.secondChild].map(\.id))
    }
}
