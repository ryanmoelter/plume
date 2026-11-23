import Foundation
import Testing
@testable import Plume

@MainActor
struct CodexRecoveryTests {
    @MainActor
    private final class Harness {
        var client: CodexAppServerClient!
        var requests: [JSONValue] = []
        var failResume = false
        var resumeErrorCode = -1
        var resumeErrorMessage = "Thread unavailable"
        var failStart = false
        var echoesWorkspaceRoots = true
        var resumedThread: JSONValue?
        var beforeResumeReply: (() -> Void)?
        var beforeHistoryReply: (() -> Void)?

        init() {
            client = CodexAppServerClient { [weak self] line in
                guard let self,
                      let request = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)),
                      let method = request["method"]?.stringValue else { return true }
                requests.append(request)
                if method == "thread/resume" { beforeResumeReply?() }
                if method == "thread/items/list" { beforeHistoryReply?() }
                guard let id = request["id"], method != "turn/start" else { return true }
                if (method == "thread/resume" && failResume) || (method == "thread/start" && failStart) {
                    reply(id: id, error: .object(["code": .number(Double(resumeErrorCode)), "message": .string(resumeErrorMessage)]))
                } else {
                    let result: JSONValue
                    if method == "thread/resume" || method == "thread/start" {
                        var fields: [String: JSONValue] = [
                            "thread": resumedThread ?? .object(["id": .string("thread")]),
                            "model": .string("gpt-6-astra"), "reasoningEffort": .string("medium")
                        ]
                        if echoesWorkspaceRoots {
                            fields["runtimeWorkspaceRoots"] = request["params"]?["runtimeWorkspaceRoots"]
                        }
                        result = .object(fields)
                    } else {
                        result = .object(["data": .array([])])
                    }
                    reply(id: id, result: result)
                }
                return true
            }
        }

        func reply(id: JSONValue, result: JSONValue = .object([:]), error: JSONValue? = nil) {
            let object: JSONValue = error.map { .object(["id": id, "error": $0]) }
                ?? .object(["id": id, "result": result])
            let data = try! JSONEncoder().encode(object)
            client.receive(String(decoding: data, as: UTF8.self))
        }

        var turns: [JSONValue] { requests.filter { $0["method"] == .string("turn/start") } }
        var interrupts: [JSONValue] { requests.filter { $0["method"] == .string("turn/interrupt") } }
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("Protocol task did not settle")
        throw CancellationError()
    }

    @Test func neverMountedThreadPersistsItsLastItem() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let items = CodexItemStore(cache: CodexHistoryCache(directory: directory))
        let h = Harness()
        let session = CodexSession(tabID: UUID(), taskID: UUID(), client: h.client, itemStore: items)
        defer { session.stop() }
        session.start(workingDirectory: nil, resumeThreadID: nil, model: nil, environment: [:])
        try await waitFor { h.requests.contains { $0["method"] == .string("thread/backgroundTerminals/list") } }
        h.client.receive(#"{"method":"item/completed","params":{"threadId":"thread","turnId":"turn","item":{"id":"reply","type":"agentMessage","text":"Done"}}}"#)
        await items.flush(tabID: session.tabID)
        let reopened = CodexHistoryCache(directory: directory)
        let snapshot = await reopened.load(tabID: session.tabID, threadID: "thread")
        #expect(snapshot?.entries.last?.stableID == "turn#reply")
    }

    private var activeRemoteThread: JSONValue {
        .object(["id": .string("thread"), "status": .object(["type": .string("active")]),
                 "turns": .array([.object(["id": .string("remote-turn"), "status": .string("inProgress")])])])
    }

    @Test func parentBriefAndUserFollowUpKeepTheirTurnOrigins() async throws {
        let h = Harness()
        let session = CodexSession(tabID: UUID(), taskID: UUID(), client: h.client)
        defer { session.stop() }
        var outcomes: [AgentTurnOutcome] = []
        session.onTurnFinished = { outcomes.append($0) }
        session.start(
            workingDirectory: "/workspace", resumeThreadID: nil, model: nil,
            permissionProfile: AgentPermissionPreset.codexWorkspace.id,
            defaultPermissionProfile: AgentPermissionPreset.codexDangerFullAccess.id,
            isChildSession: true, childNotesDirectory: "/notes/session", environment: [:],
            additionalDirectories: ["/notes/session", "/extra"]
        )
        let brief = HostMessage(
            display: [.text("Check login")], wire: [.text("Task:\nCheck login")],
            origin: .fromParent(text: "Check login")
        )
        session.submit(QueuedMessage(parts: [.host(brief)]))
        #expect(session.hasPendingParentBrief)
        let workingSince = try #require(session.workingSince)
        try await waitFor { h.turns.count == 1 }
        #expect(session.workingSince == workingSince)
        let start = try #require(h.requests.first { $0["method"] == .string("thread/start") })
        #expect(start["params"]?["permissions"] == .string(":workspace"))
        #expect(start["params"]?["runtimeWorkspaceRoots"] == .array([.string("/workspace"), .string("/notes/session"), .string("/extra")]))
        #expect(!session.hasPendingAdditionalDirectories)
        #expect(session.appliedAdditionalDirectories == ["/extra"])
        session.setAdditionalDirectories([])
        #expect(h.turns.first?["params"]?["input"]?.arrayValue?.first?["text"] == .string("Task:\nCheck login"))
        session.submit(text: "User follow-up")

        h.reply(id: try #require(h.turns[0]["id"]), result: .object(["turn": .object(["id": .string("t1")])]))
        h.client.receive(#"{"method":"turn/started","params":{"threadId":"thread","turn":{"id":"t1"}}}"#)
        h.client.receive(#"{"method":"item/completed","params":{"threadId":"thread","turnId":"t1","item":{"id":"final","type":"agentMessage","phase":"final_answer","text":"Login works"}}}"#)
        h.client.receive(#"{"method":"turn/completed","params":{"threadId":"thread","turn":{"id":"t1","status":"completed"}}}"#)
        try await waitFor { h.turns.count == 2 }
        #expect(h.turns.last?["params"]?["runtimeWorkspaceRoots"] == .array([.string("/workspace"), .string("/notes/session")]))
        #expect(outcomes.map(\.isParentDriven) == [true])
        #expect(outcomes.first?.text == "Login works")

        h.reply(id: try #require(h.turns[1]["id"]), result: .object(["turn": .object(["id": .string("t2")])]))
        h.client.receive(#"{"method":"turn/started","params":{"threadId":"thread","turn":{"id":"t2"}}}"#)
        h.client.receive(#"{"method":"turn/completed","params":{"threadId":"thread","turn":{"id":"t2","status":"completed"}}}"#)
        try await waitFor { outcomes.count == 2 }
        #expect(outcomes.map(\.isParentDriven) == [true, false])
    }

    @Test func childWithoutNotesRootSupportFailsBeforeAdoption() async throws {
        let h = Harness()
        h.echoesWorkspaceRoots = false
        let session = CodexSession(tabID: UUID(), taskID: UUID(), client: h.client)
        defer { session.stop() }
        session.start(
            workingDirectory: "/workspace", resumeThreadID: nil, model: nil,
            isChildSession: true, childNotesDirectory: "/notes/session", environment: [:]
        )
        let brief = HostMessage(display: [.text("Check login")], wire: [.text("Check login")], origin: .fromParent(text: "Check login"))
        session.submit(QueuedMessage(parts: [.host(brief)]))
        try await waitFor { session.hasExited }
        #expect(session.sessionID == nil)
        #expect(session.lastError?.contains("cannot apply linked folders") == true)
        #expect(h.turns.isEmpty)
    }

    @Test(arguments: [false, true])
    func parentBriefReportsStartupFailureAfterTheChildStopsHoldingWakes(disconnectAfterAdopt: Bool) async throws {
        let h = Harness()
        h.failStart = !disconnectAfterAdopt
        let session = CodexSession(tabID: UUID(), taskID: UUID(), client: h.client)
        defer { session.stop() }
        var outcomes: [AgentTurnOutcome] = []
        session.onTurnFinished = { outcome in
            #expect(session.hasExited)
            #expect(!session.hasPendingParentBrief)
            #expect(session.workingSince == nil)
            outcomes.append(outcome)
        }
        if disconnectAfterAdopt {
            h.beforeHistoryReply = {
                #expect(session.sessionID == "thread")
                h.client.onExit?(1, "Connection lost during history hydration")
            }
        }
        session.start(workingDirectory: nil, resumeThreadID: nil, model: nil, isChildSession: true, environment: [:])
        let brief = HostMessage(display: [.text("Check login")], wire: [.text("Check login")], origin: .fromParent(text: "Check login"))
        session.submit(QueuedMessage(parts: [.host(brief)]))
        try await waitFor { outcomes.count == 1 }
        #expect(outcomes.first?.isParentDriven == true)
        #expect(outcomes.first?.exitedMidTurn == true)
        #expect(h.turns.isEmpty)
    }

    @Test func refreshReportsActiveParentTurnOnceAndResubmitsOnlyQueuedFollowup() async throws {
        func parentMessage(_ text: String) -> QueuedMessage {
            let host = HostMessage(display: [.text(text)], wire: [.text(text)], origin: .fromParent(text: text))
            return QueuedMessage(parts: [.host(host)])
        }
        let original = Harness()
        let session = CodexSession(tabID: UUID(), taskID: UUID(), client: original.client)
        session.start(workingDirectory: nil, resumeThreadID: nil, model: nil, isChildSession: true, environment: [:])
        session.submit(parentMessage("Active brief"))
        try await waitFor { original.turns.count == 1 }
        let followup = parentMessage("Queued follow-up")
        session.submit(followup)
        let queued = session.queue
        #expect(queued == [followup])

        var outcomes: [AgentTurnOutcome] = []
        session.onTurnFinished = { outcomes.append($0) }
        let resumedThreadID = try #require(session.sessionID)
        session.stop()

        let replacement = Harness()
        let resumed = CodexSession(tabID: session.tabID, taskID: session.taskID, client: replacement.client)
        defer { resumed.stop() }
        resumed.start(workingDirectory: nil, resumeThreadID: resumedThreadID, model: nil, isChildSession: true, environment: [:])
        for message in queued { resumed.submit(message) }
        session.reportInterruptedParentTurn()
        session.reportInterruptedParentTurn()

        try await waitFor { replacement.turns.count == 1 }
        #expect(outcomes.count == 1)
        #expect(outcomes.first?.isParentDriven == true)
        #expect(outcomes.first?.wasInterrupted == true)
        #expect(session.queue == [followup])
        #expect(replacement.turns.first?["params"]?["input"]?.arrayValue?.first?["text"] == .string("Queued follow-up"))
    }

    @Test func resumeRestoresRemoteTurnAndQueuesFollowupUntilItEnds() async throws {
        let h = Harness()
        h.resumedThread = activeRemoteThread
        let session = CodexSession(tabID: UUID(), taskID: UUID(), client: h.client)
        defer { session.stop() }
        session.start(workingDirectory: nil, resumeThreadID: "thread", model: nil, environment: [:])
        try await waitFor { session.canSteer }
        #expect(session.isWorking)
        #expect(session.workingSince != nil)
        session.submit(text: "Follow up after the remote turn")
        #expect(h.turns.isEmpty)
        #expect(session.queuedMessages.count == 1)
        session.interrupt()
        try await waitFor { !h.interrupts.isEmpty }
        #expect(h.interrupts.first?["params"]?["turnId"] == .string("remote-turn"))
    }

    @Test func resumeRestoresWaitingFlagsWithoutAWorkingAwakeHold() async throws {
        for (flag, expected) in [("waitingOnApproval", TaskStatus.permissionNeeded), ("waitingOnUserInput", .questionAsked)] {
            let h = Harness()
            h.resumedThread = .object([
                "id": .string("thread"),
                "status": .object(["type": .string("active"), "activeFlags": .array([.string(flag)])]),
                "turns": .array([.object(["id": .string("remote-turn"), "status": .string("inProgress")])])
            ])
            let session = CodexSession(tabID: UUID(), taskID: UUID(), client: h.client)
            session.start(workingDirectory: nil, resumeThreadID: "thread", model: nil, environment: [:])
            try await waitFor { h.requests.contains { $0["method"] == .string("thread/items/list") } }
            #expect(session.isWorking) // The turn is still active; follow-ups must queue.
            #expect(StatusEngine.shared.status(forTab: session.tabID) == expected)
            session.stop()
        }
    }

    @Test func remoteAttachmentDoesNotOverrideRuntimeConfiguration() async throws {
        let h = Harness()
        h.resumedThread = activeRemoteThread
        let session = CodexSession(tabID: UUID(), taskID: UUID(), client: h.client)
        defer { session.stop() }
        session.start(workingDirectory: "/stale/path", resumeThreadID: "thread",
                      model: AgentModel(id: "stale-model", label: "Stale"),
                      preserveRemoteConfiguration: true, environment: [:])
        try await waitFor { session.canSteer }
        let request = try #require(h.requests.first { $0["method"] == .string("thread/resume") })
        #expect(request["params"] == .object(["threadId": .string("thread")]))
        #expect(session.model?.id == "gpt-6-astra")
    }

    @Test func bufferedCompletionWinsOverActiveResumeSnapshot() async throws {
        let h = Harness()
        h.resumedThread = activeRemoteThread
        h.beforeResumeReply = {
            h.client.receive(#"{"method":"turn/completed","params":{"threadId":"thread","turn":{"id":"remote-turn","status":"completed"}}}"#)
        }
        let session = CodexSession(tabID: UUID(), taskID: UUID(), client: h.client)
        defer { session.stop() }
        session.start(workingDirectory: nil, resumeThreadID: "thread", model: nil, environment: [:])
        try await waitFor { h.requests.contains { $0["method"] == .string("thread/items/list") } }
        #expect(!session.isWorking)
        #expect(!session.canSteer)
    }

    @Test func liveTurnDuringHistoryHydrationWinsOverResumeSnapshot() async throws {
        let h = Harness()
        h.resumedThread = activeRemoteThread
        h.beforeHistoryReply = {
            h.client.receive(#"{"method":"turn/completed","params":{"threadId":"thread","turn":{"id":"remote-turn","status":"completed"}}}"#)
            h.client.receive(#"{"method":"turn/started","params":{"threadId":"thread","turn":{"id":"new-turn","status":"inProgress"}}}"#)
        }
        let session = CodexSession(tabID: UUID(), taskID: UUID(), client: h.client)
        defer { session.stop() }
        session.start(workingDirectory: nil, resumeThreadID: "thread", model: nil, environment: [:])
        try await waitFor { h.requests.contains { $0["method"] == .string("thread/items/list") } }
        session.interrupt()
        try await waitFor { !h.interrupts.isEmpty }
        #expect(session.isWorking)
        #expect(h.interrupts.first?["params"]?["turnId"] == .string("new-turn"))
    }

    @Test(arguments: [nil, "thread"])
    func theThreadRequestCarriesTheTabsEnvironment(resumeThreadID: String?) async throws {
        let h = Harness()
        let session = CodexSession(tabID: UUID(), taskID: UUID(), client: h.client)
        defer { session.stop() }
        session.start(
            workingDirectory: nil, resumeThreadID: resumeThreadID, model: nil,
            environment: [:], threadEnvironment: ["PLUME_TAB_ID": "tab", "PLUME_TASK_ID": "task"]
        )
        let method = resumeThreadID == nil ? "thread/start" : "thread/resume"
        try await waitFor { h.requests.contains { $0["method"] == .string(method) } }
        let request = try #require(h.requests.first { $0["method"] == .string(method) })
        #expect(request["params"]?["config"] == .object([
            "shell_environment_policy.set.PLUME_TAB_ID": .string("tab"),
            "shell_environment_policy.set.PLUME_TASK_ID": .string("task"),
        ]))
    }

    @Test func noThreadEnvironmentSendsNoConfig() async throws {
        let h = Harness()
        let session = CodexSession(tabID: UUID(), taskID: UUID(), client: h.client)
        defer { session.stop() }
        session.start(workingDirectory: nil, resumeThreadID: nil, model: nil, environment: [:])
        try await waitFor { h.requests.contains { $0["method"] == .string("thread/start") } }
        let request = try #require(h.requests.first { $0["method"] == .string("thread/start") })
        #expect(request["params"]?["config"] == nil)
    }

    @Test func failedResumeBecomesRetryableWithoutStartingANewThread() async throws {
        let h = Harness()
        h.failResume = true
        let session = CodexSession(tabID: UUID(), taskID: UUID(), client: h.client)
        defer { session.stop() }
        session.start(workingDirectory: nil, resumeThreadID: "thread", model: nil, environment: [:])
        session.submit(text: "still unsent")
        try await waitFor { session.hasExited }
        #expect(session.queuedMessages.map(\.plainText) == ["still unsent"])
        #expect(h.turns.isEmpty)
        #expect(!h.requests.contains { $0["method"] == .string("thread/start") })
        #expect(session.lastError?.contains("Thread unavailable") == true)
    }

    @Test func activeWriterRefusalKeepsHistoryAndUnsentInputForRetry() async throws {
        let tabID = UUID()
        let items = CodexItemStore()
        items.upsert(tabID: tabID, item: .object(["id": .string("saved"), "type": .string("agentMessage"), "text": .string("Saved reply")]), turnID: "previous")
        let h = Harness()
        h.failResume = true
        h.resumeErrorCode = -32600
        h.resumeErrorMessage = "thread thread already has an active writer"
        let session = CodexSession(tabID: tabID, taskID: UUID(), client: h.client, itemStore: items)
        defer { session.stop() }
        session.start(workingDirectory: nil, resumeThreadID: "thread", model: nil, environment: [:])
        session.submit(text: "still unsent")
        try await waitFor { session.hasExited }
        #expect(session.hasActiveWriterConflict)
        #expect(session.startFailure?.title == "This conversation is open elsewhere")
        #expect(session.lastError?.contains("Close it there") == true)
        #expect(session.queuedMessages.map(\.plainText) == ["still unsent"])
        #expect(items.item(tabID: tabID, id: "previous#saved")?["text"] == .string("Saved reply"))
        #expect(h.turns.isEmpty)
        #expect(h.interrupts.isEmpty)
        #expect(!h.requests.contains { $0["method"] == .string("thread/start") })

        let retry = Harness()
        let resumed = CodexSession(tabID: tabID, taskID: session.taskID, client: retry.client)
        defer { resumed.stop() }
        resumed.start(workingDirectory: nil, resumeThreadID: "thread", model: nil, environment: [:])
        for blocks in session.queuedMessages { resumed.submit(blocks: blocks) }
        try await waitFor { retry.turns.count == 1 }
        #expect(!resumed.hasActiveWriterConflict)
        #expect(retry.requests.first { $0["method"] == .string("thread/resume") }?["params"]?["threadId"] == .string("thread"))
        #expect(!retry.requests.contains { $0["method"] == .string("thread/start") })
        #expect(retry.turns[0]["params"]?["input"]?.arrayValue?.first?["text"] == .string("still unsent"))
    }

    @Test func ownershipRequiresTheMatchingServerRefusal() {
        #expect(CodexThreadOwnership.isActiveWriterConflict(CodexAppServerClient.Failure.server(code: -32600, message: "thread target already has an active writer"), threadID: "target"))
        #expect(!CodexThreadOwnership.isActiveWriterConflict(CodexAppServerClient.Failure.server(code: -32600, message: "thread other already has an active writer"), threadID: "target"))
        #expect(!CodexThreadOwnership.isActiveWriterConflict(CodexAppServerClient.Failure.server(code: -32603, message: "thread target already has an active writer"), threadID: "target"))
        #expect(!CodexThreadOwnership.isActiveWriterConflict(CodexAppServerClient.Failure.server(code: -32600, message: "command output: already has an active writer"), threadID: "target"))
    }

    @Test func disconnectDoesNotRequeueAnUncertainTurn() async throws {
        let h = Harness()
        let session = CodexSession(tabID: UUID(), taskID: UUID(), client: h.client)
        defer { session.stop() }
        session.start(workingDirectory: nil, resumeThreadID: "thread", model: nil, environment: [:])
        session.submit(text: "possibly accepted")
        try await waitFor { h.turns.count == 1 }
        session.submit(text: "definitely unsent")
        h.client.handleExit(status: 1, message: "Lost connection")
        await Task.yield()
        #expect(session.hasExited)
        #expect(session.sessionID == "thread")
        #expect(session.queuedMessages.map(\.plainText) == ["definitely unsent"])
        #expect(h.turns.count == 1)
    }

    @Test func lateStartReplyCannotRestartACompletedTurn() async throws {
        let h = Harness()
        let session = CodexSession(tabID: UUID(), taskID: UUID(), client: h.client)
        defer { session.stop() }
        session.start(workingDirectory: nil, resumeThreadID: nil, model: nil, environment: [:])
        session.submit(text: "one")
        try await waitFor { h.turns.count == 1 }
        session.submit(text: "two")
        h.client.receive(#"{"method":"turn/started","params":{"threadId":"thread","turn":{"id":"t1"}}}"#)
        h.client.receive(#"{"method":"turn/completed","params":{"threadId":"thread","turn":{"id":"t1","status":"completed"}}}"#)
        #expect(!session.isWorking)
        h.reply(id: try #require(h.turns.first?["id"]), result: .object(["turn": .object(["id": .string("t1")])]))
        try await waitFor { h.turns.count == 2 }
        #expect(session.queuedMessages.isEmpty)
        #expect(session.isWorking)
        #expect(h.turns.last?["params"]?["input"]?.arrayValue?.first?["text"] == .string("two"))
    }

    @Test func interruptedTurnKeepsQueuedFollowupUnsentAfterLateReply() async throws {
        let h = Harness()
        let session = CodexSession(tabID: UUID(), taskID: UUID(), client: h.client)
        defer { session.stop() }
        session.start(workingDirectory: nil, resumeThreadID: nil, model: nil, environment: [:])
        session.submit(text: "one")
        try await waitFor { h.turns.count == 1 }
        session.submit(text: "two")
        h.client.receive(#"{"method":"turn/completed","params":{"threadId":"thread","turn":{"id":"t1","status":"interrupted"}}}"#)
        h.reply(id: try #require(h.turns.first?["id"]))
        await Task.yield()
        #expect(h.turns.count == 1)
        #expect(session.queuedMessages.map(\.plainText) == ["two"])
        #expect(!session.isWorking)
    }

    @Test func terminalErrorKeepsQueuedFollowupUnsentAfterLateReply() async throws {
        let h = Harness()
        let session = CodexSession(tabID: UUID(), taskID: UUID(), client: h.client)
        defer { session.stop() }
        session.start(workingDirectory: nil, resumeThreadID: nil, model: nil, environment: [:])
        session.submit(text: "one")
        try await waitFor { h.turns.count == 1 }
        session.submit(text: "two")

        h.client.receive(#"{"method":"error","params":{"threadId":"thread","turnId":"t1","willRetry":false,"error":{"message":"terminal failure"}}}"#)
        h.reply(
            id: try #require(h.turns.first?["id"]),
            result: .object(["turn": .object(["id": .string("t1")])])
        )
        await Task.yield()

        #expect(h.turns.count == 1)
        #expect(session.queuedMessages.map(\.plainText) == ["two"])
        #expect(!session.isWorking)
        #expect(session.lastError == "terminal failure")
    }

    @Test func interruptBeforeTurnIDIsDeliveredWhenStartReplies() async throws {
        let h = Harness()
        let session = CodexSession(tabID: UUID(), taskID: UUID(), client: h.client)
        defer { session.stop() }
        session.start(workingDirectory: nil, resumeThreadID: nil, model: nil, environment: [:])
        session.submit(text: "one")
        try await waitFor { h.turns.count == 1 }

        session.interrupt()
        await Task.yield()
        #expect(h.interrupts.isEmpty)

        h.reply(
            id: try #require(h.turns.first?["id"]),
            result: .object(["turn": .object(["id": .string("t1")])])
        )
        try await waitFor { h.interrupts.count == 1 }
        #expect(h.interrupts.first?["params"]?["threadId"] == .string("thread"))
        #expect(h.interrupts.first?["params"]?["turnId"] == .string("t1"))
    }

    @Test func zeroStatusAppServerExitIsStillAnError() async throws {
        let h = Harness()
        let tabID = UUID()
        let taskID = UUID()
        let session = CodexSession(tabID: tabID, taskID: taskID, client: h.client)
        defer { session.stop() }
        session.start(workingDirectory: nil, resumeThreadID: nil, model: nil, environment: [:])
        try await waitFor { session.sessionID == "thread" }

        h.client.handleExit(status: 0, message: nil)
        #expect(session.hasExited)
        #expect(StatusEngine.shared.ownStatus(forTab: tabID) == .error)
        #expect(session.lastError?.contains("disconnected") == true)
    }

    @Test func queuedImageOnlyTurnRetainsPayloadThroughSubmissionAndEditing() async throws {
        let h = Harness()
        let session = CodexSession(tabID: UUID(), taskID: UUID(), client: h.client)
        defer { session.stop() }
        let image = ChatImage(mediaType: "image/png", base64: "aW1hZ2U=")
        let blocks: [UserContentBlock] = [.image(image)]
        #expect(session.submit(blocks: blocks) == .queued)
        #expect(session.removeQueuedMessage(at: 0) == blocks)
        session.submit(blocks: blocks)
        session.start(workingDirectory: nil, resumeThreadID: nil, model: nil, environment: [:])
        try await waitFor { h.turns.count == 1 }
        #expect(h.turns[0]["params"]?["input"] == .array([
            .object(["type": .string("image"), "url": .string("data:image/png;base64,aW1hZ2U=")])
        ]))
    }

    @Test func imagesSurviveDefinitelyUnsentTransportFailure() async throws {
        let h = Harness()
        let session = CodexSession(tabID: UUID(), taskID: UUID(), client: h.client)
        defer { session.stop() }
        session.start(workingDirectory: nil, resumeThreadID: nil, model: nil, environment: [:])
        session.submit(text: "first")
        try await waitFor { h.turns.count == 1 }
        h.reply(id: try #require(h.turns.first?["id"]), result: .object(["turn": .object(["id": .string("initial")])]))
        try await waitFor { session.canSteer }
        h.client.receive(#"{"method":"turn/completed","params":{"threadId":"thread","turn":{"id":"initial","status":"completed"}}}"#)
        h.client.stop()
        let blocks: [UserContentBlock] = [.text("Keep this"), .image(.init(mediaType: "image/png", base64: "aW1hZ2U="))]
        session.submit(blocks: blocks)
        try await waitFor { !session.queuedMessages.isEmpty }
        #expect(session.queuedMessages == [blocks])
    }

    /// An interrupted turn otherwise pauses the queue, so send-now has to
    /// override that, and send the queue then the draft as one turn.
    @Test func sendNowInterruptsThenSendsTheQueueAsOneTurn() async throws {
        let h = Harness()
        let session = CodexSession(tabID: UUID(), taskID: UUID(), client: h.client)
        defer { session.stop() }
        session.start(workingDirectory: nil, resumeThreadID: nil, model: nil, environment: [:])
        session.submit(text: "one")
        try await waitFor { h.turns.count == 1 }
        h.reply(id: try #require(h.turns.first?["id"]), result: .object(["turn": .object(["id": .string("t1")])]))
        try await waitFor { session.canSteer }
        session.submit(text: "two")

        session.sendNow(appending: [.text("draft")])
        try await waitFor { h.interrupts.count == 1 }
        #expect(h.turns.count == 1)
        #expect(session.queuedMessages.map(\.plainText) == ["two", "draft"])

        h.client.receive(#"{"method":"turn/completed","params":{"threadId":"thread","turn":{"id":"t1","status":"interrupted"}}}"#)
        try await waitFor { h.turns.count == 2 }
        #expect(h.turns.last?["params"]?["input"]?.arrayValue?.first?["text"] == .string("two\n\ndraft"))
        #expect(session.queuedMessages.isEmpty)
    }
}
