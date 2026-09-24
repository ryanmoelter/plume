import Foundation
import Testing
@testable import Plume

@MainActor
struct CodexForeignThreadTests {
    @MainActor private final class Harness {
        var client: CodexAppServerClient!
        var lines: [JSONValue] = []
        var parents: [String: String] = [:]
        var delayedReads = false
        var pendingReads: [JSONValue] = []
        init() {
            client = CodexAppServerClient { [weak self] line in
                guard let self, let message = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)) else { return true }
                lines.append(message)
                guard let id = message["id"], let method = message["method"]?.stringValue else { return true }
                if delayedReads && method == "thread/read" {
                    pendingReads.append(message)
                    return true
                }
                let threadID = message["params"]?["threadId"]?.stringValue ?? "root"
                let result: JSONValue
                switch method {
                case "thread/start": result = .object(["thread": .object(["id": .string("root")])])
                case "thread/read": result = metadata(threadID)
                default: result = .object(["data": .array([])])
                }
                reply(id: id, result: result)
                return true
            }
        }
        func metadata(_ id: String) -> JSONValue {
            var thread: [String: JSONValue] = ["id": .string(id)]
            if let parent = parents[id] {
                thread["source"] = .object(["subAgent": .object(["thread_spawn": .object(["parent_thread_id": .string(parent)])])])
            }
            return .object(["thread": .object(thread)])
        }
        func reply(id: JSONValue, result: JSONValue) {
            let data = try! JSONEncoder().encode(JSONValue.object(["id": id, "result": result]))
            client.receive(String(decoding: data, as: UTF8.self))
        }
        func notification(_ method: String, threadID: String, fields: [String: JSONValue] = [:]) {
            var params = fields
            params["threadId"] = .string(threadID)
            let data = try! JSONEncoder().encode(JSONValue.object(["method": .string(method), "params": .object(params)]))
            client.receive(String(decoding: data, as: UTF8.self))
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("Expected protocol event did not arrive")
    }

    @Test func unrelatedBroadcastsAndApprovalsDoNotBecomeChildren() async throws {
        let h = Harness()
        let session = CodexSession(tabID: UUID(), taskID: UUID(), client: h.client)
        defer { session.stop(); CodexSubagentStore.shared.forget(tabID: session.tabID) }
        session.start(workingDirectory: nil, resumeThreadID: nil, model: nil, environment: [:])
        try await waitUntil { session.sessionID == "root" }
        h.notification("turn/started", threadID: "unrelated")
        h.client.receive(#"{"id":"foreign-approval","method":"item/commandExecution/requestApproval","params":{"threadId":"unrelated","command":"pwd"}}"#)
        try await waitUntil { h.lines.contains { $0["method"] == .string("thread/read") } }
        for _ in 0..<20 { await Task.yield() }
        #expect(CodexSubagentStore.shared.subagents(forTab: session.tabID).isEmpty)
        #expect(session.pendingPermissions.isEmpty)
        #expect(!h.lines.contains { $0["id"] == .string("foreign-approval") })
        #expect(!h.lines.contains { $0["method"] == .string("thread/backgroundTerminals/list") && $0["params"]?["threadId"] == .string("unrelated") })
    }

    @Test func earlyGrandchildTrafficIsReplayedAfterAncestryVerification() async throws {
        let h = Harness()
        h.parents = ["child": "root", "grandchild": "child"]
        let session = CodexSession(tabID: UUID(), taskID: UUID(), client: h.client)
        defer { session.stop(); CodexSubagentStore.shared.forget(tabID: session.tabID) }
        session.start(workingDirectory: nil, resumeThreadID: nil, model: nil, environment: [:])
        try await waitUntil { session.sessionID == "root" }
        h.notification("turn/started", threadID: "grandchild")
        h.client.receive(#"{"id":"child-approval","method":"item/commandExecution/requestApproval","params":{"threadId":"grandchild","command":"pwd"}}"#)
        try await waitUntil { !session.pendingPermissions.isEmpty }
        #expect(session.pendingPermissions.first?.agentID == "grandchild")
        #expect(CodexSubagentStore.shared.subagents(forTab: session.tabID).contains { $0.id == "grandchild" })
    }

    @Test func stoppingDuringAncestryReadDoesNotResurrectChildActivity() async throws {
        let h = Harness()
        h.parents = ["child": "root"]
        let session = CodexSession(tabID: UUID(), taskID: UUID(), client: h.client)
        defer { CodexSubagentStore.shared.forget(tabID: session.tabID) }
        session.start(workingDirectory: nil, resumeThreadID: nil, model: nil, environment: [:])
        try await waitUntil { session.sessionID == "root" }
        h.delayedReads = true
        h.notification("turn/started", threadID: "child")
        try await waitUntil { !h.pendingReads.isEmpty }
        session.stop()
        if let id = h.pendingReads.first?["id"] { h.reply(id: id, result: h.metadata("child")) }
        for _ in 0..<20 { await Task.yield() }
        #expect(CodexSubagentStore.shared.subagents(forTab: session.tabID).isEmpty)
    }
}
