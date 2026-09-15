import Testing
import Foundation
import SwiftData
@testable import Plume

/// Archiving a task tears its tabs down the way deleting one does, and
/// unarchiving brings them back dormant rather than still claiming to work.
@MainActor
struct ArchiveTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(
            for: Schema([TaskGroup.self, WorkTask.self, TaskTab.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        ))
    }

    /// The shared stores outlive any one test, and Swift Testing runs suites
    /// in parallel in one process.
    private func isolated(_ body: () throws -> Void) rethrows {
        StatusEngine.shared.reset()
        DraftStore.shared.reset()
        defer {
            StatusEngine.shared.reset()
            DraftStore.shared.reset()
        }
        try body()
    }

    @Test func archivingMarksTheTask() throws {
        try isolated {
            let context = try context()
            let task = TaskStore.createTask(in: context, siblings: [])

            TaskStore.archive(task)

            #expect(task.isArchived)
            #expect(task.archivedAt != nil)
        }
    }

    @Test func archivingForgetsEveryTabsStores() throws {
        try isolated {
            let context = try context()
            let task = TaskStore.createTask(in: context, siblings: [])
            let second = TaskStore.addTab(to: task, kind: .agent, in: context)
            let first = try #require(task.tabs.first { $0.id != second.id })
            DraftStore.shared.setDraft("half-typed", forTab: first.id)
            DraftStore.shared.setDraft("also half-typed", forTab: second.id)

            TaskStore.archive(task)

            #expect(DraftStore.shared.draft(forTab: first.id).isEmpty)
            #expect(DraftStore.shared.draft(forTab: second.id).isEmpty)
        }
    }

    @Test func archivingClearsLiveStatus() throws {
        try isolated {
            let context = try context()
            let task = TaskStore.createTask(in: context, siblings: [])
            let tab = try #require(task.tabs.first)
            StatusEngine.shared.setStatus(.working, taskID: task.id, tabID: tab.id)

            TaskStore.archive(task)

            #expect(StatusEngine.shared.ownStatus(forTab: tab.id) == .notStarted)
            #expect(StatusEngine.shared.status(forTask: task.id) == .notStarted)
        }
    }

    /// The archived task's agent is dead, so a sidebar row that still reads
    /// `working` invites the user back to nothing.
    @Test func unarchivingDoesNotRestoreTheStatusItWasArchivedWith() throws {
        try isolated {
            let context = try context()
            let task = TaskStore.createTask(in: context, siblings: [])
            let tab = try #require(task.tabs.first)
            StatusEngine.shared.setStatus(.working, taskID: task.id, tabID: tab.id)

            TaskStore.archive(task)
            TaskStore.unarchive(task)

            #expect(!task.isArchived)
            #expect(task.archivedAt == nil)
            #expect(StatusEngine.shared.status(forTask: task.id) == .notStarted)
            #expect(StatusEngine.shared.isDormant(tabID: tab.id))
        }
    }

    /// Re-registering is what lets the task aggregate again; an unarchived
    /// task whose tabs the engine has never heard of can never leave
    /// `notStarted`.
    @Test func unarchivedTabsReportStatusAgain() throws {
        try isolated {
            let context = try context()
            let task = TaskStore.createTask(in: context, siblings: [])
            let tab = try #require(task.tabs.first)

            TaskStore.archive(task)
            TaskStore.unarchive(task)
            StatusEngine.shared.setStatus(.working, taskID: task.id, tabID: tab.id)

            #expect(StatusEngine.shared.status(forTask: task.id) == .working)
            #expect(!StatusEngine.shared.isDormant(tabID: tab.id))
        }
    }

    /// `agentSessionID` is what `--resume` reads, and the transcript it names
    /// outlives the process, so teardown must not drop it.
    @Test func archivingKeepsWhatARelaunchNeeds() throws {
        try isolated {
            let context = try context()
            let task = TaskStore.createTask(in: context, siblings: [])
            let tab = try #require(task.tabs.first)
            tab.agentSessionID = "session-abc"
            tab.sessionJSONLPath = "/tmp/session-abc.jsonl"

            TaskStore.archive(task)
            TaskStore.unarchive(task)

            #expect(tab.agentSessionID == "session-abc")
            #expect(tab.sessionJSONLPath == "/tmp/session-abc.jsonl")
            #expect(task.tabs.count == 1)
        }
    }

    @Test func archivingKeepsTheTaskAndItsTabs() throws {
        try isolated {
            let context = try context()
            let task = TaskStore.createTask(in: context, siblings: [])
            TaskStore.addTab(to: task, kind: .terminal, in: context)

            TaskStore.archive(task)

            #expect(try context.fetch(FetchDescriptor<WorkTask>()).count == 1)
            #expect(try context.fetch(FetchDescriptor<TaskTab>()).count == 2)
        }
    }
}
