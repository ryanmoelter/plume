import Foundation
import Testing
@testable import Plume

@MainActor
struct CodexItemStoreTests {
    @Test func completedPlanIsDockedAndRemainsInChatHistory() throws {
        let store = CodexItemStore()
        let tabID = UUID()
        store.upsert(tabID: tabID, item: item([
            "id": .string("proposal"), "type": .string("plan"),
            "text": .string("# Parser\n\nAdd the parser")
        ]), turnID: "turn", lifecycle: .completed)

        #expect(store.transcript(forTab: tabID)?.messages.first?.blocks == [
            .markdown("## Plan\n\n# Parser\n\nAdd the parser")
        ])
        #expect(store.latestPendingPlan(forTab: tabID) == .init(
            id: "turn#proposal", markdown: "# Parser\n\nAdd the parser"
        ))
    }

    @Test func historyPlanWithoutAStatusRestoresAsPending() throws {
        let store = CodexItemStore()
        let tabID = UUID()
        store.mergeHistory(tabID: tabID, entries: [.object([
            "turnId": .string("planning"),
            "item": .object([
                "id": .string("proposal"),
                "type": .string("plan"),
                "text": .string("# Recovered plan\n\nMake the change")
            ])
        ])], since: store.revision(forTab: tabID))

        #expect(store.latestPendingPlan(forTab: tabID) == .init(
            id: "planning#proposal",
            markdown: "# Recovered plan\n\nMake the change"
        ))
        #expect(store.transcript(forTab: tabID)?.messages.first?.blocks == [
            .markdown("## Plan\n\n# Recovered plan\n\nMake the change")
        ])
    }

    @Test func aLaterUserTurnKeepsAnOldPlanFromResurrecting() {
        let store = CodexItemStore()
        let tabID = UUID()
        store.upsert(tabID: tabID, item: item([
            "id": .string("proposal"), "type": .string("plan"), "text": .string("Do it")
        ]), turnID: "one", lifecycle: .completed)
        store.upsert(tabID: tabID, item: item([
            "id": .string("answer"), "type": .string("userMessage"),
            "content": .array([.object(["type": .string("text"), "text": .string("Implement")])])
        ]), turnID: "two", lifecycle: .completed)

        #expect(store.latestPendingPlan(forTab: tabID) == nil)
    }

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

    @Test func historyUnwrapsEntriesAndPreservesUpdatesDuringPagination() throws {
        let store = CodexItemStore()
        let tabID = UUID()
        store.upsert(tabID: tabID, item: item([
            "id": .string("a"), "type": .string("agentMessage"), "text": .string("old cache")
        ]))
        let revision = store.revision(forTab: tabID)
        store.upsert(tabID: tabID, item: item([
            "id": .string("b"), "type": .string("agentMessage"), "text": .string("newer live text")
        ]))
        store.upsert(tabID: tabID, item: item([
            "id": .string("tool"), "type": .string("commandExecution"), "command": .string("ls")
        ]))
        store.mergeHistory(tabID: tabID, entries: [
            item(["turnId": .string("turn"), "item": item([
                "id": .string("a"), "type": .string("agentMessage"), "text": .string("restored")
            ])]),
            item(["turnId": .string("turn"), "item": item([
                "id": .string("b"), "type": .string("agentMessage"), "text": .string("older page text")
            ])])
        ], since: revision)
        let transcript = try #require(store.transcript(forTab: tabID))
        #expect(transcript.messages.map(\.id) == ["turn#a", "turn#b", "tool"])
        #expect(transcript.messages[0].blocks == [.markdown("restored")])
        #expect(transcript.messages[1].blocks == [.markdown("newer live text")])
    }

    @Test func startedRowsKeepTheirPositionWhenCompletedInReverseOrder() throws {
        let store = CodexItemStore()
        let tabID = UUID()
        store.upsert(tabID: tabID, item: item([
            "id": .string("a"), "type": .string("agentMessage"), "text": .string("")
        ]))
        store.upsert(tabID: tabID, item: item([
            "id": .string("tool"), "type": .string("commandExecution"), "command": .string("ls")
        ]))
        store.appendText(tabID: tabID, itemID: "a", type: "agentMessage", field: "text", delta: "Checking")
        store.upsert(tabID: tabID, item: item([
            "id": .string("tool"), "type": .string("commandExecution"), "command": .string("ls"),
            "aggregatedOutput": .string("done")
        ]))
        store.upsert(tabID: tabID, item: item([
            "id": .string("a"), "type": .string("agentMessage"), "text": .string("Checking files")
        ]))
        let transcript = try #require(store.transcript(forTab: tabID))
        #expect(transcript.messages.map(\.id) == ["a", "tool"])
        #expect(transcript.messages[0].blocks == [.markdown("Checking files")])
    }

    @Test func historyMergeKeepsMissingLiveRowsBeforeTheirLaterNeighbors() throws {
        let store = CodexItemStore()
        let tabID = UUID()
        let revision = store.revision(forTab: tabID)
        for id in ["prose", "reasoning", "tool", "final"] {
            store.appendText(tabID: tabID, itemID: id, type: "agentMessage", field: "text", delta: id)
        }
        let liveRevision = store.revision(forTab: tabID)
        store.mergeHistory(tabID: tabID, entries: [
            item(["id": .string("old"), "type": .string("agentMessage"), "text": .string("History")]),
            item(["id": .string("tool"), "type": .string("agentMessage"), "text": .string("Stale")])
        ], since: revision)
        let transcript = try #require(store.transcript(forTab: tabID))
        #expect(transcript.messages.map(\.id) == ["old", "prose", "reasoning", "tool", "final"])
        #expect(transcript.messages[3].blocks == [.markdown("tool")])
        #expect(store.revision(forTab: tabID) == liveRevision)

        // A second pending history request must still recognize the same
        // notifications as newer, even after the first merge finishes, while
        // retaining the history already loaded.
        store.mergeHistory(tabID: tabID, entries: [], since: revision)
        #expect(store.transcript(forTab: tabID)?.messages.map(\.id) == ["old", "prose", "reasoning", "tool", "final"])
        store.appendText(tabID: tabID, itemID: "final", type: "agentMessage", field: "text", delta: " updated")
        #expect(store.revision(forTab: tabID) > liveRevision)
    }

    @Test func itemIDsAreStableWhenTurnsReuseAnItemID() throws {
        let store = CodexItemStore()
        let tabID = UUID()
        store.upsert(tabID: tabID, item: item([
            "id": .string("same"), "type": .string("agentMessage"), "text": .string("one")
        ]), turnID: "turn-1", lifecycle: .completed)
        store.upsert(tabID: tabID, item: item([
            "id": .string("same"), "type": .string("agentMessage"), "text": .string("two")
        ]), turnID: "turn-2", lifecycle: .completed)

        let messages = try #require(store.transcript(forTab: tabID)).messages
        #expect(messages.map(\.id) == ["turn-1#same", "turn-2#same"])
        #expect(messages.map { $0.blocks } == [[.markdown("one")], [.markdown("two")]])
    }

    @Test func streamBeforeStartAndCompletionRemainsMonotonic() throws {
        let store = CodexItemStore()
        let tabID = UUID()
        store.appendText(tabID: tabID, itemID: "item", turnID: "turn", type: "agentMessage", field: "text", delta: "partial")
        store.upsert(tabID: tabID, item: item([
            "id": .string("item"), "type": .string("agentMessage"), "text": .string("complete")
        ]), turnID: "turn", lifecycle: .completed)
        // A delayed started event and delta must not rewind a completed row.
        store.upsert(tabID: tabID, item: item([
            "id": .string("item"), "type": .string("agentMessage"), "text": .string("")
        ]), turnID: "turn", lifecycle: .started)
        store.appendText(tabID: tabID, itemID: "item", turnID: "turn", type: "agentMessage", field: "text", delta: " stale")

        let messages = try #require(store.transcript(forTab: tabID)).messages
        #expect(messages.map(\.id) == ["turn#item"])
        #expect(messages.first?.blocks == [.markdown("complete")])
    }

    @Test func onlyUnfinishedLiveItemsAreMarkedForReveal() throws {
        let store = CodexItemStore()
        let tabID = UUID()
        store.upsert(tabID: tabID, item: item([
            "id": .string("live"), "type": .string("agentMessage"), "text": .string("Streaming")
        ]), lifecycle: .started)
        store.upsert(tabID: tabID, item: item([
            "id": .string("done"), "type": .string("agentMessage"), "text": .string("Finished")
        ]), lifecycle: .completed)
        store.mergeHistory(tabID: tabID, entries: [item([
            "turnId": .string("old"), "item": item([
                "id": .string("history"), "type": .string("agentMessage"), "text": .string("Earlier")
            ])
        ])], since: store.revision(forTab: tabID))

        let messages = try #require(store.transcript(forTab: tabID)?.messages)
        #expect(messages.first { $0.id == "live" }?.isLive == true)
        #expect(messages.first { $0.id == "done" }?.isLive == false)
        #expect(messages.first { $0.id == "old#history" }?.isLive == false)
    }

    @Test func historyPagesStayOrderedAroundInterleavedLiveRows() throws {
        let store = CodexItemStore()
        let tabID = UUID()
        let revision = store.revision(forTab: tabID)
        store.mergeHistory(tabID: tabID, entries: [
            item(["turnId": .string("old-1"), "item": item([
                "id": .string("same"), "type": .string("agentMessage"), "text": .string("first")
            ])])
        ], since: revision)
        store.appendText(tabID: tabID, itemID: "live", turnID: "new", type: "agentMessage", field: "text", delta: "live")
        store.mergeHistory(tabID: tabID, entries: [
            item(["turnId": .string("old-2"), "item": item([
                "id": .string("same"), "type": .string("agentMessage"), "text": .string("second")
            ])])
        ], since: revision)

        let messages = try #require(store.transcript(forTab: tabID)).messages
        #expect(messages.map(\.id) == ["old-1#same", "old-2#same", "new#live"])
    }

    private func item(_ fields: [String: JSONValue]) -> JSONValue { .object(fields) }
}
