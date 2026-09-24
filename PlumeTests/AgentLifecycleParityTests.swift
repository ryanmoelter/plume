import Foundation
import Testing
@testable import Plume

@MainActor
struct AgentLifecycleParityTests {
    @Test func reservesCodexThreadsBeforeHandshakeAndReleasesOnClose() {
        let manager = AgentSessionManager()
        let first = UUID(), second = UUID(), task = UUID()
        _ = manager.session(for: first, taskID: task, provider: .codex)
        _ = manager.session(for: second, taskID: task, provider: .codex)
        #expect(manager.claimCodexThread("conversation", for: first))
        #expect(!manager.claimCodexThread("conversation", for: second))
        #expect(manager.claimCodexThread("conversation", for: first))
        manager.closeSession(for: first)
        #expect(manager.claimCodexThread("conversation", for: second))
        manager.closeAll()
    }

    @Test func failedCodexResumeDoesNotKeepOwnership() {
        let manager = AgentSessionManager()
        let first = UUID(), second = UUID(), task = UUID()
        let session = manager.session(for: first, taskID: task, provider: .codex) as? CodexSession
        #expect(manager.claimCodexThread("conversation", for: first))
        session?.failToLaunch(reason: "offline")
        #expect(!manager.isCodexThreadOwnedElsewhere("conversation", by: second))
        manager.closeAll()
    }

    @Test func movingAnAgentPreservesItsSession() {
        let manager = AgentSessionManager()
        let tab = UUID(), destination = UUID()
        let session = manager.session(for: tab, taskID: UUID(), provider: .codex)
        manager.reparent(tabID: tab, taskID: destination)
        #expect(manager.existingSession(for: tab) === session)
        #expect(session.taskID == destination)
        manager.closeAll()
    }

    @Test func movingStatusPreservesWorkAndRoutesLateHooksToTheDestination() {
        let tracker = BackgroundTaskTracker()
        let engine = StatusEngine(backgroundTasks: tracker)
        let tab = UUID(), source = UUID(), destination = UUID()
        engine.setStatus(.working, taskID: source, tabID: tab)
        let started = engine.workStarted(forTab: tab)
        tracker.replace(tabID: tab, entries: [
            .init(id: "command", kind: .backgroundCommand, description: "build", startedAt: Date(), expiresAt: nil)
        ])
        var notifiedTasks: [UUID] = []
        engine.onTabStatusChanged = { task, _, _, _ in notifiedTasks.append(task) }
        engine.reparent(tabID: tab, taskID: destination)
        #expect(engine.status(forTask: source) == .notStarted)
        #expect(engine.status(forTask: destination) == .working)
        #expect(engine.workStarted(forTab: tab) == started)
        #expect(engine.backgroundTaskTabs.first?.taskID == destination)
        #expect(notifiedTasks.isEmpty)
        engine.setStatus(.awaitingReply, taskID: source, tabID: tab)
        #expect(notifiedTasks == [destination])
        #expect(engine.status(forTask: source) == .notStarted)
        #expect(engine.status(forTask: destination) == .awaitingReply)
    }
}
