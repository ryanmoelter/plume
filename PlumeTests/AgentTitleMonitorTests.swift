import Testing
import Foundation
@testable import Plume

/// `onTitleDiscovered` reports a title's `TitleSource`, which is what lets
/// `TitleStore` refuse a fallback or a stale transcript read that would
/// otherwise overwrite a higher-ranked title a control response already set
/// (`TitleStoreTests.aReplyTitleSurvivesAStaleTranscriptAfterARewatch`).
@MainActor
struct AgentTitleMonitorTests {
    private func write(_ lines: [String], to existing: URL? = nil) throws -> URL {
        let url = existing ?? URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "plume-title-monitor-\(UUID().uuidString).jsonl")
        try Data(lines.joined(separator: "\n").utf8).write(to: url)
        return url
    }

    /// Runs `body`, then waits for `count` reads to settle. Reads run off the
    /// main actor, so nothing is reported by the time `watch` returns.
    private func settle(_ monitor: AgentTitleMonitor, reads count: Int, _ body: () throws -> Void) async rethrows {
        var settled = 0
        var waiting: CheckedContinuation<Void, Never>?
        monitor.didRead = { _ in
            settled += 1
            if settled >= count, let continuation = waiting {
                waiting = nil
                continuation.resume()
            }
        }
        try body()
        if settled < count {
            await withCheckedContinuation { waiting = $0 }
        }
        monitor.didRead = nil
    }

    @Test func anAITitleReportsAsTranscriptSourced() async throws {
        let url = try write([
            #"{"type":"user","isSidechain":false,"message":{"role":"user","content":"Fix the login bug"}}"#,
            #"{"type":"ai-title","aiTitle":"Fixing login","sessionId":"a"}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let monitor = AgentTitleMonitor()
        var discovered: (title: String, source: TitleSource)?
        monitor.onTitleDiscovered = { _, title, source in discovered = (title, source) }

        await settle(monitor, reads: 1) { monitor.watch(tabID: UUID(), transcriptPath: url.path) }

        #expect(discovered?.title == "Fixing login")
        #expect(discovered?.source == .transcript)
    }

    @Test func theFirstMessageFallbackReportsAsFallbackSourced() async throws {
        let url = try write([
            #"{"type":"user","isSidechain":false,"message":{"role":"user","content":"Fix the login bug"}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let monitor = AgentTitleMonitor()
        var discovered: (title: String, source: TitleSource)?
        monitor.onTitleDiscovered = { _, title, source in discovered = (title, source) }

        await settle(monitor, reads: 1) { monitor.watch(tabID: UUID(), transcriptPath: url.path) }

        #expect(discovered?.title == "Fix the login bug")
        #expect(discovered?.source == .fallback)
    }

    @Test func aRepeatedReadOfTheSameTitleReportsOnlyOnce() async throws {
        let url = try write([
            #"{"type":"user","isSidechain":false,"message":{"role":"user","content":"Fix the login bug"}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let monitor = AgentTitleMonitor()
        var reportCount = 0
        monitor.onTitleDiscovered = { _, _, _ in reportCount += 1 }

        let tab = UUID()
        await settle(monitor, reads: 2) {
            monitor.watch(tabID: tab, transcriptPath: url.path)
            monitor.watch(tabID: tab, transcriptPath: url.path)
        }

        #expect(reportCount == 1)
    }

    @Test func aReadWithNoCallbackRecordsNothingSoTheNextReadWithOneStillReports() async throws {
        let url = try write([
            #"{"type":"user","isSidechain":false,"message":{"role":"user","content":"Fix the login bug"}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let monitor = AgentTitleMonitor()
        let tab = UUID()
        monitor.watch(tabID: tab, transcriptPath: url.path)

        var reportCount = 0
        monitor.onTitleDiscovered = { _, _, _ in reportCount += 1 }
        await settle(monitor, reads: 1) { monitor.watch(tabID: tab, transcriptPath: url.path) }

        #expect(reportCount == 1)
    }

    @Test func unwatchingForgetsTheLastReportedTitleSoTheNextWatchReportsAgain() async throws {
        let url = try write([
            #"{"type":"user","isSidechain":false,"message":{"role":"user","content":"Fix the login bug"}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let monitor = AgentTitleMonitor()
        var reportCount = 0
        monitor.onTitleDiscovered = { _, _, _ in reportCount += 1 }

        let tab = UUID()
        await settle(monitor, reads: 1) { monitor.watch(tabID: tab, transcriptPath: url.path) }
        monitor.stopWatching(tabID: tab)
        await settle(monitor, reads: 1) { monitor.watch(tabID: tab, transcriptPath: url.path) }

        #expect(reportCount == 2)
    }

    @Test func aReadStillInFlightWhenTheWatchStopsReportsNothing() async throws {
        let url = try write([
            #"{"type":"user","isSidechain":false,"message":{"role":"user","content":"Fix the login bug"}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let monitor = AgentTitleMonitor()
        var reportCount = 0
        monitor.onTitleDiscovered = { _, _, _ in reportCount += 1 }

        let tab = UUID()
        await settle(monitor, reads: 1) {
            monitor.watch(tabID: tab, transcriptPath: url.path)
            monitor.stopWatching(tabID: tab)
        }

        #expect(reportCount == 0)
    }

    @Test func aReadRequestedMidReadRunsAgainAndReportsTheNewerTitle() async throws {
        let url = try write([
            #"{"type":"user","isSidechain":false,"message":{"role":"user","content":"Fix the login bug"}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let monitor = AgentTitleMonitor()
        var discovered: String?
        monitor.onTitleDiscovered = { _, title, _ in discovered = title }

        let tab = UUID()
        try await settle(monitor, reads: 2) {
            monitor.watch(tabID: tab, transcriptPath: url.path)
            _ = try write([
                #"{"type":"user","isSidechain":false,"message":{"role":"user","content":"Fix the login bug"}}"#,
                #"{"type":"ai-title","aiTitle":"Fixing login","sessionId":"a"}"#,
            ], to: url)
            monitor.watch(tabID: tab, transcriptPath: url.path)
        }

        #expect(discovered == "Fixing login")
    }
}
