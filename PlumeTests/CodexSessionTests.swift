import Foundation
import Testing

@testable import Plume

/// Drives `CodexSession` through its notification and request handlers with a
/// client that has no process behind it, so the mapping onto Plume's own
/// types is what gets asserted.
@MainActor
struct CodexSessionTests {
    private final class Box {
        var lines: [String] = []
    }

    private func makeSession() -> (CodexSession, CodexAppServerClient, () -> [String]) {
        let sent = Box()
        let client = CodexAppServerClient { line in
            sent.lines.append(line)
            return true
        }
        let session = CodexSession(tabID: UUID(), taskID: UUID(), client: client)
        return (session, client, { sent.lines })
    }

    @Test func aStartedThreadBecomesTheSessionID() {
        let (session, client, _) = makeSession()
        client.receive(#"{"method":"thread/started","params":{"thread":{"id":"th-1","model":"gpt-6-astra"}}}"#)
        #expect(session.sessionID == "th-1")
        #expect(session.model?.id == "gpt-6-astra")
    }

    @Test func agentMessageDeltasAccumulateAsStreamingText() {
        let (session, client, _) = makeSession()
        client.receive(#"{"method":"item/agentMessage/delta","params":{"delta":"Hel","itemId":"i","threadId":"t","turnId":"u"}}"#)
        client.receive(#"{"method":"item/agentMessage/delta","params":{"delta":"lo"}}"#)
        #expect(session.streamingText == "Hello")
    }

    @Test func reasoningDeltasLandInThinkingRatherThanProse() {
        let (session, client, _) = makeSession()
        client.receive(#"{"method":"item/reasoning/textDelta","params":{"delta":"pondering"}}"#)
        #expect(session.streamingThinking == "pondering")
        #expect(session.streamingText.isEmpty)
    }

    @Test func aTurnStartsAndFinishesWorking() {
        let (session, client, _) = makeSession()
        client.receive(#"{"method":"turn/started","params":{"threadId":"t","turn":{"id":"turn-1"}}}"#)
        #expect(session.isWorking)
        client.receive(#"{"method":"turn/completed","params":{"threadId":"t","turn":{"id":"turn-1","status":"completed"}}}"#)
        #expect(!session.isWorking)
    }

    @Test func aFailedTurnReportsItsMessage() {
        let (session, client, _) = makeSession()
        client.receive(#"{"method":"turn/completed","params":{"threadId":"t","turn":{"id":"x","status":"failed","error":{"message":"model exploded"}}}}"#)
        #expect(session.lastError == "model exploded")
        #expect(!session.isWorking)
    }

    /// A retry is the same turn still in flight, so it must not surface as a
    /// failure the user has to act on.
    @Test func aRetryableErrorDoesNotEndTheTurn() {
        let (session, client, _) = makeSession()
        client.receive(#"{"method":"turn/started","params":{"threadId":"t","turn":{"id":"turn-1"}}}"#)
        client.receive(#"{"method":"error","params":{"threadId":"t","turnId":"u","willRetry":true,"error":{"message":"429"}}}"#)
        #expect(session.isWorking)
        #expect(session.lastError == "429")
    }

    @Test func tokenUsageFeedsTheContextMeter() {
        let (session, client, _) = makeSession()
        client.receive(#"""
        {"method":"thread/tokenUsage/updated","params":{"threadId":"t","turnId":"u","tokenUsage":{"modelContextWindow":272000,"total":{"totalTokens":1234},"last":{"totalTokens":10}}}}
        """#)
        #expect(session.contextWindow == 272_000)
        #expect(session.contextUsedTokens == 1234)
    }

    @Test func aCommandApprovalBecomesAPendingPermission() {
        let (session, client, _) = makeSession()
        client.receive(#"""
        {"id":5,"method":"item/commandExecution/requestApproval","params":{"itemId":"it-1","threadId":"t","turnId":"u","startedAtMs":0,"command":"ls -la","reason":"needs approval"}}
        """#)
        let permission = try? #require(session.pendingPermissions.first)
        #expect(permission?.id == "it-1")
        #expect(permission?.description == "ls -la")
        #expect(permission?.decisionReason == "needs approval")
    }

    @Test func answeringAnApprovalRepliesToItsRequestAndClearsTheRow() throws {
        let (session, client, sent) = makeSession()
        client.receive(#"""
        {"id":5,"method":"item/commandExecution/requestApproval","params":{"itemId":"it-1","threadId":"t","turnId":"u","startedAtMs":0,"command":"ls"}}
        """#)
        let permission = try #require(session.pendingPermissions.first)
        session.resolve(permission, with: .allow(updatedInput: [:]))

        let reply = try #require(sent().last)
        #expect(reply.contains("\"decision\":\"accept\""))
        #expect(reply.contains("\"id\":5"))
        #expect(session.pendingPermissions.isEmpty)
    }

    /// Codex's decisions carry no free text, so a reason has nowhere to go and
    /// a denial is just `decline`.
    @Test func denyingAnApprovalSendsDeclineWithoutTheReason() throws {
        let (session, client, sent) = makeSession()
        client.receive(#"""
        {"id":6,"method":"item/commandExecution/requestApproval","params":{"itemId":"it-2","threadId":"t","turnId":"u","startedAtMs":0,"command":"rm -rf /"}}
        """#)
        let permission = try #require(session.pendingPermissions.first)
        session.resolve(permission, with: .deny(message: "absolutely not"))

        let reply = try #require(sent().last)
        #expect(reply.contains("\"decision\":\"decline\""))
        #expect(!reply.contains("absolutely not"))
    }

    /// An unanswered server request stalls the turn, so anything unimplemented
    /// still gets a reply.
    @Test func anUnsupportedServerRequestIsRefusedRatherThanIgnored() throws {
        let (session, client, sent) = makeSession()
        _ = session
        client.receive(#"{"id":8,"method":"item/tool/call","params":{}}"#)
        let reply = try #require(sent().last)
        #expect(reply.contains("\"error\""))
    }

    @Test func aResolvedRequestDropsItsPendingRow() throws {
        let (session, client, _) = makeSession()
        client.receive(#"""
        {"id":7,"method":"item/commandExecution/requestApproval","params":{"itemId":"it-3","threadId":"t","turnId":"u","startedAtMs":0,"command":"ls"}}
        """#)
        #expect(session.pendingPermissions.count == 1)
        client.receive(#"{"method":"serverRequest/resolved","params":{"requestId":7,"threadId":"t"}}"#)
        #expect(session.pendingPermissions.isEmpty)
    }

    @Test func messagesTypedBeforeTheThreadExistsAreQueued() {
        let (session, _, _) = makeSession()
        session.submit(text: "first")
        #expect(session.queuedMessages == ["first"])
    }

    @Test func aCodexSessionOffersNoPlanApproval() {
        let (session, _, _) = makeSession()
        #expect(!session.supportsPlanApproval)
        #expect(session.sessionCostUSD == nil)
    }
}
