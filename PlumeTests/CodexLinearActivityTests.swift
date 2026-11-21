import Foundation
import Testing
@testable import Plume

@MainActor
struct CodexLinearActivityTests {
    private func item(_ id: String = "call", server: String = "plume-linear", tool: String = "get_issue", input: String = #"{"id":"PLUME-288"}"#, result: String? = nil, status: String = "inProgress") throws -> JSONValue {
        var fields: [String: JSONValue] = [
            "id": .string(id), "type": .string("mcpToolCall"), "server": .string(server),
            "tool": .string(tool), "arguments": try JSONDecoder().decode(JSONValue.self, from: Data(input.utf8)),
            "status": .string(status)
        ]
        if let result { fields["result"] = try JSONDecoder().decode(JSONValue.self, from: Data(result.utf8)) }
        return .object(fields)
    }

    @Test func liveCompletionReplacesPendingEvidenceAndHistoryDoesNotDuplicateIt() throws {
        let sink = CodexLinearSink()
        let store = CodexItemStore(linearActivity: CodexLinearActivity(sink: sink))
        let tab = UUID()
        store.upsert(tabID: tab, item: try item(tool: "save_issue", input: #"{"id":"PLUME-288","state":"In Progress"}"#), turnID: "turn", lifecycle: .started)
        #expect(sink.evidence[tab]?.first?.outcome == .pending)
        let completed = try item(tool: "save_issue", input: #"{"id":"PLUME-288","state":"In Progress"}"#, result: #"{"content":[{"type":"text","text":"{\"identifier\":\"PLUME-288\"}"}]}"#, status: "completed")
        store.upsert(tabID: tab, item: completed, turnID: "turn", lifecycle: .completed)
        store.mergeHistory(tabID: tab, entries: [.object(["item": completed, "turnId": .string("turn")])], since: store.revision(forTab: tab))
        #expect(sink.evidence[tab]?.count == 1)
        #expect(sink.evidence[tab]?.first?.outcome == .succeeded)
        #expect(sink.evidence[tab]?.first?.requestedState == "In Progress")
        let call = try #require(store.transcript(forTab: tab)?.messages.first?.blocks.first)
        guard case .toolCall(let tool) = call else { Issue.record("Expected MCP call"); return }
        #expect(tool.name == "mcp__plume-linear__save_issue")
        #expect(tool.summary.name == "MCP")
        #expect(tool.summary.detail == "plume-linear.save_issue")
    }

    @Test func uuidAndCreatedIssuesResolveThroughMCPResultEnvelopes() throws {
        let store = CodexItemStore()
        let tab = UUID()
        store.replace(tabID: tab, items: [
            try item("structured", tool: "save_issue", input: #"{"team":"Plume"}"#, result: #"{"structuredContent":{"identifier":"PLUME-300"}}"#, status: "completed"),
            try item("text", input: #"{"id":"925ea779-451c-4723-b755-e0828e5912c3"}"#, result: #"{"content":[{"type":"text","text":"{\"identifier\":\"PLUME-301\"}"}]}"#, status: "completed")
        ])
        #expect(store.linearEvidence(forTab: tab).map(\.identifier) == ["PLUME-300", "PLUME-301"])
    }

    @Test func errorsDoNotPromoteResultIdentifiersAndEmptyCompletionsSucceed() throws {
        let store = CodexItemStore()
        let tab = UUID()
        store.upsert(tabID: tab, item: try item(result: #"{"isError":true,"structuredContent":{"identifier":"PLUME-999"}}"#, status: "completed"), lifecycle: .completed)
        #expect(store.linearEvidence(forTab: tab).map(\.identifier) == ["PLUME-288"])
        #expect(store.linearEvidence(forTab: tab).first?.outcome == .failed)
        store.replace(tabID: tab, items: [try item(status: "completed")])
        #expect(store.linearEvidence(forTab: tab).first?.outcome == .succeeded)
    }

    @Test func codexAppsLinearToolsUseCanonicalNamesAndExcludeOtherTools() throws {
        let store = CodexItemStore()
        let tab = UUID()
        store.replace(tabID: tab, items: [
            try item("write", server: "codex_apps", tool: "linear_save_issue", input: #"{"id":"PLUME-288","state":"In Progress"}"#, result: #"{"content":[{"type":"text","text":"{\"identifier\":\"PLUME-288\"}"}]}"#, status: "completed"),
            try item("read", server: "codex_apps", tool: "linear_get_issue"),
            try item("dotted", server: "codex_apps", tool: "linear.get_issue"),
            try item("nonlinear", server: "codex_apps", tool: "nonlinear.get_issue"),
            try item("prefix", server: "codex_apps", tool: "linearish.get_issue"),
            try item("unrelated", server: "codex_apps", tool: "github_get_issue"),
            try item("spoof", server: "not_codex_apps", tool: "linear_get_issue")
        ])
        #expect(store.linearEvidence(forTab: tab).map(\.tool) == ["save_issue", "get_issue", "get_issue"])
        #expect(store.linearEvidence(forTab: tab).first?.requestedState == "In Progress")
    }

    @Test func unrelatedServersListsAndProseDoNotBecomeActivity() throws {
        let store = CodexItemStore()
        let tab = UUID()
        store.replace(tabID: tab, items: [
            try item("false-server", server: "nonlinear"),
            try item("list", tool: "list_issues", result: #"{"structuredContent":{"identifier":"PLUME-999"}}"#, status: "completed"),
            .object(["id": .string("prose"), "type": .string("agentMessage"), "text": .string("mcp__linear__get_issue PLUME-999")])
        ])
        #expect(store.linearEvidence(forTab: tab).isEmpty)
    }

    @Test func parentAndChildEvidenceRetainProvenanceAndTabIsolation() throws {
        let sink = CodexLinearSink()
        let activity = CodexLinearActivity(sink: sink)
        let parent = CodexItemStore(linearActivity: activity)
        let children = CodexSubagentStore(linearActivity: activity)
        let tab = UUID(), other = UUID()
        parent.upsert(tabID: tab, item: try item())
        children.receiveParentItem(tabID: tab, taskID: UUID(), item: .object([
            "type": .string("subAgentActivity"), "agentThreadId": .string("child"),
            "agentPath": .string("reviewer"), "kind": .string("started")
        ]))
        children.receiveChildItem(tabID: tab, threadID: "child", item: try item(), turnID: "turn", lifecycle: .completed)
        children.mergeHistory(tabID: tab, threadID: "child", entries: [.object(["item": try item(), "turnId": .string("turn")])], since: children.revision(tabID: tab, threadID: "child"))
        #expect(sink.evidence[tab]?.count == 2)
        #expect(sink.evidence[tab]?.first?.subagent == nil)
        #expect(sink.evidence[tab]?.last?.subagent == LinearSubagentRef(id: "child", label: "reviewer"))
        parent.upsert(tabID: other, item: try item(input: #"{"id":"PLUME-400"}"#))
        #expect(sink.evidence[other]?.map(\.identifier) == ["PLUME-400"])
        children.forget(tabID: tab)
        #expect(sink.evidence[tab]?.count == 1)
        parent.forget(tabID: tab)
        #expect(sink.evidence[tab]?.isEmpty == true)
        #expect(sink.evidence[other]?.map(\.identifier) == ["PLUME-400"])
    }

    @Test func textDeltasDoNotRepublishActivityAndReplacementRefreshesIt() throws {
        let sink = CodexLinearSink()
        let store = CodexItemStore(linearActivity: CodexLinearActivity(sink: sink))
        let tab = UUID()
        store.upsert(tabID: tab, item: try item())
        let publications = sink.publications
        for _ in 0..<20 {
            store.appendText(tabID: tab, itemID: "reply", type: "agentMessage", field: "text", delta: "hello")
        }
        #expect(sink.publications == publications)
        store.replace(tabID: tab, items: [try item(input: #"{"id":"PLUME-500"}"#)])
        #expect(sink.evidence[tab]?.map(\.identifier) == ["PLUME-500"])
    }

    @Test func rebindingParentClearsItsPreviousConversationActivity() throws {
        let sink = CodexLinearSink()
        let store = CodexItemStore(linearActivity: CodexLinearActivity(sink: sink))
        let tab = UUID()
        store.bind(tabID: tab, threadID: "old")
        store.upsert(tabID: tab, item: try item())
        store.bind(tabID: tab, threadID: "new")
        #expect(sink.evidence[tab]?.isEmpty == true)
    }
}

@MainActor
private final class CodexLinearSink: LinearActivitySink {
    var evidence: [UUID: [LinearEvidence]] = [:]
    var publications = 0
    func replaceActivity(tabID: UUID, evidence: [LinearEvidence]) {
        self.evidence[tabID] = evidence
        publications += 1
    }
    func replaceMentions(tabID: UUID, identifiers: [String]) {}
    func forgetActivity(tabID: UUID) { evidence.removeValue(forKey: tabID) }
}
