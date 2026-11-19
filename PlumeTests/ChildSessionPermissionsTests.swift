import Foundation
import SwiftData
import Testing
@testable import Plume

/// A child gets the mode it asks for, even one above its parent's, or its
/// parent's when it asks for none. Bypass needs the setting, and the user's
/// approval unless the parent is in bypass; without them the child gets auto.
/// A parent in plan mode starts nothing, and a child whose parent closed
/// still gets only `send_message`.
@MainActor
struct ChildSessionPermissionsTests {
    private let context: ModelContext

    init() throws {
        context = ModelContext(try ModelContainer(
            for: Schema([TaskGroup.self, WorkTask.self, TaskTab.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        ))
    }

    private func mode(
        _ requested: PermissionMode?, parent: PermissionMode, bypass: Bool = true, approved: Bool = false
    ) -> PermissionMode? {
        try? ChildSessionPermissions.mode(
            requested: requested, parent: parent, showsBypassPermissions: bypass, approvedByUser: approved
        ).get()
    }

    @Test func aChildGetsTheModeItAsksFor() {
        #expect(mode(.auto, parent: .acceptEdits) == .auto)
        #expect(mode(.acceptEdits, parent: .auto) == .acceptEdits)
        #expect(mode(.plan, parent: .auto) == .plan)
    }

    @Test func aChildThatAsksForNoModeGetsItsParents() {
        #expect(mode(nil, parent: .acceptEdits) == .acceptEdits)
        #expect(mode(nil, parent: .manual) == .manual)
        #expect(mode(nil, parent: .bypassPermissions) == .bypassPermissions)
    }

    @Test(arguments: [PermissionMode.manual, .auto, .acceptEdits])
    func bypassFromAParentWithoutItNeedsApproval(parent: PermissionMode) {
        #expect(mode(.bypassPermissions, parent: parent, approved: true) == .bypassPermissions)
        #expect(mode(.bypassPermissions, parent: parent, approved: false) == .auto)
    }

    @Test func aBypassParentPassesBypassOnUnapproved() {
        #expect(mode(.bypassPermissions, parent: .bypassPermissions, approved: false) == .bypassPermissions)
    }

    @Test func bypassNeedsTheSetting() {
        #expect(mode(.bypassPermissions, parent: .bypassPermissions, bypass: false) == .auto)
        #expect(mode(nil, parent: .bypassPermissions, bypass: false) == .auto)
        #expect(mode(.bypassPermissions, parent: .auto, bypass: false, approved: true) == .auto)
    }

    @Test func onlyBypassAboveTheParentNeedsApproval() {
        func needs(_ requested: PermissionMode?, _ parent: PermissionMode?, bypass: Bool = true) -> Bool {
            ChildSessionPermissions.needsApproval(requested: requested, parent: parent, showsBypassPermissions: bypass)
        }
        #expect(needs(.bypassPermissions, .auto))
        #expect(needs(.bypassPermissions, .acceptEdits))
        #expect(!needs(.bypassPermissions, .bypassPermissions))
        #expect(!needs(nil, .auto))
        #expect(!needs(nil, .bypassPermissions))
        #expect(!needs(.auto, .acceptEdits))
        #expect(!needs(.bypassPermissions, .auto, bypass: false))
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

        let result = await ChildSessionCoordinator.shared.startSession(request, from: parent, approvedByUser: false)

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
