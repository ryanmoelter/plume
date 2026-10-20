import Testing
import Foundation
import SwiftData
@testable import Plume

/// `TaskStore.moveTab(_:toPane:at:in:)` within one strip rewrites
/// `orderIndex` densely, as `TabStripView`'s drag-to-reorder drives it. The
/// gap counts positions before the move, like `Array.move(toOffset:)`.
@MainActor
struct TaskStoreOrderingTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(
            for: Schema([TaskGroup.self, WorkTask.self, TaskTab.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
    }

    /// A task with `extra` terminal tabs added beyond the agent tab
    /// `createTask` seeds, in creation order.
    private func makeTabs(_ extra: Int, in context: ModelContext) -> (WorkTask, [TaskTab]) {
        let task = TaskStore.createTask(in: context, siblings: [])
        for _ in 0..<extra {
            TaskStore.addTab(to: task, kind: .terminal, in: context)
        }
        return (task, task.orderedTabs)
    }

    @Test func movingATabForwardReordersTheOnesBetween() throws {
        let context = ModelContext(try container())
        let (task, tabs) = makeTabs(4, in: context)

        TaskStore.moveTab(tabs[0], toPane: 0, at: 3, in: task)

        let expected: [TaskTab] = [tabs[1], tabs[2], tabs[0], tabs[3], tabs[4]]
        #expect(task.orderedTabs.map(\.id) == expected.map(\.id))
    }

    @Test func movingATabBackwardReordersTheOnesBetween() throws {
        let context = ModelContext(try container())
        let (task, tabs) = makeTabs(4, in: context)

        TaskStore.moveTab(tabs[3], toPane: 0, at: 1, in: task)

        let expected: [TaskTab] = [tabs[0], tabs[3], tabs[1], tabs[2], tabs[4]]
        #expect(task.orderedTabs.map(\.id) == expected.map(\.id))
    }

    @Test func orderIndexStaysDenseAndZeroBasedAfterAMove() throws {
        let context = ModelContext(try container())
        let (task, tabs) = makeTabs(3, in: context)

        TaskStore.moveTab(tabs[0], toPane: 0, at: 2, in: task)

        let indices = task.orderedTabs.map(\.orderIndex)
        #expect(indices == Array(0..<indices.count))
    }

    @Test func movingATabToItsOwnPositionIsANoOp() throws {
        let context = ModelContext(try container())
        let (task, tabs) = makeTabs(2, in: context)
        let before = task.orderedTabs.map(\.id)

        TaskStore.moveTab(tabs[1], toPane: 0, at: 1, in: task)

        #expect(task.orderedTabs.map(\.id) == before)
    }

    @Test func movingToTheEndAppendsAfterEveryOtherTab() throws {
        let context = ModelContext(try container())
        let (task, tabs) = makeTabs(3, in: context)

        TaskStore.moveTab(tabs[0], toPane: 0, at: tabs.count, in: task)

        #expect(task.orderedTabs.last?.id == tabs[0].id)
    }

    @Test func movingAGroupForwardReordersTheOnesBetween() throws {
        let context = ModelContext(try container())
        let groups = (0..<4).map { TaskStore.createGroup(in: context, name: "Group \($0)", existing: []) }
        for (index, group) in groups.enumerated() { group.orderIndex = index }

        TaskStore.moveGroups(groups, from: IndexSet(integer: 0), to: 3)

        let expected = [groups[1], groups[2], groups[0], groups[3]]
        #expect(groups.sorted { $0.orderIndex < $1.orderIndex }.map(\.id) == expected.map(\.id))
    }
}
