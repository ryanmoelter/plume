import Foundation
import Testing
@testable import Plume

/// A headless tab's background tasks come from the CLI's
/// `background_tasks_changed` list: a task runs exactly as long as the list
/// names it, with no time limit, and the transcript only fills in its kind and
/// start. The payloads are real, from the probe in docs/headless-protocol.md.
@MainActor
struct LiveBackgroundTaskTests {
    private static let sleepStarted = #"{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"b5b6p3ipm","run_id":"0muyhepps-9ba3eac4","task_type":"local_bash","description":"Sleep in background"}],"uuid":"981aea64-e8a9-4fb8-bd50-4fdfa5d057ec","session_id":"58731551-09b2-44ab-a75a-ae80694b1698"}"#
    private static let monitorStarted = #"{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"b5b6p3ipm","run_id":"0muyhepps-9ba3eac4","task_type":"local_bash","description":"Sleep in background"},{"task_id":"bmzg7xfjs","run_id":"0muyheqxb-d628cb7a","task_type":"local_bash","description":"clock"}],"uuid":"7bf8d30a-29c6-47a1-949d-14cb1b0e8778","session_id":"58731551-09b2-44ab-a75a-ae80694b1698"}"#
    private static let sleepEnded = #"{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"bmzg7xfjs","run_id":"0muyheqxb-d628cb7a","task_type":"local_bash","description":"clock"}],"uuid":"09bb7966-3458-4a0d-92e6-6da2b2c710f2","session_id":"58731551-09b2-44ab-a75a-ae80694b1698"}"#
    private static let monitorStopped = #"{"type":"system","subtype":"background_tasks_changed","tasks":[],"uuid":"f85e9310-5fd8-4575-803f-5027c3e3b599","session_id":"58731551-09b2-44ab-a75a-ae80694b1698"}"#

    private func message(_ line: String) throws -> StreamJSONMessage {
        try #require(StreamJSONDecoder.decode(line: line))
    }

    private func tasks(_ line: String) throws -> [LiveBackgroundTask] {
        guard case .backgroundTasksChanged(let tasks) = try message(line) else {
            Issue.record("expected backgroundTasksChanged")
            return []
        }
        return tasks
    }

    // MARK: - Decoding

    @Test func theListDecodesEveryTask() throws {
        #expect(try tasks(Self.monitorStarted) == [
            LiveBackgroundTask(id: "b5b6p3ipm", taskType: "local_bash", description: "Sleep in background"),
            LiveBackgroundTask(id: "bmzg7xfjs", taskType: "local_bash", description: "clock"),
        ])
    }

    @Test func anEmptyListDecodesAsEmpty() throws {
        #expect(try tasks(Self.monitorStopped).isEmpty)
    }

    @Test func aListWithoutTasksStaysUnknown() throws {
        guard case .unknown(let type) = try message(#"{"type":"system","subtype":"background_tasks_changed"}"#) else {
            Issue.record("expected unknown")
            return
        }
        #expect(type == "system")
    }

    @Test func subagentsAreNotTracked() {
        #expect(LiveBackgroundTask(id: "a", taskType: "local_agent", description: nil).trackedKind == nil)
        #expect(LiveBackgroundTask(id: "a", taskType: "local_bash", description: nil).trackedKind == .backgroundCommand)
        #expect(LiveBackgroundTask(id: "a", taskType: "local_workflow", description: nil).trackedKind == .workflow)
    }

    // MARK: - Tracker

    private func entry(_ id: String, kind: BackgroundTaskTracker.Kind = .backgroundCommand, startedAt: Date, expiresAt: Date? = nil) -> BackgroundTaskTracker.Entry {
        BackgroundTaskTracker.Entry(id: id, kind: kind, startedAt: startedAt, expiresAt: expiresAt)
    }

    @Test func aLiveTaskOutlastsTheHardCap() {
        let tracker = BackgroundTaskTracker()
        let tabID = UUID()
        let start = Date()
        tracker.replaceLive(tabID: tabID, entries: [entry("b1", startedAt: start)])

        let later = start.addingTimeInterval(BackgroundTaskTracker.hardCap * 4)
        #expect(tracker.inFlight(tabID: tabID, now: later).map(\.id) == ["b1"])
    }

    /// The transcript can still read a task as running after the CLI has
    /// dropped it, which is exactly the case the live list exists to settle.
    @Test func anEmptyLiveListOverridesTheTranscript() {
        let tracker = BackgroundTaskTracker()
        let tabID = UUID()
        let now = Date()
        tracker.replace(tabID: tabID, entries: [entry("b1", kind: .monitor, startedAt: now)])
        tracker.replaceLive(tabID: tabID, entries: [])

        #expect(tracker.inFlight(tabID: tabID).isEmpty)
        #expect(tracker.tabsWithBackgroundTasks.isEmpty)
    }

    @Test func theTranscriptSuppliesKindAndStart() {
        let tracker = BackgroundTaskTracker()
        let tabID = UUID()
        let launched = Date().addingTimeInterval(-60)
        let expiry = launched.addingTimeInterval(BackgroundTaskTracker.hardCap)
        tracker.replace(tabID: tabID, entries: [entry("b1", kind: .monitor, startedAt: launched, expiresAt: expiry)])
        tracker.replaceLive(tabID: tabID, entries: [
            BackgroundTaskTracker.Entry(id: "b1", kind: .backgroundCommand, description: "clock", startedAt: Date(), expiresAt: nil),
        ])

        let running = tracker.inFlight(tabID: tabID)
        #expect(running.map(\.kind) == [.monitor])
        #expect(running.map(\.description) == ["clock"])
        #expect(running.map(\.startedAt) == [launched])
    }

    @Test func aRepeatedLiveEntryKeepsItsFirstStart() {
        let tracker = BackgroundTaskTracker()
        let tabID = UUID()
        let first = Date().addingTimeInterval(-120)
        tracker.replaceLive(tabID: tabID, entries: [entry("b1", startedAt: first)])
        tracker.replaceLive(tabID: tabID, entries: [entry("b1", startedAt: Date()), entry("b2", startedAt: Date())])

        #expect(tracker.inFlight(tabID: tabID).first { $0.id == "b1" }?.startedAt == first)
    }

    @Test func forgettingALiveTabRestoresTheTranscript() {
        let tracker = BackgroundTaskTracker()
        let tabID = UUID()
        tracker.replaceLive(tabID: tabID, entries: [])
        tracker.forget(tabID: tabID)
        tracker.replace(tabID: tabID, entries: [entry("b1", startedAt: Date())])

        #expect(tracker.inFlight(tabID: tabID).map(\.id) == ["b1"])
    }

    @Test func aTabReportsHowManyTasksItRuns() {
        let tracker = BackgroundTaskTracker()
        let tabID = UUID()
        tracker.replaceLive(tabID: tabID, entries: [entry("b1", startedAt: Date()), entry("b2", startedAt: Date())])

        #expect(tracker.tabsWithBackgroundTasks.map(\.count) == [2])
    }

    // MARK: - Session

    private func makeSession(tracker: BackgroundTaskTracker) -> HeadlessSession {
        HeadlessSession(
            tabID: UUID(),
            taskID: UUID(),
            statusEngine: StatusEngine(backgroundTasks: tracker),
            backgroundTasks: tracker
        )
    }

    @Test func aTaskLeavingTheListLeavesTheTracker() throws {
        let tracker = BackgroundTaskTracker()
        let session = makeSession(tracker: tracker)

        session.handle(try message(Self.sleepStarted))
        session.handle(try message(Self.monitorStarted))
        #expect(Set(tracker.inFlight(tabID: session.tabID).map(\.id)) == ["b5b6p3ipm", "bmzg7xfjs"])

        session.handle(try message(Self.sleepEnded))
        #expect(tracker.inFlight(tabID: session.tabID).map(\.id) == ["bmzg7xfjs"])

        session.handle(try message(Self.monitorStopped))
        #expect(tracker.inFlight(tabID: session.tabID).isEmpty)
    }

    @Test func stoppingTheSessionClearsItsTasks() throws {
        let tracker = BackgroundTaskTracker()
        let session = makeSession(tracker: tracker)
        session.handle(try message(Self.monitorStarted))

        session.stop()

        #expect(tracker.inFlight(tabID: session.tabID).isEmpty)
    }

    @Test func aListArrivingAfterExitIsIgnored() throws {
        let tracker = BackgroundTaskTracker()
        let session = makeSession(tracker: tracker)
        session.stop()

        session.handle(try message(Self.monitorStarted))

        #expect(tracker.inFlight(tabID: session.tabID).isEmpty)
    }
}
