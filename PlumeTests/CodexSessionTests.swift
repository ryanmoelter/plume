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

    @Test func alreadyHydratedChildRefreshesBackgroundWorkAfterCommandsAndTurnCompletion() async throws {
        @MainActor final class Harness {
            var client: CodexAppServerClient!
            var inventories: [String: [String]] = [:]
            var childHistoryReads = 0
            init() {
                client = CodexAppServerClient { [weak self] line in
                    guard let self,
                          let request = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)),
                          let id = request["id"], let method = request["method"]?.stringValue else { return true }
                    let threadID = request["params"]?["threadId"]?.stringValue ?? "parent"
                    let result: JSONValue
                    switch method {
                    case "thread/start", "thread/read":
                        result = .object(["thread": .object(["id": .string(threadID)])])
                    case "thread/backgroundTerminals/list":
                        result = .object(["data": .array((inventories[threadID] ?? []).map {
                            .object(["processId": .string($0)])
                        })])
                    default:
                        if method == "thread/items/list", threadID == "child" { childHistoryReads += 1 }
                        result = .object(["data": .array([])])
                    }
                    let response = try! JSONEncoder().encode(JSONValue.object(["id": id, "result": result]))
                    client.receive(String(decoding: response, as: UTF8.self))
                    return true
                }
            }
        }
        let h = Harness()
        let session = CodexSession(tabID: UUID(), taskID: UUID(), client: h.client)
        defer {
            session.stop()
            CodexSubagentStore.shared.forget(tabID: session.tabID)
            CodexItemStore.shared.forget(tabID: session.tabID)
        }
        session.start(workingDirectory: nil, resumeThreadID: nil, model: nil, environment: [:])
        try await waitUntil { session.sessionID == "parent" }
        h.client.receive(#"{"method":"item/started","params":{"threadId":"parent","item":{"id":"spawn","type":"subAgentActivity","agentThreadId":"child","kind":"started"}}}"#)
        h.client.receive(#"{"method":"turn/started","params":{"threadId":"child","turn":{"id":"child-turn"}}}"#)
        try await waitUntil { h.childHistoryReads == 1 }
        #expect(BackgroundTaskTracker.shared.inFlight(tabID: session.tabID).isEmpty)

        // The first inventory was empty. A later command must acquire a hold
        // without relying on hydration (which runs once) or an existing poll.
        h.inventories["child"] = ["process"]
        h.client.receive(#"{"method":"item/started","params":{"threadId":"child","turnId":"child-turn","item":{"id":"command","type":"commandExecution","command":"sleep 30","status":"inProgress"}}}"#)
        try await waitUntil { BackgroundTaskTracker.shared.inFlight(tabID: session.tabID).map(\.id) == ["child/process"] }
        h.inventories["child"] = []
        h.client.receive(#"{"method":"turn/completed","params":{"threadId":"child","turn":{"id":"child-turn","status":"completed"}}}"#)
        try await waitUntil { BackgroundTaskTracker.shared.inFlight(tabID: session.tabID).isEmpty }
        #expect(h.childHistoryReads == 1)
    }

    @Test func startupFailureUsesCodexAndCanOfferInstallation() throws {
        let (session, client, _) = makeSession()
        #expect(session.startFailure == nil)
        client.onExit?(127, "zsh: command not found: codex")
        let failure = try #require(session.startFailure)
        #expect(failure.title == "Codex isn't on PATH")
        #expect(failure.remedy == .installCLI)
    }

    @Test func unsolicitedCleanExitStillReportsCodexDisconnect() throws {
        let (session, client, _) = makeSession()
        client.onExit?(0, nil)
        let failure = try #require(session.startFailure)
        #expect(failure.title == "Codex couldn't start")
        #expect(failure.remedy == .retry)
    }

    @Test func intentionalStopWithoutAnErrorIsNotAStartupFailure() {
        let (session, _, _) = makeSession()
        session.stop()
        #expect(session.startFailure == nil)
    }

    @Test func initializeOptsIntoTheExperimentalThreadAPI() {
        #expect(CodexSession.initializeCapabilities["experimentalApi"] == .bool(true))
    }

    @Test func aThreadNotificationCannotChooseTheSessionsIdentity() {
        let (session, client, _) = makeSession()
        client.receive(#"{"method":"thread/started","params":{"thread":{"id":"th-1","model":"gpt-6-astra"}}}"#)
        #expect(session.sessionID == nil)
        #expect(session.model == nil)
    }

    @Test func handshakePublishesIdentityButWaitsForHistoryBeforeSending() async throws {
        let (session, client, sent) = makeSession()
        defer {
            session.stop()
            CodexItemStore.shared.forget(tabID: session.tabID)
            CodexSubagentStore.shared.forget(tabID: session.tabID)
            CodexCatalogStore.shared.forget(tabID: session.tabID)
            TabDirectoryStore.shared.forget(tabID: session.tabID)
        }
        session.start(
            workingDirectory: "/tmp/project",
            resumeThreadID: "persisted-thread",
            model: nil,
            collaborationMode: .plan,
            environment: [:]
        )
        session.submit(text: "queued while loading")

        var cursor = 0
        try await answer("initialize", result: .object([:]), client: client, sent: sent, cursor: &cursor)
        try await answer("account/rateLimits/read", result: .object([:]), client: client, sent: sent, cursor: &cursor)
        try await answer("model/list", result: .object(["data": .array([])]), client: client, sent: sent, cursor: &cursor)
        try await answer("permissionProfile/list", result: .object(["data": .array([])]), client: client, sent: sent, cursor: &cursor)
        try await answer("thread/resume", result: .object([
            "model": .string("gpt-6-astra"),
            "reasoningEffort": .string("high"),
            "thread": .object([
                "id": .string("persisted-thread"),
                "cwd": .string("/tmp/project-worktree"),
                "model": .string("stale-nested-model"),
                "reasoningEffort": .string("low")
            ])
        ]), client: client, sent: sent, cursor: &cursor)

        try await waitUntil { session.sessionID == "persisted-thread" }
        #expect(TabDirectoryStore.shared.directory(forTab: session.tabID) == "/tmp/project-worktree")
        #expect(session.model?.id == "gpt-6-astra")
        #expect(session.effort == .high)
        #expect(!sent().contains { requestMethod(in: $0) == "turn/start" })

        client.receive(#"{"method":"thread/started","params":{"thread":{"id":"child-thread","source":{"subAgent":{"thread_spawn":{"parent_thread_id":"persisted-thread"}}}}}}"#)

        // Child approval traffic shares this app-server. Cache its patch for
        // the approval row without allowing the child item into the root chat.
        client.receive(#"{"method":"item/started","params":{"threadId":"child-thread","turnId":"child-turn","item":{"id":"child-edit","type":"fileChange","changes":[{"path":"child.swift","diff":"@@ -1 +1 @@\\n-old\\n+new"}]}}}"#)
        client.receive(#"{"method":"item/started","params":{"threadId":"child-thread","turnId":"child-turn","item":{"id":"child-message","type":"agentMessage","text":""}}}"#)
        client.receive(#"{"method":"item/agentMessage/delta","params":{"threadId":"child-thread","turnId":"child-turn","itemId":"child-message","delta":"Child reply"}}"#)
        client.receive(#"{"method":"item/agentMessage/delta","params":{"threadId":"child-thread","turnId":"child-turn","itemId":"child-message","delta":" once"}}"#)
        try await waitUntil { sent().filter { requestMethod(in: $0) == "thread/read" }.count == 1 }
        #expect(sent().filter { requestMethod(in: $0) == "thread/read" }.count == 1)
        #expect(CodexSubagentStore.shared.subagents(forTab: session.tabID).first?.transcript.messages.last?.blocks == [.markdown("Child reply once")])
        #expect(CodexItemStore.shared.transcript(forTab: session.tabID)?.messages.contains { $0.id.contains("child-message") } != true)
        client.receive(#"{"id":"child-approval","method":"item/fileChange/requestApproval","params":{"threadId":"child-thread","turnId":"child-turn","itemId":"child-edit","reason":"child edit"}}"#)
        let childPermission = try #require(session.pendingPermissions.first)
        #expect(childPermission.agentID == "child-thread")
        #expect(childPermission.toolUseID == "child-turn#child-edit")
        #expect(childPermission.input["changes"]?.arrayValue?.first?["path"] == .string("child.swift"))
        client.receive(#"{"method":"serverRequest/resolved","params":{"threadId":"child-thread","requestId":"child-approval"}}"#)
        #expect(session.pendingPermissions.isEmpty)

        // This live row lands while history is outstanding. The item store's
        // revision merge keeps it after the authoritative page arrives.
        client.receive(#"{"method":"item/started","params":{"threadId":"persisted-thread","turnId":"live-turn","item":{"id":"live","type":"agentMessage","text":"Live"}}}"#)
        try await answer("thread/items/list", result: .object([
            "data": .array([.object([
                "turnId": .string("old-turn"),
                "item": .object(["id": .string("old"), "type": .string("userMessage"), "content": .array([.object(["type": .string("text"), "text": .string("Old")])])])
            ])])
        ]), client: client, sent: sent, cursor: &cursor)

        try await waitUntil { sent().contains { requestMethod(in: $0) == "turn/start" } }
        let turnLine = try #require(sent().first { requestMethod(in: $0) == "turn/start" })
        let turnParams = try #require(decodedObject(turnLine)?["params"])
        #expect(turnParams["collaborationMode"]?["mode"] == .string("plan"))
        #expect(turnParams["collaborationMode"]?["settings"]?["model"] == .string("gpt-6-astra"))
        #expect(turnParams["collaborationMode"]?["settings"]?["reasoning_effort"] == .string("high"))
        #expect(turnParams["collaborationMode"]?["settings"]?["developer_instructions"] == .null)
        #expect(CodexItemStore.shared.transcript(forTab: session.tabID)?.messages.map(\.id) == ["old-turn#old", "live-turn#live"])
    }

    @Test func agentMessageDeltasStayBeforeToolsWithoutADuplicateOverlay() throws {
        let (session, client, _) = makeSession()
        defer { CodexItemStore.shared.forget(tabID: session.tabID) }
        client.receive(#"{"method":"item/started","params":{"turnId":"u","item":{"id":"i","type":"agentMessage","text":""}}}"#)
        client.receive(#"{"method":"item/agentMessage/delta","params":{"delta":"Hel","itemId":"i","threadId":"t","turnId":"u"}}"#)
        client.receive(#"{"method":"item/started","params":{"turnId":"u","item":{"id":"tool","type":"commandExecution","command":"ls"}}}"#)
        client.receive(#"{"method":"item/agentMessage/delta","params":{"delta":"lo","itemId":"i","turnId":"u"}}"#)
        let live = try #require(CodexItemStore.shared.transcript(forTab: session.tabID))
        #expect(live.messages.map(\.id) == ["u#i", "u#tool"])
        #expect(live.messages.first?.blocks == [.markdown("Hello")])
        #expect(session.streamingText.isEmpty)

        client.receive(#"{"method":"item/completed","params":{"turnId":"u","item":{"id":"i","type":"agentMessage","text":"Hello"}}}"#)
        client.receive(#"{"method":"item/started","params":{"turnId":"u","item":{"id":"final","type":"agentMessage","text":""}}}"#)
        client.receive(#"{"method":"item/agentMessage/delta","params":{"delta":"Done","itemId":"final","turnId":"u"}}"#)
        let completed = try #require(CodexItemStore.shared.transcript(forTab: session.tabID))
        #expect(completed.messages.map(\.id) == ["u#i", "u#tool", "u#final"])
        #expect(completed.messages.first?.blocks == [.markdown("Hello")])
        #expect(completed.messages.last?.blocks == [.markdown("Done")])
        #expect(session.streamingText.isEmpty)
    }

    @Test func reasoningDeltasPreserveIndexedPartsInTheirOwnRow() throws {
        let (session, client, _) = makeSession()
        defer { CodexItemStore.shared.forget(tabID: session.tabID) }
        client.receive(#"{"method":"item/reasoning/textDelta","params":{"itemId":"r","contentIndex":0,"delta":"pondering"}}"#)
        #expect(CodexItemStore.shared.transcript(forTab: session.tabID)?.messages.first?.blocks == [.thinking("pondering")])
        client.receive(#"{"method":"item/reasoning/summaryTextDelta","params":{"itemId":"r","summaryIndex":0,"delta":"First"}}"#)
        client.receive(#"{"method":"item/reasoning/summaryTextDelta","params":{"itemId":"r","summaryIndex":1,"delta":"Second"}}"#)
        client.receive(#"{"method":"item/reasoning/summaryTextDelta","params":{"itemId":"r","summaryIndex":0,"delta":" part"}}"#)
        let transcript = try #require(CodexItemStore.shared.transcript(forTab: session.tabID))
        #expect(transcript.messages.count == 1)
        #expect(transcript.messages.first?.blocks == [.thinking("First part\nSecond")])
        #expect(session.streamingThinking.isEmpty)
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
        #expect(session.contextUsedTokens == 10)
    }

    @Test func aCommandApprovalBecomesAPendingPermission() {
        let (session, client, _) = makeSession()
        client.receive(#"""
        {"id":5,"method":"item/commandExecution/requestApproval","params":{"itemId":"it-1","threadId":"t","turnId":"u","startedAtMs":0,"command":"ls -la","reason":"needs approval","availableDecisions":["accept","acceptForSession","decline"]}}
        """#)
        let permission = try? #require(session.pendingPermissions.first)
        #expect(permission?.id == "number:5")
        #expect(permission?.toolUseID == "u#it-1")
        #expect(permission?.description == "ls -la")
        #expect(permission?.decisionReason == "needs approval")
        #expect(permission?.decisions.map(\.id) == ["accept", "acceptForSession", "decline"])
    }

    @Test func aServerChosenDecisionRoundTripsVerbatim() throws {
        let (session, client, sent) = makeSession()
        client.receive(#"{"id":7,"method":"item/commandExecution/requestApproval","params":{"itemId":"it-3","command":"ls","availableDecisions":["acceptForSession","cancel"]}}"#)
        let permission = try #require(session.pendingPermissions.first)
        session.resolve(permission, with: permission.decisions[0])
        #expect(try #require(sent().last).contains("\"decision\":\"acceptForSession\""))
    }

    @Test func approvalRowsUseTypedRequestIdentityAndAllowDuplicateItemIDs() throws {
        let (session, client, sent) = makeSession()
        client.receive(#"{"id":5,"method":"item/commandExecution/requestApproval","params":{"itemId":"same","threadId":"t","turnId":"one","command":"one"}}"#)
        client.receive(#"{"id":"5","method":"item/commandExecution/requestApproval","params":{"itemId":"same","threadId":"t","turnId":"two","command":"two"}}"#)

        #expect(session.pendingPermissions.map(\.id) == ["number:5", "string:5"])
        #expect(session.pendingPermissions.map(\.toolUseID) == ["one#same", "two#same"])

        let second = try #require(session.pendingPermissions.last)
        session.resolve(second, with: second.decisions[0])
        #expect(session.pendingPermissions.map(\.id) == ["number:5"])
        #expect(try #require(sent().last).contains("\"id\":\"5\""))

        client.receive(#"{"method":"serverRequest/resolved","params":{"requestId":5,"threadId":"t"}}"#)
        #expect(session.pendingPermissions.isEmpty)
    }

    @Test func liveCommandDecisionShapeKeepsOnlySupportedChoices() throws {
        let (session, client, sent) = makeSession()
        client.receive(#"{"id":0,"method":"item/commandExecution/requestApproval","params":{"itemId":"exec-probe","command":"printf APPROVAL_OK","availableDecisions":["accept",{"acceptWithExecpolicyAmendment":{"execpolicy_amendment":["printf","APPROVAL_OK"]}},"cancel"]}}"#)
        let permission = try #require(session.pendingPermissions.first)
        #expect(permission.decisions.map(\.id) == ["accept", "cancel"])
        session.resolve(permission, with: permission.decisions[1])
        #expect(try #require(sent().last).contains("\"decision\":\"cancel\""))
    }

    @Test func disconnectedApprovalCannotBeAnsweredThroughItsStaleRow() throws {
        let (session, client, sent) = makeSession()
        client.receive(#"{"id":0,"method":"item/fileChange/requestApproval","params":{"itemId":"edit","threadId":"thread","turnId":"turn"}}"#)
        let permission = try #require(session.pendingPermissions.first)
        client.handleExit(status: 9, message: "Probe disconnect")
        #expect(session.pendingPermissions.isEmpty)
        let count = sent().count
        session.resolve(permission, with: permission.decisions[0])
        #expect(sent().count == count)
        #expect(session.hasExited)
    }

    @Test func aCodexQuestionAnswersByQuestionID() throws {
        let (session, client, sent) = makeSession()
        client.receive(#"{"id":9,"method":"item/tool/requestUserInput","params":{"itemId":"q-item","threadId":"t","turnId":"u","isBlocking":true,"questions":[{"id":"language","header":"Choice","question":"Which language?","options":[{"label":"Swift","description":"Native"}]}]}}"#)
        let permission = try #require(session.pendingPermissions.first)
        guard case .questions(let questions)? = permission.interactive else {
            Issue.record("Expected questions")
            return
        }
        #expect(questions.first?.id == "language")
        session.answer(permission, answers: ["Which language?": "Swift"])
        let reply = try #require(sent().last)
        #expect(reply.contains("\"language\":{\"answers\":[\"Swift\"]}"))
    }

    @Test func expandedPermissionsCanBeGrantedForTheSession() throws {
        let (session, client, sent) = makeSession()
        client.receive(#"{"id":10,"method":"item/permissions/requestApproval","params":{"itemId":"p-item","threadId":"t","turnId":"u","cwd":"/tmp","startedAtMs":0,"permissions":{"network":{"enabled":true}},"reason":"Fetch docs"}}"#)
        let permission = try #require(session.pendingPermissions.first)
        #expect(permission.decisions.map(\.id) == ["turn", "session", "decline"])
        session.resolve(permission, with: permission.decisions[1])
        let reply = try #require(sent().last)
        #expect(reply.contains("\"scope\":\"session\""))
        #expect(reply.contains("\"network\":{\"enabled\":true}"))
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
        #expect(session.queuedMessages.map(\.plainText) == ["first"])
    }

    @Test func steeringTargetsTheActiveTurnAndDoesNotUseTheQueue() async throws {
        let (session, client, sent) = makeSession()
        defer { session.stop() }
        session.start(
            workingDirectory: "/tmp/project",
            resumeThreadID: nil,
            model: nil,
            collaborationMode: .default,
            environment: [:]
        )

        var cursor = 0
        try await answer("initialize", result: .object([:]), client: client, sent: sent, cursor: &cursor)
        try await answer("account/rateLimits/read", result: .object([:]), client: client, sent: sent, cursor: &cursor)
        try await answer("model/list", result: .object(["data": .array([])]), client: client, sent: sent, cursor: &cursor)
        try await answer("permissionProfile/list", result: .object(["data": .array([])]), client: client, sent: sent, cursor: &cursor)
        try await answer("thread/start", result: .object([
            "thread": .object(["id": .string("thread-1")])
        ]), client: client, sent: sent, cursor: &cursor)
        try await answer("thread/items/list", result: .object([
            "data": .array([]), "nextCursor": .null
        ]), client: client, sent: sent, cursor: &cursor)

        session.submit(text: "start")
        try await answer("turn/start", result: .object([
            "turn": .object(["id": .string("turn-1")])
        ]), client: client, sent: sent, cursor: &cursor)
        client.receive(#"{"method":"turn/started","params":{"threadId":"thread-1","turn":{"id":"turn-1"}}}"#)
        #expect(session.canSteer)

        let steeringImage = ChatImage(mediaType: "image/png", base64: "aW1hZ2U=")
        let outcome = Task { await session.steer(blocks: [.text("  change course  "), .image(steeringImage)]) }
        try await waitUntil { sent().contains { requestMethod(in: $0) == "turn/steer" } }
        let request = try #require(sent().first { requestMethod(in: $0) == "turn/steer" })
        let params = try #require(decodedObject(request)?["params"])
        #expect(params["threadId"] == .string("thread-1"))
        #expect(params["expectedTurnId"] == .string("turn-1"))
        #expect(params["input"]?.arrayValue?.first?["text"] == .string("change course"))
        #expect(params["input"]?.arrayValue?.last?["url"] == .string("data:image/png;base64,aW1hZ2U="))
        #expect(session.queuedMessages.isEmpty)
        #expect(session.isSteering)
        #expect(!session.canSteer)

        try await answer("turn/steer", result: .object([:]), client: client, sent: sent, cursor: &cursor)
        #expect(await outcome.value)
        #expect(!session.isSteering)

        let rejected = Task { await session.steer(text: "do not lose this") }
        try await waitUntil { sent().filter { requestMethod(in: $0) == "turn/steer" }.count == 2 }
        let second = try #require(sent().last { requestMethod(in: $0) == "turn/steer" })
        let secondID = try #require(decodedObject(second)?["id"])
        let error = try JSONEncoder().encode(JSONValue.object([
            "id": secondID,
            "error": .object(["code": .number(-32000), "message": .string("turn cannot be steered")])
        ]))
        client.receive(String(decoding: error, as: UTF8.self))
        #expect(!(await rejected.value))
        #expect(session.queuedMessages.isEmpty)
        #expect(session.lastError != nil)
    }

    @Test func aSteerWithoutAnAddressableTurnIsRetainedByTheCaller() async {
        let (session, _, _) = makeSession()
        #expect(!session.canSteer)
        #expect(!(await session.steer(text: "keep this draft")))
        #expect(session.queuedMessages.isEmpty)
    }

    @Test func implementingAPlanQueuesANewCodeModeTurn() {
        let (session, client, _) = makeSession()
        defer { CodexItemStore.shared.forget(tabID: session.tabID) }
        session.setCollaborationMode(.plan)
        client.receive(#"{"method":"item/completed","params":{"turnId":"planning","item":{"id":"proposal","type":"plan","text":"Build it"}}}"#)
        #expect(session.planProposal?.markdown == "Build it")

        session.implementPlan(feedback: " Preserve compatibility ")

        #expect(session.collaborationMode == .default)
        #expect(session.planProposal == nil)
        #expect(session.queuedMessages.map(\.plainText) == ["Implement the proposed plan with this feedback:\n\nPreserve compatibility"])
        #expect(session.supportsPlanApproval)
        #expect(session.sessionCostUSD == nil)
    }

    @Test func rejectingAPlanQueuesFeedbackInPlanMode() {
        let (session, client, _) = makeSession()
        defer { CodexItemStore.shared.forget(tabID: session.tabID) }
        client.receive(#"{"method":"item/completed","params":{"turnId":"planning","item":{"id":"proposal","type":"plan","text":"Build it"}}}"#)

        session.requestPlanChanges(" Keep the old API ")

        #expect(session.collaborationMode == .plan)
        #expect(session.planProposal == nil)
        #expect(session.queuedMessages.map(\.plainText) == ["Revise the proposed plan with this feedback:\n\nKeep the old API"])
    }

    @Test func planDecisionWaitsForThePlanningTurnToFinish() {
        let (session, client, _) = makeSession()
        defer { CodexItemStore.shared.forget(tabID: session.tabID) }
        client.receive(#"{"method":"turn/started","params":{"turn":{"id":"planning"}}}"#)
        client.receive(#"{"method":"item/completed","params":{"turnId":"planning","item":{"id":"proposal","type":"plan","text":"Build it"}}}"#)

        #expect(!session.implementPlan())
        #expect(session.planProposal != nil)
        #expect(session.queuedMessages.isEmpty)
    }

    private func answer(
        _ method: String,
        result: JSONValue,
        client: CodexAppServerClient,
        sent: () -> [String],
        cursor: inout Int
    ) async throws {
        // Catalog and background inventory refresh independently after startup.
        // They are not part of the ordered turn-control exchange under test.
        func requests() -> [String] {
            sent().filter {
                decodedObject($0)?["id"] != nil
                    && !["skills/list", "thread/backgroundTerminals/list"].contains(requestMethod(in: $0) ?? "")
            }
        }
        try await waitUntil {
            requests().indices.contains(cursor) && requestMethod(in: requests()[cursor]) == method
        }
        let request = try #require(decodedObject(requests()[cursor]))
        let id = try #require(request["id"])
        cursor += 1
        let response = try JSONEncoder().encode(JSONValue.object(["id": id, "result": result]))
        client.receive(String(decoding: response, as: UTF8.self))
    }

    private func requestMethod(in line: String) -> String? {
        decodedObject(line)?["method"]?.stringValue
    }

    private func decodedObject(_ line: String) -> [String: JSONValue]? {
        guard let data = line.data(using: .utf8),
              case .object(let object)? = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return nil }
        return object
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("condition never became true")
        throw CancellationError()
    }
}
