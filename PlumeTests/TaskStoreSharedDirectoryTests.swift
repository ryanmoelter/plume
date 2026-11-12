import Testing
import Foundation
import SwiftData
@testable import Plume

/// Deleting one task must leave the git state of a directory other tasks still use.
@MainActor
struct TaskStoreSharedDirectoryTests {
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Schema([TaskGroup.self, WorkTask.self, TaskTab.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        return ModelContext(container)
    }

    private let directory = "/tmp/plume-shared-directory-test"
    private let state = GitState(branch: "feature", upstream: nil, ahead: 0, behind: 0, isDirty: false)

    @Test func deletingOneTaskKeepsGitStateForTheOthers() throws {
        let context = try makeContext()
        let store = GitStateStore.shared
        defer { store.reset() }
        let first = TaskStore.createTask(in: context, siblings: [])
        let second = TaskStore.createTask(in: context, siblings: [])
        first.workingDirectoryPath = directory
        second.workingDirectoryPath = directory
        store.seedFixture(directory: directory, state: state)
        store.watch(directory)

        TaskStore.delete(first, in: context)

        #expect(store.state(for: directory)?.branch == "feature")
    }

    @Test func deletingTheLastTaskForgetsGitState() throws {
        let context = try makeContext()
        let store = GitStateStore.shared
        defer { store.reset() }
        let only = TaskStore.createTask(in: context, siblings: [])
        only.workingDirectoryPath = directory
        store.seedFixture(directory: directory, state: state)
        store.watch(directory)

        TaskStore.delete(only, in: context)

        #expect(store.state(for: directory) == nil)
    }
}
