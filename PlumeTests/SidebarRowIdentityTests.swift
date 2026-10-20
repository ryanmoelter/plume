import Testing
import Foundation
import SwiftData
@testable import Plume

/// A task's sidebar row id changes whenever the task changes section, so the
/// sidebar's `LazyVStack` builds a fresh row in the new section instead of
/// carrying over the old one.
@MainActor
struct SidebarRowIdentityTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(
            for: Schema([TaskGroup.self, WorkTask.self, TaskTab.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
    }

    @Test func rowIDChangesWithEachMove() throws {
        let context = ModelContext(try container())
        let first = TaskStore.createGroup(in: context, name: "First", existing: [])
        let second = TaskStore.createGroup(in: context, name: "Second", existing: [first])
        let task = TaskStore.createTask(in: context, group: first, siblings: [])
        let inFirst = task.sidebarRowID

        TaskStore.move(task, to: second, siblings: [])
        let inSecond = task.sidebarRowID
        TaskStore.move(task, to: nil, siblings: [])
        let ungrouped = task.sidebarRowID

        #expect(Set([inFirst, inSecond, ungrouped]).count == 3)
        #expect([inFirst, inSecond, ungrouped].allSatisfy { $0.taskID == task.id })
    }

    @Test func rowIDIsStableWithinASection() throws {
        let context = ModelContext(try container())
        let group = TaskStore.createGroup(in: context, name: "Group", existing: [])
        let task = TaskStore.createTask(in: context, group: group, siblings: [])
        let before = task.sidebarRowID

        task.title = "Renamed"
        task.orderIndex += 1

        #expect(task.sidebarRowID == before)
    }
}
