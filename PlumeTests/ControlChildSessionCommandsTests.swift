import Foundation
import SwiftData
import Testing

@testable import Plume

/// `child-session.start` and `child-session.report` decode from the wire,
/// name tabs by ID or title, and refuse what the coordinator would refuse.
@MainActor
struct ControlChildSessionCommandsTests {
    private let context: ModelContext

    init() throws {
        context = ModelContext(try ModelContainer(
            for: Schema([TaskGroup.self, WorkTask.self, TaskTab.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        ))
    }

    private func decode(_ json: String) throws -> ControlCommand {
        try JSONDecoder().decode(ControlServerRequest.self, from: Data(json.utf8)).command
    }

    @Test func theWireNamesBothCommands() throws {
        guard case .startChildSession(let start) = try decode(
            #"{"id":"1","command":"child-session.start","parent":"Lead","title":"Fix","prompt":"Go","use_worktree":false,"context":"fork"}"#
        ) else {
            Issue.record("expected child-session.start")
            return
        }
        #expect(start == ChildSessionStartParams(parent: "Lead", title: "Fix", prompt: "Go", useWorktree: false, context: "fork"))

        guard case .reportChildSession(let report) = try decode(
            #"{"id":"2","command":"child-session.report","child":"Fix","text":"Done","wakes":false}"#
        ) else {
            Issue.record("expected child-session.report")
            return
        }
        #expect(report == ChildSessionReportParams(child: "Fix", text: "Done", wakes: false))
    }

    @Test func startRefusesArgumentsStartSessionWouldRefuse() async throws {
        let task = TaskStore.createTask(in: context, title: "Task", siblings: [])
        let parent = try #require(task.tabs.first)
        parent.title = "Lead"
        try context.save()

        await #expect(throws: ControlError.self) {
            try await ControlChildSessionCommands.start(.init(parent: "Lead", title: "Fix"), in: context)
        }
        #expect(task.tabs.count == 1)
    }

    @Test func reportNeedsAnOpenParent() throws {
        let task = TaskStore.createTask(in: context, title: "Task", siblings: [])
        let orphan = try #require(task.tabs.first)
        try context.save()

        #expect(throws: ControlError.self) {
            try ControlChildSessionCommands.report(.init(child: orphan.id.uuidString, text: "Done"), in: context)
        }
    }
}
