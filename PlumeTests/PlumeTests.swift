import Testing
import Foundation
import SwiftData
@testable import Plume

@MainActor
struct TaskStoreTests {
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Schema([TaskGroup.self, WorkTask.self, TaskTab.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        return ModelContext(container)
    }

    @Test func newTaskStartsWithOneSelectedAgentTab() throws {
        let context = try makeContext()
        let task = TaskStore.createTask(in: context, siblings: [])

        #expect(task.tabs.count == 1)
        #expect(task.tabs.first?.kind == .agent)
        #expect(task.selectedTabID == task.tabs.first?.id)
        #expect(task.workspaceKind == .unset)
    }

    @Test func createdTasksGetIncreasingOrderIndexes() throws {
        let context = try makeContext()
        var tasks: [WorkTask] = []
        for _ in 0..<3 {
            tasks.append(TaskStore.createTask(in: context, siblings: tasks))
        }
        #expect(tasks.map(\.orderIndex) == [0, 1, 2])
    }

    @Test func movingTaskRewritesDenseOrder() throws {
        let context = try makeContext()
        var tasks: [WorkTask] = []
        for index in 0..<3 {
            tasks.append(TaskStore.createTask(in: context, title: "T\(index)", siblings: tasks))
        }

        TaskStore.move(tasks, from: IndexSet(integer: 2), to: 0)

        let ordered = tasks.sorted { $0.orderIndex < $1.orderIndex }
        #expect(ordered.map(\.title) == ["T2", "T0", "T1"])
        #expect(ordered.map(\.orderIndex) == [0, 1, 2])
    }

    @Test func deletingGroupKeepsTasksAsUngrouped() throws {
        let context = try makeContext()
        let group = TaskStore.createGroup(in: context, existing: [])
        let task = TaskStore.createTask(in: context, group: group, siblings: [])

        TaskStore.deleteGroup(group, in: context)

        #expect(task.group == nil)
        #expect(!task.isDeleted)
    }

    @Test func closingSelectedTabSelectsAnother() throws {
        let context = try makeContext()
        let task = TaskStore.createTask(in: context, siblings: [])
        let first = try #require(task.tabs.first)
        let second = TaskStore.addTab(to: task, kind: .terminal, in: context)
        #expect(task.selectedTabID == second.id)

        TaskStore.closeTab(second, in: context)

        #expect(task.selectedTabID == first.id)
    }
}

struct TaskStatusTests {
    @Test func needsInputOutranksWorking() {
        #expect(TaskStatus.aggregate([.idle, .working, .needsInput, .done]) == .needsInput)
    }

    @Test func workingOutranksErrorAndDone() {
        #expect(TaskStatus.aggregate([.done, .error, .working]) == .working)
    }

    @Test func emptyAggregatesToUnset() {
        #expect(TaskStatus.aggregate([]) == .unset)
    }
}
