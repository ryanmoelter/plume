import Foundation
import SwiftData
import Testing
@testable import Plume

/// A running child is raised past its parent's mode only by the user's own
/// pick in the picker: an approved plan or an accepted mode suggestion stops
/// at the parent's mode, or at the child's launch mode once the parent is
/// gone. A mode the model enters itself is tracked from the CLI's `status`,
/// and in plan mode Plume refuses `start_session` at `can_use_tool`.
@MainActor
struct ChildSessionModeCapTests {
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

    private func makeSession(ceiling: PermissionMode? = nil) -> (HeadlessSession, Lines) {
        let backgroundTasks = BackgroundTaskTracker()
        let engine = StatusEngine(backgroundTasks: backgroundTasks)
        let session = HeadlessSession(tabID: UUID(), taskID: UUID(), statusEngine: engine, backgroundTasks: backgroundTasks)
        engine.register(tabID: session.tabID, taskID: session.taskID)
        let lines = Lines()
        session.debugLineSink = { lines.all.append($0) }
        if let ceiling { session.permissionCeiling = { ceiling } }
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

    // MARK: - The ceiling

    @Test func theCeilingIsTheParentsModeOrTheLaunchMode() {
        #expect(ChildSessionPermissions.ceiling(parent: .acceptEdits, launchedWith: .manual, showsBypassPermissions: true) == .acceptEdits)
        #expect(ChildSessionPermissions.ceiling(parent: nil, launchedWith: .manual, showsBypassPermissions: true) == .manual)
        #expect(ChildSessionPermissions.ceiling(parent: .plan, launchedWith: .auto, showsBypassPermissions: true) == .manual)
        #expect(ChildSessionPermissions.ceiling(parent: .bypassPermissions, launchedWith: .auto, showsBypassPermissions: false) == .auto)
        #expect(ChildSessionPermissions.capped(.auto, at: .acceptEdits) == .acceptEdits)
        #expect(ChildSessionPermissions.capped(.plan, at: .acceptEdits) == .plan)
    }

    @Test func aChildFollowsItsLiveParentThenItsLaunchMode() throws {
        let task = TaskStore.createTask(in: context, siblings: [])
        let parent = try #require(task.tabs.first)
        parent.permissionMode = .acceptEdits
        let child = TaskStore.addChildTab(to: task, parent: parent, in: context)
        child.permissionMode = .manual
        let session = HeadlessSession(tabID: child.id, taskID: task.id)
        ChildSessionCoordinator.shared.attach(to: session, task: task, tab: child)
        defer { ChildSessionCoordinator.shared.tabForgotten(child.id) }

        #expect(session.permissionCeiling?() == .acceptEdits)
        child.parentTabIDRaw = UUID().uuidString
        #expect(session.permissionCeiling?() == .manual)
    }

    @Test func aParentHasNoCeiling() throws {
        let task = TaskStore.createTask(in: context, siblings: [])
        let parent = try #require(task.tabs.first)
        let session = HeadlessSession(tabID: parent.id, taskID: task.id)
        ChildSessionCoordinator.shared.attach(to: session, task: task, tab: parent)

        #expect(session.permissionCeiling?() == nil)
    }

    // MARK: - Raises

    @Test func approvingAPlanInAChildStopsAtTheCeiling() throws {
        let (session, lines) = makeSession(ceiling: .acceptEdits)
        try receive(session, Self.canUseTool("ExitPlanMode"))
        let plan = try #require(session.pendingPermissions.first)

        session.approvePlan(plan)

        #expect(try requestedModes(lines) == [PermissionMode.acceptEdits.token])
        #expect(session.permissionMode == .acceptEdits)
    }

    @Test func approvingAPlanWithNoCeilingGoesToAuto() throws {
        let (session, lines) = makeSession()
        try receive(session, Self.canUseTool("ExitPlanMode"))
        session.approvePlan(try #require(session.pendingPermissions.first))

        #expect(try requestedModes(lines) == [PermissionMode.auto.token])
    }

    @Test func anAcceptedModeSuggestionStopsAtTheCeiling() throws {
        let (session, lines) = makeSession(ceiling: .manual)
        try receive(session, #"{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Write","input":{},"permission_suggestions":[{"type":"setMode","mode":"acceptEdits","destination":"session"}]}}"#)
        let permission = try #require(session.pendingPermissions.first)

        session.resolve(permission, accepting: permission.suggestions[0])

        let answer = try json(try #require(lines.all.first))
        #expect(answer["response"]?["response"]?["behavior"]?.stringValue == "allow")
        #expect(answer["response"]?["response"]?["updatedPermissions"] == nil)
        #expect(try requestedModes(lines) == [PermissionMode.manual.token])
        #expect(session.permissionMode == .manual)
    }

    @Test func theUsersOwnPickIsNeverCapped() throws {
        let (session, lines) = makeSession(ceiling: .manual)
        session.setPermissionMode(.auto)

        #expect(try requestedModes(lines) == [PermissionMode.auto.token])
        #expect(session.permissionMode == .auto)
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
