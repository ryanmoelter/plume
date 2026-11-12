import Foundation
import SwiftData
import Testing
@testable import Plume

/// A child never starts with more freedom than its parent has, bypass needs
/// both the setting and a parent in bypass, a parent in plan mode starts
/// nothing, and a child whose parent closed still gets only `send_message`.
@MainActor
struct ChildSessionPermissionsTests {
    private let context: ModelContext

    init() throws {
        context = ModelContext(try ModelContainer(
            for: Schema([TaskGroup.self, WorkTask.self, TaskTab.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        ))
    }

    private func mode(_ requested: PermissionMode?, parent: PermissionMode, bypass: Bool = true) -> PermissionMode? {
        try? ChildSessionPermissions.mode(requested: requested, parent: parent, showsBypassPermissions: bypass).get()
    }

    @Test func aChildIsCappedAtItsParentsMode() {
        #expect(mode(.bypassPermissions, parent: .manual) == .manual)
        #expect(mode(.auto, parent: .acceptEdits) == .acceptEdits)
        #expect(mode(.acceptEdits, parent: .auto) == .acceptEdits)
        #expect(mode(.plan, parent: .auto) == .plan)
        #expect(mode(nil, parent: .acceptEdits) == .acceptEdits)
    }

    @Test func bypassNeedsTheSettingAndAParentInBypass() {
        #expect(mode(.bypassPermissions, parent: .bypassPermissions, bypass: true) == .bypassPermissions)
        #expect(mode(.bypassPermissions, parent: .bypassPermissions, bypass: false) == .auto)
        #expect(mode(nil, parent: .bypassPermissions, bypass: false) == .auto)
        #expect(mode(.bypassPermissions, parent: .auto, bypass: true) == .auto)
    }

    @Test func aParentInPlanModeStartsNothing() async throws {
        #expect(mode(.manual, parent: .plan) == nil)

        let task = TaskStore.createTask(in: context, siblings: [])
        let parent = try #require(task.tabs.first)
        parent.permissionMode = .plan
        let request = try StartSessionRequest.parse([
            "title": .string("Fix"), "prompt": .string("Go"), "initiation": .string("user_asked"),
            "use_worktree": .bool(false)
        ]).get()

        let result = await ChildSessionCoordinator.shared.startSession(request, from: parent)

        guard case .failure(let error) = result else {
            Issue.record("expected a refusal")
            return
        }
        #expect(error.message.contains("Exit plan mode first"))
        #expect(task.tabs.count == 1)
    }

    @Test func aChildWhoseParentClosedStillGetsOnlySendMessage() async throws {
        let task = TaskStore.createTask(in: context, siblings: [])
        let orphan = try #require(task.tabs.first)
        orphan.parentTabIDRaw = UUID().uuidString
        let session = HeadlessSession(tabID: orphan.id, taskID: task.id)
        ChildSessionCoordinator.shared.attach(to: session, task: task, tab: orphan)
        let server = try #require(session.mcpServer)

        let list = await server.handle(.object(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string("tools/list")]))
        let names = list?["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue }
        #expect(names == ["send_message"])

        let reply = await server.handle(.object([
            "jsonrpc": .string("2.0"), "id": .number(2), "method": .string("tools/call"),
            "params": .object(["name": .string("send_message"), "arguments": .object([
                "to": .string("parent"), "message": .string("hi")
            ])])
        ]))
        #expect(reply?["result"]?["isError"]?.boolValue == true)
        let text = reply?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
        #expect(text.contains("is closed"))
    }
}
