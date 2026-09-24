import Foundation
import Testing
@testable import Plume

@MainActor
struct CodexSharedSessionTests {
    @MainActor private final class Harness {
        var client: CodexAppServerClient!
        var responses: [JSONValue] = []
        var initializeCount = 0
        init() {
            client = CodexAppServerClient { [weak self] line in
                guard let self, let value = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)) else { return false }
                guard let method = value["method"]?.stringValue else { responses.append(value); return true }
                guard let id = value["id"] else { return true }
                let result: JSONValue
                switch method {
                case "initialize": initializeCount += 1; result = .object([:])
                case "thread/start": result = .object(["thread": .object(["id": value["params"]?["cwd"] ?? .string("unknown")])])
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
        let a = CodexSession(tabID: UUID(), taskID: UUID(), client: CodexAppServerClient(sharedServer: host))
        let b = CodexSession(tabID: UUID(), taskID: UUID(), client: CodexAppServerClient(sharedServer: host))
        defer {
            a.stop(); b.stop()
            for session in [a, b] {
                CodexItemStore.shared.forget(tabID: session.tabID)
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
        h.client.receive(#"{"method":"item/completed","params":{"threadId":"first","item":{"id":"a","type":"agentMessage","text":"First answer"}}}"#)
        h.client.receive(#"{"method":"item/completed","params":{"threadId":"second","item":{"id":"b","type":"agentMessage","text":"Second answer"}}}"#)
        #expect(CodexItemStore.shared.item(tabID: a.tabID, id: "a") != nil)
        #expect(CodexItemStore.shared.item(tabID: a.tabID, id: "b") == nil)
        #expect(CodexItemStore.shared.item(tabID: b.tabID, id: "b") != nil)
        #expect(CodexItemStore.shared.item(tabID: b.tabID, id: "a") == nil)
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
}
