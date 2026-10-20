import Testing
import Foundation
import SwiftData
@testable import Plume

/// Round-trips the task tree through an on-disk store, closing and reopening
/// the container so restore-after-relaunch is exercised rather than assumed.
@MainActor
struct PersistenceTests {
    private func storeURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "plume-test-\(UUID().uuidString).store")
    }

    private func container(at url: URL) throws -> ModelContainer {
        try ModelContainer(
            for: Schema([TaskGroup.self, WorkTask.self, TaskTab.self]),
            configurations: [ModelConfiguration(url: url)]
        )
    }

    @Test func taskTreeSurvivesReopeningTheStore() throws {
        let url = storeURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let taskID: UUID
        let tabID: UUID
        do {
            let context = ModelContext(try container(at: url))
            let group = TaskStore.createGroup(in: context, name: "Backlog", existing: [])
            let task = TaskStore.createTask(in: context, title: "Ship it", group: group, siblings: [])
            TaskStore.addTab(to: task, kind: .terminal, in: context)
            task.workspaceKind = .worktree
            task.branchName = "plume/ship-it-a1b2"
            taskID = task.id
            tabID = try #require(task.selectedTabID)
            try context.save()
        }

        let context = ModelContext(try container(at: url))
        let tasks = try context.fetch(FetchDescriptor<WorkTask>())
        let restored = try #require(tasks.first { $0.id == taskID })

        #expect(restored.title == "Ship it")
        #expect(restored.group?.name == "Backlog")
        #expect(restored.tabs.count == 2)
        #expect(restored.selectedTabID == tabID)
        #expect(restored.workspaceKind == .worktree)
        #expect(restored.branchName == "plume/ship-it-a1b2")
    }

    @Test func appearanceFieldsDefaultEmpty() throws {
        let context = ModelContext(try ModelContainer(
            for: Schema([TaskGroup.self, WorkTask.self, TaskTab.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        ))
        let group = TaskStore.createGroup(in: context, existing: [])
        let task = TaskStore.createTask(in: context, group: group, siblings: [])

        #expect(group.tintRaw == nil)
        #expect(group.iconName == nil)
        #expect(task.tintRaw == nil)
        #expect(task.taskDescription == "")
        #expect(task.iconName == nil)
    }

    @Test func appearanceFieldsSurviveReopeningTheStore() throws {
        let url = storeURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let taskID: UUID
        do {
            let context = ModelContext(try container(at: url))
            let group = TaskStore.createGroup(in: context, existing: [])
            group.tint = .palette(slot: 3)
            group.iconName = "leaf"
            let task = TaskStore.createTask(in: context, group: group, siblings: [])
            task.tint = .text
            task.iconName = "bolt"
            task.taskDescription = "Fix the flaky test"
            taskID = task.id
            try context.save()
        }

        let context = ModelContext(try container(at: url))
        let restored = try #require(try context.fetch(FetchDescriptor<WorkTask>()).first { $0.id == taskID })

        #expect(restored.tint == .text)
        #expect(restored.iconName == "bolt")
        #expect(restored.taskDescription == "Fix the flaky test")
        #expect(restored.group?.tint == .palette(slot: 3))
        #expect(restored.group?.iconName == "leaf")
    }

    @Test func deletingTaskCascadesToItsTabs() throws {
        let url = storeURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let context = ModelContext(try container(at: url))
        let task = TaskStore.createTask(in: context, siblings: [])
        TaskStore.addTab(to: task, kind: .terminal, in: context)
        try context.save()

        TaskStore.delete(task, in: context)
        try context.save()

        let remainingTabs = try context.fetch(FetchDescriptor<TaskTab>())
        #expect(remainingTabs.isEmpty)
    }
}
