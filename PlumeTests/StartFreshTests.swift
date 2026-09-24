import Testing
import Foundation
import SwiftData
@testable import Plume

/// `TaskStore.startFresh` is what both Start Fresh confirmation dialogs call.
/// It does not touch the live process — a headless session already running
/// keeps talking to the old conversation regardless — so this only covers
/// the bookkeeping: the resume link, the watches, and the title.
@MainActor
struct StartFreshTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(
        for: Schema([TaskGroup.self, WorkTask.self, TaskTab.self]),
        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        ))
    }

    /// The shared stores outlive any one test, and Swift Testing runs suites
    /// in parallel in one process, so cleanup is scoped to this test's tab.
    private func forgetSharedState(of tab: TaskTab) {
        TitleStore.shared.forget(tabID: tab.id)
        AgentTitleMonitor.shared.stopWatching(tabID: tab.id)
        TranscriptStore.shared.stopWatching(tabID: tab.id)
    }

    @Test func startingFreshDropsTheResumeLinkAndTheTitle() throws {
        let context = try context()
        let task = TaskStore.createTask(in: context, siblings: [])
        let tab = try #require(task.tabs.first)
        defer { forgetSharedState(of: tab) }
        tab.agentSessionID = "session-abc"
        tab.sessionJSONLPath = "/tmp/session-abc.jsonl"
        tab.title = "Old conversation"
        tab.titleSource = .reply
        TitleStore.shared.setTitle("Old conversation", forTab: tab.id, source: .reply)

        TaskStore.startFresh(tab)

        #expect(tab.agentSessionID == nil)
        #expect(tab.sessionJSONLPath == nil)
        #expect(TitleStore.shared.title(forTab: tab.id) == nil)
        #expect(TitleStore.shared.source(forTab: tab.id) == nil)
    }

    /// Without nilling `sessionJSONLPath`, a resume picker choosing the same
    /// session Start Fresh discarded would assign the identical path it
    /// already had, which SwiftUI's `.onChange` reads as no change at all —
    /// the watch it exists to re-register would never fire.
    @Test func nillingTheTranscriptPathMakesAResumeOfTheSameSessionARealChange() throws {
        let context = try context()
        let task = TaskStore.createTask(in: context, siblings: [])
        let tab = try #require(task.tabs.first)
        defer { forgetSharedState(of: tab) }
        let path = "/tmp/session-abc.jsonl"
        tab.agentSessionID = "session-abc"
        tab.sessionJSONLPath = path

        TaskStore.startFresh(tab)
        let pathBeforeResume = tab.sessionJSONLPath
        tab.sessionJSONLPath = path

        #expect(pathBeforeResume == nil)
        #expect(pathBeforeResume != tab.sessionJSONLPath)
    }

    /// `HeadlessSession` spawns no process until `start(...)` runs, so
    /// `AgentSessionManager.session(for:)` alone is enough to stand in for
    /// a live session here without a real `claude` process.
    @Test func startingFreshWithALiveSessionOnlyDropsTheResumeLink() throws {
        let context = try context()
        let task = TaskStore.createTask(in: context, siblings: [])
        let tab = try #require(task.tabs.first)
        defer { forgetSharedState(of: tab) }
        tab.agentSessionID = "session-abc"
        tab.sessionJSONLPath = "/tmp/session-abc.jsonl"
        tab.title = "Old conversation"
        tab.titleSource = .reply
        TitleStore.shared.setTitle("Old conversation", forTab: tab.id, source: .reply)
        _ = AgentSessionManager.shared.session(for: tab.id, taskID: task.id)
        defer { AgentSessionManager.shared.closeSession(for: tab.id) }

        TaskStore.startFresh(tab)

        #expect(tab.agentSessionID == nil)
        #expect(tab.sessionJSONLPath == "/tmp/session-abc.jsonl")
        #expect(TitleStore.shared.title(forTab: tab.id) == "Old conversation")
        #expect(TitleStore.shared.source(forTab: tab.id) == .reply)
    }

    /// The live-session path leaves the old title in place, so what stops it
    /// outranking the next conversation after a relaunch is the seed.
    @Test func aTabStartedFreshRestoresNoTitleSource() throws {
        let context = try context()
        let task = TaskStore.createTask(in: context, siblings: [])
        let tab = try #require(task.tabs.first)
        tab.agentSessionID = "session-abc"
        tab.titleSource = .reply
        _ = AgentSessionManager.shared.session(for: tab.id, taskID: task.id)
        defer { AgentSessionManager.shared.closeSession(for: tab.id) }

        TaskStore.startFresh(tab)

        #expect(tab.titleSource == .reply)
        #expect(tab.restorableTitleSource == nil)
    }
}
