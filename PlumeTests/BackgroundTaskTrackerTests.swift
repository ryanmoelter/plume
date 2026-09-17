import Foundation
import Testing
@testable import Plume

/// The tracker decides how long a background task may hold the Mac awake, and
/// the scanner decides which tasks a transcript still says are running.
@MainActor
struct BackgroundTaskTrackerTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func entry(
        id: String = "b1",
        kind: BackgroundTaskTracker.Kind = .monitor,
        expiresIn: TimeInterval? = nil
    ) -> BackgroundTaskTracker.Entry {
        BackgroundTaskTracker.Entry(
            id: id,
            kind: kind,
            startedAt: start,
            expiresAt: expiresIn.map { start.addingTimeInterval($0) }
        )
    }

    // MARK: - Expiry

    @Test func aTaskHoldsUntilItsDeclaredExpiry() {
        let tracker = BackgroundTaskTracker()
        let tabID = UUID()
        tracker.replace(tabID: tabID, entries: [entry(expiresIn: 25 * 60)])

        #expect(tracker.inFlight(tabID: tabID, now: start.addingTimeInterval(24 * 60)).count == 1)
        #expect(tracker.inFlight(tabID: tabID, now: start.addingTimeInterval(26 * 60)).isEmpty)
    }

    /// A persistent monitor declares nothing, so only the cap stops it.
    @Test func aTaskWithNoExpiryStopsAtTheHardCap() {
        let tracker = BackgroundTaskTracker()
        let tabID = UUID()
        tracker.replace(tabID: tabID, entries: [entry()])

        #expect(tracker.inFlight(tabID: tabID, now: start.addingTimeInterval(29 * 60)).count == 1)
        #expect(tracker.inFlight(tabID: tabID, now: start.addingTimeInterval(31 * 60)).isEmpty)
    }

    @Test func theCapWinsOverALongerDeclaration() {
        let tracker = BackgroundTaskTracker()
        let tabID = UUID()
        tracker.replace(tabID: tabID, entries: [entry(expiresIn: 60 * 60)])

        #expect(tracker.inFlight(tabID: tabID, now: start.addingTimeInterval(31 * 60)).isEmpty)
    }

    // MARK: - Storage

    @Test func replacingWithNothingClearsTheTab() {
        let tracker = BackgroundTaskTracker()
        let tabID = UUID()
        tracker.replace(tabID: tabID, entries: [entry()])
        tracker.replace(tabID: tabID, entries: [])

        #expect(tracker.inFlight(tabID: tabID, now: start).isEmpty)
    }

    @Test func forgettingAndResettingBothClear() {
        let tracker = BackgroundTaskTracker()
        let first = UUID()
        let second = UUID()
        tracker.replace(tabID: first, entries: [entry()])
        tracker.replace(tabID: second, entries: [entry(id: "b2")])

        tracker.forget(tabID: first)
        #expect(tracker.inFlight(tabID: first, now: start).isEmpty)
        #expect(tracker.inFlight(tabID: second, now: start).count == 1)

        tracker.reset()
        #expect(tracker.inFlight(tabID: second, now: start).isEmpty)
    }

    /// One reason per tab however many tasks it is running, so the panel
    /// never lists the same tab twice. `tabsWithBackgroundTasks` reads the
    /// real clock, so these have to start now rather than at `start`.
    @Test func aTabWithSeveralTasksReportsOnce() {
        let tracker = BackgroundTaskTracker()
        let tabID = UUID()
        let now = Date()
        tracker.replace(tabID: tabID, entries: [
            BackgroundTaskTracker.Entry(id: "b1", kind: .monitor, startedAt: now, expiresAt: nil),
            BackgroundTaskTracker.Entry(id: "b2", kind: .backgroundCommand, startedAt: now, expiresAt: nil),
        ])

        #expect(tracker.tabsWithBackgroundTasks.count == 1)
    }

    // MARK: - Scanning

    private func transcript(_ lines: [String]) -> Data {
        Data(lines.joined(separator: "\n").utf8)
    }

    private func toolUse(id: String, name: String, background: Bool? = nil) -> String {
        let input = background.map { #"{"run_in_background":\#($0)}"# } ?? "{}"
        return """
        {"type":"assistant","timestamp":"2023-11-14T22:13:20.000Z","message":{"role":"assistant","content":\
        [{"type":"tool_use","id":"\(id)","name":"\(name)","input":\(input)}]}}
        """
    }

    private func toolResult(id: String, text: String) -> String {
        let escaped = text.replacingOccurrences(of: "\"", with: "\\\"")
        return """
        {"type":"user","timestamp":"2023-11-14T22:13:20.000Z","message":{"role":"user","content":\
        [{"type":"tool_result","tool_use_id":"\(id)","content":"\(escaped)"}]}}
        """
    }

    private func notification(_ body: String) -> String {
        let escaped = body
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return #"{"type":"queue-operation","operation":"enqueue","content":"\#(escaped)"}"#
    }

    private var monitorStart: [String] {
        [
            toolUse(id: "toolu_1", name: "Monitor"),
            toolResult(id: "toolu_1", text: "Monitor started (task b5vvlcw8f, timeout 1800000ms)."),
        ]
    }

    @Test func aStartedMonitorIsInFlight() throws {
        let entries = BackgroundTaskScanner.inFlight(parentData: transcript(monitorStart))

        #expect(entries.count == 1)
        #expect(entries.first?.id == "b5vvlcw8f")
        #expect(entries.first?.kind == .monitor)
    }

    @Test func aTerminalNotificationClearsIt() {
        let entries = BackgroundTaskScanner.inFlight(parentData: transcript(monitorStart + [
            notification("""
            <task-notification>
            <task-id>b5vvlcw8f</task-id>
            <status>completed</status>
            <summary>Monitor stream ended</summary>
            </task-notification>
            """),
        ]))

        #expect(entries.isEmpty)
    }

    /// A monitor fires a notification per event, and those carry no status —
    /// the task is still running.
    @Test func anEventNotificationLeavesItRunning() {
        let entries = BackgroundTaskScanner.inFlight(parentData: transcript(monitorStart + [
            notification("""
            <task-notification>
            <task-id>b5vvlcw8f</task-id>
            <summary>Monitor event: "the build"</summary>
            <event>build finished</event>
            </task-notification>
            """),
        ]))

        #expect(entries.count == 1)
    }

    @Test(arguments: ["failed", "killed", "stopped"])
    func anyTerminalStatusClearsIt(status: String) {
        let entries = BackgroundTaskScanner.inFlight(parentData: transcript(monitorStart + [
            notification("<task-notification><task-id>b5vvlcw8f</task-id><status>\(status)</status></task-notification>"),
        ]))

        #expect(entries.isEmpty)
    }

    @Test func aNotificationForAnotherTaskClearsNothing() {
        let entries = BackgroundTaskScanner.inFlight(parentData: transcript(monitorStart + [
            notification("<task-notification><task-id>bsomethingelse</task-id><status>completed</status></task-notification>"),
        ]))

        #expect(entries.count == 1)
    }

    /// One notification can close several tasks at once — a session ending
    /// reports all of its orphans together.
    @Test func aNotificationNamingSeveralTasksClearsThemAll() {
        let entries = BackgroundTaskScanner.inFlight(parentData: transcript([
            toolUse(id: "toolu_1", name: "Monitor"),
            toolResult(id: "toolu_1", text: "Monitor started (task b1, timeout 1800000ms)."),
            toolUse(id: "toolu_2", name: "Bash", background: true),
            toolResult(id: "toolu_2", text: "Command running in background with ID: b2."),
            notification("""
            <task-notification>
            <task-id>b1</task-id>
            <task-id>b2</task-id>
            <status>stopped</status>
            </task-notification>
            """),
        ]))

        #expect(entries.isEmpty)
    }

    @Test func aForegroundCommandIsNotTracked() {
        let entries = BackgroundTaskScanner.inFlight(parentData: transcript([
            toolUse(id: "toolu_1", name: "Bash", background: false),
            toolResult(id: "toolu_1", text: "Command running in background with ID: b9."),
        ]))

        #expect(entries.isEmpty)
    }

    /// Background subagents already keep their tab working through
    /// `TranscriptStore`, so tracking them here too would hold the Mac awake
    /// for the same work twice.
    @Test func aBackgroundAgentIsLeftToTheSubagentList() {
        let entries = BackgroundTaskScanner.inFlight(parentData: transcript([
            toolUse(id: "toolu_1", name: "Agent", background: true),
            toolResult(id: "toolu_1", text: "Async agent launched successfully. agentId: a12345 (Do the thing)"),
        ]))

        #expect(entries.isEmpty)
    }

    /// The entry's clock comes from the line that recorded the launch, so a
    /// transcript read hours later does not restart the expiry.
    @Test func theClockStartsWhenTheTranscriptSaysItDid() throws {
        let entries = BackgroundTaskScanner.inFlight(
            parentData: transcript(monitorStart),
            now: Date(timeIntervalSince1970: 2_000_000_000)
        )
        let entry = try #require(entries.first)

        #expect(entry.startedAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(entry.expiresAt == entry.startedAt.addingTimeInterval(1800))
    }
}
