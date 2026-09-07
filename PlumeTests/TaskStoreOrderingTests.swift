import Testing
import Foundation
import SwiftData
@testable import Plume

/// `TaskStore.moveTabs` rewrites `orderIndex` densely on every move — the
/// logic `TabStripView`'s drag-to-reorder drives. Mirrors `PersistenceTests`'
/// in-memory-container setup.
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

        TaskStore.moveTabs(tabs, from: IndexSet(integer: 0), to: 3)

        let expected: [TaskTab] = [tabs[1], tabs[2], tabs[0], tabs[3], tabs[4]]
        #expect(task.orderedTabs.map(\.id) == expected.map(\.id))
    }

    @Test func movingATabBackwardReordersTheOnesBetween() throws {
        let context = ModelContext(try container())
        let (task, tabs) = makeTabs(4, in: context)

        TaskStore.moveTabs(tabs, from: IndexSet(integer: 3), to: 1)

        let expected: [TaskTab] = [tabs[0], tabs[3], tabs[1], tabs[2], tabs[4]]
        #expect(task.orderedTabs.map(\.id) == expected.map(\.id))
    }

    @Test func orderIndexStaysDenseAndZeroBasedAfterAMove() throws {
        let context = ModelContext(try container())
        let (task, tabs) = makeTabs(3, in: context)

        TaskStore.moveTabs(tabs, from: IndexSet(integer: 0), to: 2)

        let indices = task.orderedTabs.map(\.orderIndex)
        #expect(indices == Array(0..<indices.count))
    }

    @Test func movingATabToItsOwnPositionIsANoOp() throws {
        let context = ModelContext(try container())
        let (task, tabs) = makeTabs(2, in: context)
        let before = task.orderedTabs.map(\.id)

        TaskStore.moveTabs(tabs, from: IndexSet(integer: 1), to: 1)

        #expect(task.orderedTabs.map(\.id) == before)
    }

    @Test func movingToTheEndAppendsAfterEveryOtherTab() throws {
        let context = ModelContext(try container())
        let (task, tabs) = makeTabs(3, in: context)

        // Mirrors dropping past the last chip: destination is the count of
        // the ordered array, one past its last valid index.
        TaskStore.moveTabs(tabs, from: IndexSet(integer: 0), to: tabs.count)

        #expect(task.orderedTabs.last?.id == tabs[0].id)
    }
}
