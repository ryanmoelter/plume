import Foundation
import Testing
@testable import Plume

struct LinearActivityScannerTests {
    private func message(_ calls: ToolCall...) -> ChatMessage {
        ChatMessage(id: "m", role: .assistant, blocks: calls.map { .toolCall($0) }, timestamp: nil)
    }

    private func call(_ name: String, _ input: String, result: String? = nil) -> ToolCall {
        var call = ToolCall(id: UUID().uuidString, name: name, summary: ToolCallSummary(name: name, detail: nil), input: .json(input))
        call.result = result
        return call
    }

    private let sub = LinearSubagentRef(id: "a1", label: "Explore")

    @Test func serverNameVariantsAreRecognized() {
        for name in ["mcp__plume-linear__get_issue", "mcp__claude_ai_Linear__get_issue", "mcp__linear__get_issue"] {
            let found = LinearActivityScanner.scan([message(call(name, #"{"id": "PLUME-7"}"#))], subagent: nil)
            #expect(found == [LinearEvidence(identifier: "PLUME-7", tool: "get_issue", requestedState: nil, subagent: nil)], "\(name)")
        }
    }

    @Test func nonLinearToolsAreIgnored() {
        let found = LinearActivityScanner.scan([message(
            call("mcp__notion__get_issue", #"{"id": "PLUME-7"}"#),
            call("Bash", #"{"id": "PLUME-7"}"#)
        )], subagent: nil)
        #expect(found.isEmpty)
    }

    @Test func saveIssueCapturesRequestedState() {
        let found = LinearActivityScanner.scan([message(
            call("mcp__plume-linear__save_issue", #"{"id": "PLUME-231", "state": "In Progress"}"#)
        )], subagent: nil)
        #expect(found.first?.requestedState == "In Progress")
        #expect(found.first?.tool == "save_issue")
    }

    @Test func createdIssueComesFromResult() {
        let result = #"{"id":"PLUME-131","uuid":"925ea779-451c-4723-b755-e0828e5912c3","title":"T"}"#
        let found = LinearActivityScanner.scan([message(
            call("mcp__plume-linear__save_issue", #"{"team": "Plume", "state": "Backlog", "title": "T"}"#, result: result)
        )], subagent: nil)
        #expect(found.map(\.identifier) == ["PLUME-131"])
        #expect(found.first?.requestedState == "Backlog")
    }

    @Test func uuidInputResolvesThroughResult() {
        let found = LinearActivityScanner.scan([message(
            call("mcp__linear__update_issue", #"{"id": "925ea779-451c-4723-b755-e0828e5912c3"}"#, result: #"{"identifier":"DROID-4"}"#)
        )], subagent: nil)
        #expect(found.map(\.identifier) == ["DROID-4"])
    }

    @Test func listAndSearchResultsAreIgnored() {
        let result = #"[{"id":"PLUME-1"},{"id":"PLUME-2"}]"#
        let found = LinearActivityScanner.scan([message(
            call("mcp__plume-linear__list_issues", #"{"team": "Plume"}"#, result: result),
            call("mcp__plume-linear__search_documentation", #"{"query": "x"}"#, result: result)
        )], subagent: nil)
        #expect(found.isEmpty)
    }

    @Test func commentsCountAsMentions() {
        let found = LinearActivityScanner.scan([message(
            call("mcp__plume-linear__save_comment", #"{"issueId": "PLUME-148", "body": "hi"}"#)
        )], subagent: nil)
        #expect(found.map(\.identifier) == ["PLUME-148"])
        #expect(found.first?.requestedState == nil)
    }

    @Test func subagentIsTagged() {
        let found = LinearActivityScanner.scan([message(
            call("mcp__linear__get_issue", #"{"id": "PLUME-7"}"#)
        )], subagent: sub)
        #expect(found.first?.subagent == sub)
    }

    @Test func malformedInputIsSkipped() {
        let found = LinearActivityScanner.scan([message(
            call("mcp__linear__get_issue", "not json"),
            call("mcp__linear__get_issue", #"{"id": "nonsense"}"#)
        )], subagent: nil)
        #expect(found.isEmpty)
    }
}
