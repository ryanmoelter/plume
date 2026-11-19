import Foundation
import SwiftData
import Testing
@testable import Plume

/// A running child's mode is not limited by its parent's: its picker offers
/// every mode, and an approved plan or an accepted mode suggestion applies as
/// it would in any tab. A mode the model enters itself is tracked from the
/// CLI's `status`, and in plan mode Plume refuses `start_session` at
/// `can_use_tool`.
@MainActor
struct ChildSessionModeTests {
    private let context: ModelContext

    init() throws {
        context = ModelContext(try ModelContainer(
            for: Schema([TaskGroup.self, WorkTask.self, TaskTab.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        ))
    }

    private final class Lines {
        var all: [String] = []
    }

    private func makeSession() -> (HeadlessSession, Lines) {
        let backgroundTasks = BackgroundTaskTracker()
        let engine = StatusEngine(backgroundTasks: backgroundTasks)
        let session = HeadlessSession(tabID: UUID(), taskID: UUID(), statusEngine: engine, backgroundTasks: backgroundTasks)
        engine.register(tabID: session.tabID, taskID: session.taskID)
        let lines = Lines()
        session.debugLineSink = { lines.all.append($0) }
        return (session, lines)
    }

    private func receive(_ session: HeadlessSession, _ line: String) throws {
        session.handle(try #require(StreamJSONDecoder.decode(line: line)))
    }

    private func json(_ line: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
    }

    private func requestedModes(_ lines: Lines) throws -> [String] {
        try lines.all.compactMap { line in
            let request = try json(line)["request"]
            guard request?["subtype"]?.stringValue == "set_permission_mode" else { return nil }
            return request?["mode"]?.stringValue
        }
    }

    private static func canUseTool(_ tool: String, id: String = "r1") -> String {
        #"{"type":"control_request","request_id":""# + id + #"","request":{"subtype":"can_use_tool","tool_name":""# + tool + #"","input":{}}}"#
    }

    @Test func theChildsPickerTakesAModeAboveItsParents() throws {
        let task = TaskStore.createTask(in: context, siblings: [])
        let parent = try #require(task.tabs.first)
        parent.permissionMode = .acceptEdits
        let child = TaskStore.addChildTab(to: task, parent: parent, in: context)
        child.permissionMode = .manual
        let settings = ComposerSettings(session: nil, tab: child, defaults: .init(effort: .medium))

        settings.setPermissionPreset(AgentPermissionPreset(id: PermissionMode.auto.rawValue, label: PermissionMode.auto.label))

        #expect(child.permissionMode == .auto)
    }

    @Test func approvingAPlanGoesToAuto() throws {
        let (session, lines) = makeSession()
        try receive(session, Self.canUseTool("ExitPlanMode"))
        session.approvePlan(try #require(session.pendingPermissions.first))

        #expect(try requestedModes(lines) == [PermissionMode.auto.token])
    }

    @Test func anAcceptedModeSuggestionRidesTheAnswer() throws {
        let (session, lines) = makeSession()
        try receive(session, #"{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Write","input":{},"permission_suggestions":[{"type":"setMode","mode":"acceptEdits","destination":"session"}]}}"#)
        let permission = try #require(session.pendingPermissions.first)

        session.resolve(permission, accepting: permission.suggestions[0])

        let answer = try json(try #require(lines.all.first))
        #expect(answer["response"]?["response"]?["updatedPermissions"]?.arrayValue?.count == 1)
        #expect(try requestedModes(lines).isEmpty)
        #expect(session.permissionMode == .acceptEdits)
    }

    // MARK: - Plan mode the model enters

    /// The line `claude -p` 2.1.321 wrote when the model called `EnterPlanMode`.
    private static let enteredPlanMode = #"{"type":"system","subtype":"status","status":null,"permissionMode":"plan","uuid":"u1","session_id":"s1"}"#

    @Test func aModeTheModelEntersIsTracked() throws {
        let (session, _) = makeSession()
        try receive(session, #"{"type":"system","subtype":"init","session_id":"s1","permissionMode":"auto"}"#)

        try receive(session, Self.enteredPlanMode)

        #expect(session.permissionMode == .plan)
    }

    @Test func inPlanModeStartingASessionIsRefusedButMessagingIsNot() throws {
        let (session, lines) = makeSession()
        session.mcpServer = PlumeMCPServer(role: { .parent }) { _ in .success("ok") }
        try receive(session, Self.enteredPlanMode)

        try receive(session, Self.canUseTool(PlumeMCPTool.startSession.qualifiedName, id: "r1"))
        try receive(session, Self.canUseTool(PlumeMCPTool.sendMessage.qualifiedName, id: "r2"))

        let behaviors = try lines.all.map { try json($0)["response"]?["response"]?["behavior"]?.stringValue }
        #expect(behaviors == ["deny", "allow"])
        #expect(lines.all.first?.contains("Exit plan mode first") == true)
        #expect(session.pendingPermissions.isEmpty)
    }
}
