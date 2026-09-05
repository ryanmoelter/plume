import Foundation
import Testing
@testable import Plume

@MainActor
struct CodexItemStoreTests {
    @Test func historyKeepsServerOrderAndReplacesItemsByID() throws {
        let store = CodexItemStore()
        let tabID = UUID()
        store.replace(tabID: tabID, items: [
            item(["id": .string("u"), "type": .string("userMessage"), "content": .array([
                .object(["type": .string("text"), "text": .string("hello")])
            ])]),
            item(["id": .string("a"), "type": .string("agentMessage"), "text": .string("old")])
        ])
        store.upsert(tabID: tabID, item: item([
            "id": .string("a"), "type": .string("agentMessage"), "text": .string("new")
        ]))

        let transcript = try #require(store.transcript(forTab: tabID))
        #expect(transcript.messages.map(\.id) == ["u", "a"])
        #expect(transcript.messages.last?.blocks == [.markdown("new")])
    }

    @Test func commandAndFileItemsBecomeTypedToolRows() throws {
        let store = CodexItemStore()
        let tabID = UUID()
        store.replace(tabID: tabID, items: [
            item([
                "id": .string("command"), "type": .string("commandExecution"),
                "command": .string("swift test"), "aggregatedOutput": .string("ok"),
                "exitCode": .number(0)
            ]),
            item([
                "id": .string("edit"), "type": .string("fileChange"),
                "status": .string("completed"), "changes": .array([.object([
                    "path": .string("a.swift"), "kind": .string("update"),
                    "diff": .string("@@ -1 +1 @@\n-old\n+new")
                ])])
            ])
        ])

        let messages = try #require(store.transcript(forTab: tabID)).messages
        guard case .toolCall(let command) = messages[0].blocks[0],
              case .toolCall(let edit) = messages[1].blocks[0],
              case .diff(let diff) = edit.input
        else { Issue.record("Expected typed tool calls"); return }
        #expect(command.name == "Bash")
        #expect(command.result?.contains("ok") == true)
        #expect(diff.addedCount == 1)
        #expect(diff.removedCount == 1)
    }

    @Test func missingFileChangeStillHasSafeEmptyApprovalInput() {
        let store = CodexItemStore()
        #expect(store.fileChangeInput(tabID: UUID(), itemID: "missing").isEmpty)
    }

    private func item(_ fields: [String: JSONValue]) -> JSONValue { .object(fields) }
}
