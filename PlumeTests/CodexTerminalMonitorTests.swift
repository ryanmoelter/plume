import Foundation
import Testing
@testable import Plume

@MainActor
struct CodexTerminalMonitorTests {
    @Test func titleHelpersAndChildrenCannotReplaceTheResumeConversation() {
        #expect(CodexTerminalMonitor.isConversationRoot(.object(["id": .string("root"), "ephemeral": .bool(false)])))
        #expect(!CodexTerminalMonitor.isConversationRoot(.object(["id": .string("title"), "ephemeral": .bool(true)])))
        #expect(!CodexTerminalMonitor.isConversationRoot(.object(["id": .string("child"), "parentThreadId": .string("root")])))
    }

    @Test func childApprovalRemainsVisibleAfterParentFinishes() {
        let threads: [JSONValue] = [
            .object(["id": .string("parent"), "status": .object(["type": .string("idle")])]),
            .object(["id": .string("child"), "parentThreadId": .string("parent"), "status": .object([
                "type": .string("active"), "activeFlags": .array([.string("waitingOnApproval")])
            ])])
        ]
        #expect(CodexTerminalMonitor.aggregateStatus(threads) == .permissionNeeded)
        #expect(CodexTerminalMonitor.aggregateStatus([]) == .awaitingReply)
    }

    @Test func idleServerDoesNotCountAsWork() {
        #expect(CodexTerminalMonitor.status(.object(["type": .string("idle")])) == .awaitingReply)
        #expect(CodexTerminalMonitor.status(.object(["type": .string("notLoaded")])) == .awaitingReply)
    }

    @Test func approvalAndQuestionsAreNotWorking() {
        #expect(CodexTerminalMonitor.status(.object([
            "type": .string("active"), "activeFlags": .array([.string("waitingOnApproval")])
        ])) == .permissionNeeded)
        #expect(CodexTerminalMonitor.status(.object([
            "type": .string("active"), "activeFlags": .array([.string("waitingOnUserInput")])
        ])) == .questionAsked)
        #expect(CodexTerminalMonitor.status(.object([
            "type": .string("active"), "activeFlags": .array([])
        ])) == .working)
    }

    @Test func terminalConnectsToItsPrivateServerAndPreservesResume() {
        let launch = CodexProvider(remoteSocket: "/private/tmp/plume-test/s").launchCommand(
            firstMessage: nil, resumeSessionID: "thread-id", taskID: nil, tabID: nil, permissionMode: nil
        )
        #expect(launch.command.contains("--remote"))
        #expect(launch.command.contains("unix:///private/tmp/plume-test/s"))
        #expect(launch.command.contains("resume"))
        #expect(launch.command.contains("thread-id"))
        #expect(!launch.command.contains("bypass-hook-trust"))
    }

    @Test func unloadedThreadsReleaseBackgroundInventory() async {
        let tracker = BackgroundTaskTracker()
        let tab = UUID()
        let tasks = CodexBackgroundTaskTracker(tabID: tab, tracker: tracker) { _, _ in
            .object(["data": .array([.object(["processId": .string("build"), "command": .string("build")])])])
        }
        await tasks.refresh(threadID: "child")?.value
        #expect(tracker.inFlight(tabID: tab).count == 1)
        tasks.retainThreads([])
        #expect(tracker.inFlight(tabID: tab).isEmpty)
        tasks.stop()
    }
}
