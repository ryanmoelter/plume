import Foundation
import Testing
@testable import Plume

/// What a `/clear` does to the session ID a tab would resume.
///
/// The events are verbatim copies of what Claude Code wrote during a real
/// clear: `SessionEnd` carrying the *old* ID, then `SessionStart` carrying
/// the new one. Writing them to the events file before `watch` is called (as
/// below) is what a launch's backlog replay looks like.
@MainActor
struct AgentClearTransitionTests {
    private let oldSessionID = "3176c2af-d557-46a8-8fe9-db44b1870211"
    private let newSessionID = "68b117c1-84b0-4772-b55d-1a217dbec8d4"

    private func sessionEndClear() -> String {
        #"{"session_id":"\#(oldSessionID)","transcript_path":"/t/old.jsonl","cwd":"/w","hook_event_name":"SessionEnd","reason":"clear"}"#
    }

    private func sessionStartClear() -> String {
        #"{"session_id":"\#(newSessionID)","transcript_path":"/t/new.jsonl","cwd":"/w","hook_event_name":"SessionStart","source":"clear"}"#
    }

    /// Runs the lines through a real monitor, wired the way `MainWindow`
    /// wires it, and reports the session ID a tab would be left holding.
    private func resumableSessionID(afterWriting lines: [String]) throws -> String? {
        let (taskID, tabID) = (UUID(), UUID())
        let url = AppPaths.eventsFile(taskID: taskID, tabID: tabID)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)

        var sessionID: String?
        let monitor = AgentEventMonitor(statusEngine: StatusEngine())
        monitor.onSessionIDDiscovered = { _, discovered in sessionID = discovered }
        monitor.onSessionCleared = { _, _ in sessionID = nil }
        monitor.watch(taskID: taskID, tabID: tabID)
        monitor.stopWatching(tabID: tabID)
        return sessionID
    }

    @Test func aClearLeavesTheTabOnTheNewConversation() throws {
        let resumable = try resumableSessionID(
            afterWriting: [sessionEndClear(), sessionStartClear()]
        )

        #expect(resumable == newSessionID)
    }

    /// If Plume dies between the two events, the tab must not be left holding
    /// the discarded conversation's ID — resuming it would restore exactly
    /// what the user threw away.
    @Test func aClearAloneLeavesNothingToResume() throws {
        let resumable = try resumableSessionID(afterWriting: [sessionEndClear()])

        #expect(resumable == nil)
        #expect(!AgentAutoResume.shouldResume(
            agentSessionID: resumable,
            workingDirectoryPath: "/w",
            hasExistingSurfaceSession: false,
            directoryExists: { _ in true }
        ))
    }

    /// The scenario `MainWindow`'s guard alone cannot catch: a launch
    /// replays `SessionStart(A)`, `clear(A)`, `SessionStart(B)` in one drain,
    /// so `agentSessionID` still equals A — the clear's own ID — by the time
    /// the replayed clear is read. Reporting it would be indistinguishable
    /// from a live clear, so `AgentEventMonitor` must withhold it itself.
    @Test func aReplayedClearNeverFiresOnSessionCleared() throws {
        let (taskID, tabID) = (UUID(), UUID())
        let url = AppPaths.eventsFile(taskID: taskID, tabID: tabID)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let lines = [sessionEndClear(), sessionStartClear()]
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)

        var clearedCount = 0
        let monitor = AgentEventMonitor(statusEngine: StatusEngine())
        monitor.onSessionCleared = { _, _ in clearedCount += 1 }
        monitor.watch(taskID: taskID, tabID: tabID)
        monitor.stopWatching(tabID: tabID)

        #expect(clearedCount == 0)
    }
}
