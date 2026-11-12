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

    /// The parent has no conversation to resume, so the wake cannot reach it.
    @Test func aWakeThatCannotReachTheParentLeavesTheNoteForTheUser() throws {
        let task = TaskStore.createTask(in: context, title: "Task", siblings: [])
        let parent = try #require(task.tabs.first)
        let child = TaskStore.addChildTab(to: task, parent: parent, in: context)
        try context.save()
        let session = HeadlessSession(tabID: parent.id, taskID: task.id)
        ChildSessionCoordinator.shared.attach(to: session, task: task, tab: parent)
        defer { ChildSessionCoordinator.shared.tabForgotten(parent.id) }

        _ = try ControlChildSessionCommands.report(.init(child: child.id.uuidString, text: "All green"), in: context)

        let preamble = try #require(session.userMessagePreamble?())
        #expect(preamble.contains("All green"))
        #expect(preamble.contains("<side-sessions-event>"))
    }

    @Test func aChildsMessageToAParentThatCannotWakeSaysItWaitsForTheUser() async throws {
        let task = TaskStore.createTask(in: context, title: "Task", siblings: [])
        let parent = try #require(task.tabs.first)
        let child = TaskStore.addChildTab(to: task, parent: parent, in: context)
        try context.save()
        let parentSession = HeadlessSession(tabID: parent.id, taskID: task.id)
        let childSession = HeadlessSession(tabID: child.id, taskID: task.id)
        ChildSessionCoordinator.shared.attach(to: parentSession, task: task, tab: parent)
        ChildSessionCoordinator.shared.attach(to: childSession, task: task, tab: child)
        defer { ChildSessionCoordinator.shared.tabForgotten(parent.id) }
        let server = try #require(childSession.mcpServer)

        let reply = await server.handle(.object([
            "jsonrpc": .string("2.0"), "id": .number(1), "method": .string("tools/call"),
            "params": .object(["name": .string("send_message"), "arguments": .object([
                "to": .string("parent"), "message": .string("Need a decision")
            ])])
        ]))

        let text = reply?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
        #expect(text.hasPrefix("Delivered with the user's next message"))
        #expect(parentSession.userMessagePreamble?()?.contains("Need a decision") == true)
    }

    private final class Lines {
        var all: [String] = []
    }

    private static let result = #"{"type":"result","subtype":"success","is_error":false,"result":"DONE"}"#

    @Test func aMessageQueuedBehindAnInterruptLetsAChildWakeTheParentAgain() throws {
        let task = TaskStore.createTask(in: context, title: "Task", siblings: [])
        let parent = try #require(task.tabs.first)
        let child = TaskStore.addChildTab(to: task, parent: parent, in: context)
        try context.save()
        let session = try #require(AgentSessionManager.shared.session(for: parent.id, taskID: task.id) as? HeadlessSession)
        defer {
            _ = AgentSessionManager.shared.detachSession(for: parent.id)
            ChildSessionCoordinator.shared.tabForgotten(parent.id)
        }
        session.queuedMessageDelivery = { .endOfTurn }
        let lines = Lines()
        session.debugLineSink = { lines.all.append($0) }
        ChildSessionCoordinator.shared.attach(to: session, task: task, tab: parent)
        _ = try ControlChildSessionCommands.report(.init(child: child.id.uuidString, text: "Earlier", wakes: false), in: context)

        session.submit(text: "first")
        session.submit(text: "second")
        session.interrupt()
        session.handle(try #require(StreamJSONDecoder.decode(line: Self.result)))
        session.handle(try #require(StreamJSONDecoder.decode(line: Self.result)))
        _ = try ControlChildSessionCommands.report(.init(child: child.id.uuidString, text: "All green"), in: context)

        #expect(lines.all.last?.contains("All green") == true)
        #expect(session.isWorking)
    }

    @Test func hostMessagesTheUserRemovesGoBackToTheParentAsHeldNotes() throws {
        let task = TaskStore.createTask(in: context, title: "Task", siblings: [])
        let parent = try #require(task.tabs.first)
        let child = TaskStore.addChildTab(to: task, parent: parent, in: context)
        try context.save()
        let parentSession = HeadlessSession(tabID: parent.id, taskID: task.id)
        let childSession = HeadlessSession(tabID: child.id, taskID: task.id)
        ChildSessionCoordinator.shared.attach(to: parentSession, task: task, tab: parent)
        ChildSessionCoordinator.shared.attach(to: childSession, task: task, tab: child)
        defer { ChildSessionCoordinator.shared.tabForgotten(parent.id) }
        let wake = ChildSessionWakePolicy.Note(childID: child.id, text: "WAKE NOTE", kind: .message)

        parentSession.onHostMessagesReturned?([
            HostMessage(display: [.text("shown")], wire: [.text("WAKE NOTE")], origin: .notes([wake]))
        ])
        childSession.onHostMessagesReturned?([
            HostMessage(display: [.text("Run the tests")], wire: [.text("framed")], origin: .fromParent(text: "Run the tests"))
        ])

        let preamble = try #require(parentSession.userMessagePreamble?())
        #expect(preamble.contains("WAKE NOTE"))
        #expect(preamble.contains("removed your message"))
        #expect(preamble.contains("Run the tests"))
    }

    @Test func aQueuedNoteShowsItsEventSummaries() {
        let child = ChildSessionFormats.Participant(sessionID: "C1", title: "Fix", name: "fix")
        let notes = ChildSessionCoordinator.joined([
            .init(childID: UUID(), text: ChildSessionFormats.turnFinishedNote(child: child, text: "Done")),
            .init(childID: UUID(), text: ChildSessionFormats.messageFromChildNote(child: child, text: "Help")),
        ])
        #expect(ChildSessionFormats.summary(ofNotes: notes) == "↳ fix finished a turn: Done\n↳ fix sent a message: Help")
    }
}
