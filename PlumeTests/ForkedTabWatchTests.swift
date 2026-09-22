import Foundation
import SwiftData
import Testing
@testable import Plume

/// A forked tab records its session id before the process exists, which is
/// what makes the fork addressable — but `ChatTabView.persistHeadlessSessionID`
/// derives the transcript path only for an id it has not already seen. A tab
/// carrying an id with no path watches nothing: its transcript is never read,
/// so the chat list never mounts and the composer stays disabled forever, with
/// the forked `claude` process alive the whole time.
@MainActor
struct ForkedTabWatchTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(
            for: Schema([TaskGroup.self, WorkTask.self, TaskTab.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        ))
    }

    @Test func aTabThatKnowsItsSessionCanDeriveAPathToWatch() throws {
        let context = try context()
        let task = WorkTask(title: "forked", orderIndex: 0)
        task.workingDirectoryPath = "/tmp/plume-fork-test"
        context.insert(task)
        let tab = TaskStore.addTab(to: task, kind: .agent, in: context)

        let sessionID = UUID().uuidString.lowercased()
        tab.agentSessionID = sessionID
        tab.sessionJSONLPath = SessionJSONLReader.resolvedTranscriptPath(
            workingDirectory: try #require(task.workingDirectoryPath),
            sessionID: sessionID
        )

        let path = try #require(tab.sessionJSONLPath)
        #expect(!path.isEmpty)
        // The session's own file, not some other conversation's.
        #expect(path.hasSuffix("\(sessionID).jsonl"))
    }

    /// The shape the bug had: an id with no path. `registerWatchIfNeeded`
    /// returns without starting either watch, and nothing later supplies one,
    /// because the id is already the one the CLI reports back.
    @Test func aSessionIDWithoutAPathStartsNoWatch() throws {
        let context = try context()
        let task = WorkTask(title: "forked", orderIndex: 0)
        context.insert(task)
        let tab = TaskStore.addTab(to: task, kind: .agent, in: context)
        tab.agentSessionID = UUID().uuidString.lowercased()

        #expect(tab.sessionJSONLPath == nil)
    }
}
