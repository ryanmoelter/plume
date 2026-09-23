import Foundation
import Testing

@testable import Plume

@MainActor
struct CodexSubagentStoreTests {
    @Test func historicalStartDoesNotAssertActivityUntilLiveStatusConfirmsIt() {
        let store = CodexSubagentStore()
        let tabID = UUID()
        store.receiveParentItem(tabID: tabID, taskID: UUID(), item: .object([
            "type": .string("subAgentActivity"), "agentThreadId": .string("child"),
            "kind": .string("started")
        ]), historical: true)
        #expect(store.subagents(forTab: tabID).first?.status == .notStarted)
        store.receiveThreadMetadata(tabID: tabID, threadID: "child", thread: .object([
            "status": .object(["type": .string("active")])
        ]))
        #expect(store.subagents(forTab: tabID).first?.status == .working)
        store.connectionClosed(tabID: tabID)
        #expect(store.subagents(forTab: tabID).first?.status == .interrupted)
    }

    @Test func activityDiscoversAChildAndDrivesItsLifecycle() throws {
        let store = CodexSubagentStore()
        let tabID = UUID()
        let taskID = UUID()

        let discovered = store.receiveParentItem(tabID: tabID, taskID: taskID, item: .object([
            "id": .string("activity-1"), "type": .string("subAgentActivity"),
            "agentThreadId": .string("child-1"), "agentPath": .string("reviewer"),
            "kind": .string("started")
        ]))

        #expect(discovered == ["child-1"])
        var child = try #require(store.subagents(forTab: tabID).first)
        #expect(child.id == "child-1")
        #expect(child.title == "reviewer")
        #expect(child.status == .working)
        #expect(child.provider == .codex)

        _ = store.receiveParentItem(tabID: tabID, taskID: taskID, item: .object([
            "id": .string("activity-2"), "type": .string("subAgentActivity"),
            "agentThreadId": .string("child-1"), "agentPath": .string("reviewer"),
            "kind": .string("completed")
        ]))
        child = try #require(store.subagents(forTab: tabID).first)
        #expect(child.status == .done)
    }

    @Test func legacyCollaborationItemSuppliesPromptModelAndStatus() throws {
        let store = CodexSubagentStore()
        let tabID = UUID()
        _ = store.receiveParentItem(tabID: tabID, taskID: UUID(), item: .object([
            "id": .string("spawn-1"), "type": .string("collabAgentToolCall"),
            "receiverThreadIds": .array([.string("child-2")]),
            "prompt": .string("Inspect the parser"), "model": .string("gpt-6-astra"),
            "agentsStates": .object(["child-2": .object(["status": .string("running")])])
        ]))

        let child = try #require(store.subagents(forTab: tabID).first)
        #expect(child.title == "Inspect the parser")
        #expect(child.transcript.model == "gpt-6-astra")
        #expect(child.status == .working)
    }

    @Test func childHistoryUsesASeparateItemTable() throws {
        let store = CodexSubagentStore()
        let tabID = UUID()
        let revision = store.revision(tabID: tabID, threadID: "child")
        store.receiveChildItem(tabID: tabID, threadID: "child", item: .object([
            "id": .string("live"), "type": .string("agentMessage"), "text": .string("Live")
        ]), turnID: "turn-2", lifecycle: .started)
        store.mergeHistory(tabID: tabID, threadID: "child", entries: [.object([
            "turnId": .string("turn-1"),
            "item": .object(["id": .string("old"), "type": .string("userMessage"), "content": .array([.object(["type": .string("text"), "text": .string("Old")])])])
        ])], since: revision)

        let child = try #require(store.subagents(forTab: tabID).first)
        #expect(child.transcript.messages.map(\.id) == ["turn-1#old", "turn-2#live"])
        #expect(CodexItemStore.shared.transcript(forTab: tabID) == nil)
    }

    @Test func threadReadMetadataUsesNestedSubagentSourceAndTopLevelIdentity() throws {
        let store = CodexSubagentStore()
        let tabID = UUID()
        store.receiveThreadMetadata(tabID: tabID, threadID: "child", thread: .object([
            "agentNickname": .string("Ada"), "agentRole": .string("reviewer"),
            "model": .string("gpt-5.6-luna"),
            "status": .object(["type": .string("idle")]),
            "source": .object(["subAgent": .object(["thread_spawn": .object([
                "agent_path": .array([.string("root"), .string("reviewer")]),
                "depth": .number(1), "parent_thread_id": .string("parent")
            ])])])
        ]))

        let child = try #require(store.subagents(forTab: tabID).first)
        #expect(child.title == "reviewer: Ada")
        #expect(child.transcript.model == "gpt-5.6-luna")
        #expect(child.status == .done)
    }

    @Test func hydrationFailureIsVisibleAndForgetClearsTheTab() throws {
        struct Failure: Error, LocalizedError { var errorDescription: String? { "history unavailable" } }
        let store = CodexSubagentStore()
        let tabID = UUID()
        store.hydrationFailed(tabID: tabID, threadID: "child", error: Failure())
        let child = try #require(store.subagents(forTab: tabID).first)
        #expect(child.transcript.messages.first?.role == .notice)
        store.forget(tabID: tabID)
        #expect(store.subagents(forTab: tabID).isEmpty)
    }

    @Test func staleMetadataAndHistoricalParentItemsDoNotRollBackLiveStatus() throws {
        let store = CodexSubagentStore()
        let tabID = UUID()
        let taskID = UUID()
        _ = store.receiveParentItem(tabID: tabID, taskID: taskID, item: .object([
            "type": .string("subAgentActivity"), "id": .string("start"),
            "agentThreadId": .string("child"), "agentPath": .string("worker"), "kind": .string("started")
        ]))
        let revision = store.lifecycleRevision(tabID: tabID, threadID: "child")
        store.receiveThreadMetadata(tabID: tabID, threadID: "child", thread: .object([
            "status": .object(["type": .string("idle")])
        ]))
        store.receiveThreadMetadata(tabID: tabID, threadID: "child", thread: .object([
            "status": .object(["type": .string("active")])
        ]), since: revision)
        _ = store.receiveParentItem(tabID: tabID, taskID: taskID, item: .object([
            "type": .string("subAgentActivity"), "id": .string("old"),
            "agentThreadId": .string("child"), "agentPath": .string("worker"), "kind": .string("started")
        ]), historical: true)

        #expect(try #require(store.subagents(forTab: tabID).first).status == .done)
    }

    @Test func cachedChildIsReturnedAgainForReconnectHydration() {
        let store = CodexSubagentStore()
        let tabID = UUID()
        let taskID = UUID()
        let item: JSONValue = .object([
            "type": .string("subAgentActivity"), "id": .string("activity"),
            "agentThreadId": .string("child"), "agentPath": .string("worker"),
            "kind": .string("completed")
        ])

        #expect(store.receiveParentItem(tabID: tabID, taskID: taskID, item: item) == ["child"])
        #expect(store.receiveParentItem(tabID: tabID, taskID: taskID, item: item, historical: true) == ["child"])
    }

    @Test func recoveredWaitCompletionSurvivesUnloadedThreadMetadata() throws {
        let store = CodexSubagentStore()
        let tabID = UUID()
        let taskID = UUID()
        func call(_ status: String) -> JSONValue {
            .object([
                "type": .string("collabAgentToolCall"), "id": .string(status),
                "receiverThreadIds": .array([.string("child")]),
                "agentsStates": .object(["child": .object(["status": .string(status)])])
            ])
        }

        _ = store.receiveParentItem(tabID: tabID, taskID: taskID, item: call("running"), historical: true)
        _ = store.receiveParentItem(tabID: tabID, taskID: taskID, item: call("completed"), historical: true)
        store.receiveThreadMetadata(tabID: tabID, threadID: "child", thread: .object([
            "status": .object(["type": .string("notLoaded")])
        ]), since: store.lifecycleRevision(tabID: tabID, threadID: "child"))

        #expect(try #require(store.subagents(forTab: tabID).first).status == .done)
    }
}
