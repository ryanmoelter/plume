import Testing
import Foundation
@testable import Plume

/// `onTitleDiscovered` reports a title's `TitleSource`, which is what lets
/// `TitleStore` refuse a fallback or a stale transcript read that would
/// otherwise overwrite a higher-ranked title a control response already set
/// (`TitleStoreTests.aReplyTitleSurvivesAStaleTranscriptAfterARewatch`).
@MainActor
struct AgentTitleMonitorTests {
    private func write(_ lines: [String]) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "plume-title-monitor-\(UUID().uuidString).jsonl")
        try Data(lines.joined(separator: "\n").utf8).write(to: url)
        return url
    }

    @Test func anAITitleReportsAsTranscriptSourced() throws {
        let url = try write([
            #"{"type":"user","isSidechain":false,"message":{"role":"user","content":"Fix the login bug"}}"#,
            #"{"type":"ai-title","aiTitle":"Fixing login","sessionId":"a"}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let monitor = AgentTitleMonitor()
        var discovered: (title: String, source: TitleSource)?
        monitor.onTitleDiscovered = { _, title, source in discovered = (title, source) }

        monitor.watch(tabID: UUID(), transcriptPath: url.path)

        #expect(discovered?.title == "Fixing login")
        #expect(discovered?.source == .transcript)
    }

    @Test func theFirstMessageFallbackReportsAsFallbackSourced() throws {
        let url = try write([
            #"{"type":"user","isSidechain":false,"message":{"role":"user","content":"Fix the login bug"}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let monitor = AgentTitleMonitor()
        var discovered: (title: String, source: TitleSource)?
        monitor.onTitleDiscovered = { _, title, source in discovered = (title, source) }

        monitor.watch(tabID: UUID(), transcriptPath: url.path)

        #expect(discovered?.title == "Fix the login bug")
        #expect(discovered?.source == .fallback)
    }

    @Test func aRepeatedReadOfTheSameTitleReportsOnlyOnce() throws {
        let url = try write([
            #"{"type":"user","isSidechain":false,"message":{"role":"user","content":"Fix the login bug"}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let monitor = AgentTitleMonitor()
        var reportCount = 0
        monitor.onTitleDiscovered = { _, _, _ in reportCount += 1 }

        let tab = UUID()
        monitor.watch(tabID: tab, transcriptPath: url.path)
        monitor.watch(tabID: tab, transcriptPath: url.path)

        #expect(reportCount == 1)
    }

    @Test func aReadWithNoCallbackRecordsNothingSoTheNextReadWithOneStillReports() throws {
        let url = try write([
            #"{"type":"user","isSidechain":false,"message":{"role":"user","content":"Fix the login bug"}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let monitor = AgentTitleMonitor()
        let tab = UUID()
        monitor.watch(tabID: tab, transcriptPath: url.path)

        var reportCount = 0
        monitor.onTitleDiscovered = { _, _, _ in reportCount += 1 }
        monitor.watch(tabID: tab, transcriptPath: url.path)

        #expect(reportCount == 1)
    }

    @Test func unwatchingForgetsTheLastReportedTitleSoTheNextWatchReportsAgain() throws {
        let url = try write([
            #"{"type":"user","isSidechain":false,"message":{"role":"user","content":"Fix the login bug"}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let monitor = AgentTitleMonitor()
        var reportCount = 0
        monitor.onTitleDiscovered = { _, _, _ in reportCount += 1 }

        let tab = UUID()
        monitor.watch(tabID: tab, transcriptPath: url.path)
        monitor.stopWatching(tabID: tab)
        monitor.watch(tabID: tab, transcriptPath: url.path)

        #expect(reportCount == 2)
    }
}
