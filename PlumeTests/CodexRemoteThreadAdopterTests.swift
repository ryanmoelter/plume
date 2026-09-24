import Foundation
import SwiftData
import Testing
@testable import Plume

@MainActor
struct CodexRemoteThreadAdopterTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: TaskGroup.self, WorkTask.self, TaskTab.self,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
    }

    @Test func matchesArchivedExactIdentityWithoutDirectoryGuessing() throws {
        let context = try context()
        let task = WorkTask(title: "Existing", orderIndex: 0)
        context.insert(task)
        task.isArchived = true
        task.workingDirectoryPath = "/old"
        let tab = TaskStore.addTab(to: task, kind: .agent, provider: .codex, in: context)
        tab.transport = .headless
        tab.agentSessionID = "existing"
        let matched = try CodexRemoteThreadAdopter.resolve(thread: .object([
            "id": .string("existing"), "cwd": .string("/new")
        ]), in: context)
        #expect(matched?.id == tab.id)
        #expect(!task.isArchived)
        #expect(task.workingDirectoryPath == "/old")
        let fresh = try CodexRemoteThreadAdopter.resolve(thread: .object([
            "id": .string("new"), "cwd": .string("/old")
        ]), in: context)
        #expect(fresh?.task?.id != task.id)
        #expect(fresh?.provider == .codex)
        #expect(fresh?.transport == .headless)
        #expect(fresh?.agentSessionID == "new")
    }

    @Test func excludesHelpersAndDoesNotReplaceTerminalIdentity() throws {
        let context = try context()
        let ignored = try CodexRemoteThreadAdopter.resolve(thread: .object([
            "id": .string("helper"), "ephemeral": .bool(true)
        ]), in: context)
        #expect(ignored == nil)
        let task = WorkTask(title: "Terminal", orderIndex: 0)
        context.insert(task)
        let tab = TaskStore.addTab(to: task, kind: .agent, provider: .codex, in: context)
        tab.transport = .terminal
        tab.agentSessionID = "terminal"
        let result = try CodexRemoteThreadAdopter.resolve(thread: .object(["id": .string("terminal")]), in: context)
        #expect(result == nil)
        #expect(tab.transport == .terminal)
        let tasks = try context.fetch(FetchDescriptor<WorkTask>())
        #expect(tasks.count == 1)
    }
}
