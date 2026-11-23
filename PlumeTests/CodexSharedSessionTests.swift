import Foundation
import SwiftData
import Testing
@testable import Plume

@MainActor
struct CodexSharedSessionTests {
    @MainActor private final class Harness {
        var client: CodexAppServerClient!
        var responses: [JSONValue] = []
        var initializeCount = 0
        var newThreadParameters: [JSONValue] = []
        init() {
            client = CodexAppServerClient { [weak self] line in
                guard let self, let value = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)) else { return false }
                guard let method = value["method"]?.stringValue else { responses.append(value); return true }
                guard let id = value["id"] else { return true }
                let result: JSONValue
                switch method {
                case "initialize": initializeCount += 1; result = .object([:])
                case "thread/start":
                    let params = value["params"] ?? .null
                    newThreadParameters.append(params)
                    let name = params["cwd"]?.stringValue.map { ($0 as NSString).lastPathComponent } ?? "unknown"
                    var fields: [String: JSONValue] = ["thread": .object(["id": .string(name)])]
                    fields["runtimeWorkspaceRoots"] = params["runtimeWorkspaceRoots"]
                    result = .object(fields)
                case "thread/read": result = .object(["thread": .object(["id": value["params"]?["threadId"] ?? .null])])
                default: result = .object(["data": .array([])])
                }
                let data = try! JSONEncoder().encode(JSONValue.object(["id": id, "result": result]))
                client.receive(String(decoding: data, as: UTF8.self))
                return true
            }
        }
    }

    @Test func sharedSessionsIsolateInterleavedItemsAndApprovals() async throws {
        let h = Harness()
        let host = CodexSharedAppServer(physical: h.client)
        let items = CodexItemStore()
        let a = CodexSession(tabID: UUID(), taskID: UUID(), client: CodexAppServerClient(sharedServer: host), itemStore: items)
        let b = CodexSession(tabID: UUID(), taskID: UUID(), client: CodexAppServerClient(sharedServer: host), itemStore: items)
        defer {
            a.stop(); b.stop()
            for session in [a, b] {
                items.forget(tabID: session.tabID)
                CodexSubagentStore.shared.forget(tabID: session.tabID)
            }
        }
        a.start(workingDirectory: "first", resumeThreadID: nil, model: nil, environment: [:])
        b.start(workingDirectory: "second", resumeThreadID: nil, model: nil, environment: [:])
        for _ in 0..<1000 {
            if a.sessionID == "first", b.sessionID == "second" { break }
            await Task.yield()
        }
        #expect(a.sessionID == "first")
        #expect(b.sessionID == "second")
        #expect(h.initializeCount == 1)
        #expect(h.newThreadParameters.count == 2)
        #expect(h.newThreadParameters.allSatisfy { $0["dynamicTools"] == .array([CodexPresenceTool.definition]) })
        h.client.receive(#"{"method":"turn/started","params":{"threadId":"first","turn":{"id":"turn-a"}}}"#)
        h.client.receive(#"{"id":890,"method":"item/tool/call","params":{"threadId":"first","turnId":"turn-a","callId":"presence","tool":"plume_presence","arguments":{}}}"#)
        h.client.receive(#"{"id":891,"method":"item/tool/call","params":{"threadId":"second","turnId":"turn-a","callId":"wrong-turn","tool":"plume_presence","arguments":{}}}"#)
        let validCall = try #require(h.responses.first { $0["id"] == .number(890) })
        #expect(validCall["result"]?["success"] == .bool(true))
        let wrongTurn = try #require(h.responses.first { $0["id"] == .number(891) })
        #expect(wrongTurn["error"]?["code"] == .number(-32601))
        h.client.receive(#"{"method":"turn/completed","params":{"threadId":"first","turn":{"id":"turn-a","status":"completed"}}}"#)
        h.client.receive(#"{"method":"item/completed","params":{"threadId":"first","item":{"id":"a","type":"agentMessage","text":"First answer"}}}"#)
        h.client.receive(#"{"method":"item/completed","params":{"threadId":"second","item":{"id":"b","type":"agentMessage","text":"Second answer"}}}"#)
        #expect(items.item(tabID: a.tabID, id: "a") != nil)
        #expect(items.item(tabID: a.tabID, id: "b") == nil)
        #expect(items.item(tabID: b.tabID, id: "b") != nil)
        #expect(items.item(tabID: b.tabID, id: "a") == nil)
        h.client.receive(#"{"id":900,"method":"item/commandExecution/requestApproval","params":{"threadId":"first","itemId":"cmd","command":"pwd","availableDecisions":["accept","decline"]}}"#)
        h.client.receive(#"{"id":901,"method":"item/commandExecution/requestApproval","params":{"threadId":"second","itemId":"cmd","command":"ls","availableDecisions":["accept","decline"]}}"#)
        // A newly attached remote root can replay an unresolved request.
        h.client.receive(#"{"id":900,"method":"item/commandExecution/requestApproval","params":{"threadId":"first","itemId":"cmd","command":"pwd","availableDecisions":["accept","decline"]}}"#)
        #expect(a.pendingPermissions.map(\.id) == ["number:900"])
        #expect(b.pendingPermissions.map(\.id) == ["number:901"])
        let approval = try #require(a.pendingPermissions.first)
        a.resolve(approval, with: approval.decisions[0])
        #expect(h.responses.filter { $0["id"] == .number(900) }.count == 1)
        #expect(b.pendingPermissions.count == 1)
    }

    @Test func childToolsRequireApprovalAndRespectPlanMode() async throws {
        let h = Harness()
        let host = CodexSharedAppServer(physical: h.client)
        let codex = CodexSession(tabID: UUID(), taskID: UUID(), client: CodexAppServerClient(sharedServer: host))
        defer {
            codex.stop()
            CodexItemStore.shared.forget(tabID: codex.tabID)
            CodexSubagentStore.shared.forget(tabID: codex.tabID)
        }
        var calls: [PlumeMCPServer.ToolCall] = []
        var approvals: [Bool] = []
        codex.childSessionTools = CodexChildSessionTools(role: .parent) { call, approved in
            calls.append(call)
            approvals.append(approved)
            return .success("Passed to the coordinator")
        }
        codex.start(
            workingDirectory: "/parent", resumeThreadID: nil, model: nil,
            childNotesDirectory: "/notes/parent", environment: [:]
        )
        for _ in 0..<1000 {
            if codex.sessionID == "parent" { break }
            await Task.yield()
        }
        try #require(codex.sessionID == "parent")
        let threadParameters = try #require(h.newThreadParameters.first)
        let tools = try #require(threadParameters["dynamicTools"]?.arrayValue)
        #expect(tools.compactMap { $0["name"]?.stringValue } == [
            "plume_presence", "plume_start_session", "plume_send_message", "plume_dismiss_task"
        ])
        let startTool = try #require(tools.first { $0["name"] == .string("plume_start_session") })
        #expect(startTool["inputSchema"]?["properties"]?["context"]?["enum"] == .array([.string("fresh")]))
        #expect(threadParameters["runtimeWorkspaceRoots"] == .array([.string("/parent"), .string("/notes/parent")]))
        h.client.receive(#"{"method":"turn/started","params":{"threadId":"parent","turn":{"id":"turn-a"}}}"#)
        h.client.receive(#"{"id":902,"method":"item/tool/call","params":{"threadId":"parent","turnId":"turn-a","callId":"start-a","tool":"plume_start_session","arguments":{"title":"Verify report","prompt":"Check the generated report","initiation":"user_asked"}}}"#)
        #expect(calls.isEmpty)
        let approval = try #require(codex.pendingPermissions.first)
        #expect(approval.toolUseID == "turn-a#start-a")
        codex.resolve(approval, with: .deny(message: "Declined"))
        #expect(h.responses.first { $0["id"] == .number(902) }?["result"]?["success"] == .bool(false))
        #expect(calls.isEmpty)

        h.client.receive(#"{"id":903,"method":"item/tool/call","params":{"threadId":"parent","turnId":"turn-a","callId":"start-b","tool":"plume_start_session","arguments":{"title":"Verify report","prompt":"Check the generated report","initiation":"user_asked"}}}"#)
        codex.resolve(try #require(codex.pendingPermissions.first), with: .allow(updatedInput: [:]))
        for _ in 0..<1000 {
            if h.responses.contains(where: { $0["id"] == .number(903) }) { break }
            await Task.yield()
        }
        #expect(calls.map(\.tool) == [.startSession])
        #expect(approvals == [true])

        codex.setCollaborationMode(.plan)
        h.client.receive(#"{"id":904,"method":"item/tool/call","params":{"threadId":"parent","turnId":"turn-a","callId":"offer","tool":"plume_start_session","arguments":{"initiation":"offer"}}}"#)
        #expect(h.responses.first { $0["id"] == .number(904) }?["result"]?["success"] == .bool(false))
        #expect(codex.pendingPermissions.isEmpty)
        #expect(calls.count == 1)

        h.client.receive(#"{"id":905,"method":"item/tool/call","params":{"threadId":"parent","turnId":"turn-a","callId":"proposal","tool":"plume_start_session","arguments":{"initiation":"own_initiative"}}}"#)
        for _ in 0..<1000 {
            if h.responses.contains(where: { $0["id"] == .number(905) }) { break }
            await Task.yield()
        }
        #expect(calls.map(\.toolUseID) == ["turn-a#start-b", "turn-a#proposal"])
        #expect(approvals == [true, false])
    }

    @Test func codexChildCanSendNotesToItsParentFromAUserTurn() async throws {
        let container = try ModelContainer(
            for: Schema([TaskGroup.self, WorkTask.self, TaskTab.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let task = TaskStore.createTask(in: context, title: "Task", siblings: [])
        let parent = try #require(task.tabs.first)
        let child = TaskStore.addChildTab(to: task, parent: parent, in: context)
        let sibling = TaskStore.addChildTab(to: task, parent: parent, in: context)
        try context.save()

        let h = Harness()
        let host = CodexSharedAppServer(physical: h.client)
        let childSession = CodexSession(tabID: child.id, taskID: task.id, client: CodexAppServerClient(sharedServer: host))
        let parentSession = HeadlessSession(tabID: parent.id, taskID: task.id)
        let coordinator = ChildSessionCoordinator()
        coordinator.attach(to: childSession, tab: child)
        coordinator.attach(to: parentSession, task: task, tab: parent)
        defer {
            childSession.stop()
            CodexItemStore.shared.forget(tabID: child.id)
            CodexSubagentStore.shared.forget(tabID: child.id)
        }

        childSession.start(workingDirectory: "child", resumeThreadID: nil, model: nil, isChildSession: true, environment: [:])
        for _ in 0..<1000 {
            if childSession.sessionID == "child" { break }
            await Task.yield()
        }
        try #require(childSession.sessionID == "child")
        #expect(h.newThreadParameters.first?["dynamicTools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } == [
            "plume_presence", "plume_send_message"
        ])
        h.client.receive(#"{"method":"turn/started","params":{"threadId":"child","turn":{"id":"user-turn"}}}"#)

        func call(_ id: Int, _ tool: String, to: String, message: String, turn: String = "user-turn") async throws -> JSONValue {
            h.client.receive(#"{"id":\#(id),"method":"item/tool/call","params":{"threadId":"child","turnId":"\#(turn)","callId":"call-\#(id)","tool":"\#(tool)","arguments":{"to":"\#(to)","message":"\#(message)"}}}"#)
            for _ in 0..<1000 {
                if let reply = h.responses.first(where: { $0["id"] == .number(Double(id)) }) { return reply }
                await Task.yield()
            }
            return try #require(h.responses.first { $0["id"] == .number(Double(id)) })
        }

        let stale = try await call(910, "plume_send_message", to: "parent", message: "Stale note", turn: "old-turn")
        #expect(stale["error"]?["code"] == .number(-32601))
        let sideways = try await call(911, "plume_send_message", to: sibling.id.uuidString, message: "Sibling note")
        #expect(sideways["result"]?["success"] == .bool(false))
        let start = try await call(912, "plume_start_session", to: "parent", message: "Start")
        #expect(start["result"]?["success"] == .bool(false))
        let dismiss = try await call(913, "plume_dismiss_task", to: "parent", message: "Dismiss")
        #expect(dismiss["result"]?["success"] == .bool(false))
        #expect(parentSession.userMessagePreamble?() == nil)

        let alias = try await call(914, "plume_send_message", to: "parent", message: "Need a decision")
        #expect(alias["result"]?["success"] == .bool(true))
        let uuid = try await call(915, "plume_send_message", to: parent.id.uuidString.lowercased(), message: "See the draft")
        #expect(uuid["result"]?["success"] == .bool(true))
        #expect(childSession.pendingPermissions.isEmpty)
        h.client.receive(#"{"method":"turn/completed","params":{"threadId":"child","turn":{"id":"user-turn","status":"completed"}}}"#)
        let preamble = try #require(parentSession.userMessagePreamble?()?.wire.plainText)
        #expect(preamble.contains("Need a decision"))
        #expect(preamble.contains("See the draft"))
        #expect(preamble.contains(#""event":"message""#))
        #expect(!preamble.contains(#""event":"turn_finished""#))
    }

}
