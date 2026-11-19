#if DEBUG
import Foundation
import SwiftData
import Testing
@testable import Plume

@MainActor
struct SidebarFixturesTests {
    private let context: ModelContext

    init() throws {
        let container = try ModelContainer(
            for: Schema([TaskGroup.self, WorkTask.self, TaskTab.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        context = ModelContext(container)
    }

    private func groups() throws -> [TaskGroup] {
        try context.fetch(FetchDescriptor<TaskGroup>(sortBy: [SortDescriptor(\.orderIndex)]))
    }

    @Test func removeDeletesTheFixtureGroupAndItsTasksOnly() throws {
        let other = TaskStore.createGroup(in: context, name: "Real work", existing: [])
        _ = TaskStore.createTask(in: context, title: "Keep me", group: other, siblings: [])
        _ = TaskStore.createTask(in: context, title: "Ungrouped", group: nil, siblings: [])
        try context.save()

        SidebarFixtures.seed(in: context, existingGroups: try groups())
        try context.save()
        #expect(SidebarFixtures.hasFixtures(in: try groups()))
        #expect(try context.fetchCount(FetchDescriptor<WorkTask>()) > 2)

        SidebarFixtures.remove(in: context, existingGroups: try groups())
        try context.save()

        let remaining = try groups()
        #expect(remaining.map(\.name) == ["Real work"])
        #expect(!SidebarFixtures.hasFixtures(in: remaining))
        let titles = try context.fetch(FetchDescriptor<WorkTask>()).map(\.title).sorted()
        #expect(titles == ["Keep me", "Ungrouped"])
    }
}
#endif
