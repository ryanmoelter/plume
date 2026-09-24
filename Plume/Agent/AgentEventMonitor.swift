import Foundation
import os

/// Feeds hook events into the status engine.
///
/// One watcher per agent tab. Watching starts when a tab is instrumented and
/// on app launch for tabs with existing event files, so events written while
/// Plume was closed replay before any status is shown.
@MainActor
final class AgentEventMonitor {
    static let shared = AgentEventMonitor()

    private let ingester = HookEventIngester()
    private var watchers: [UUID: FileWatcher] = [:]
    private let statusEngine: StatusEngine

    /// Reports the session ID a tab's events carry, for `--resume`.
    var onSessionIDDiscovered: ((UUID, String) -> Void)?

    /// Reports that a tab's conversation was cleared, and the discarded
    /// session's own ID. Never fires for a clear read during the initial
    /// backlog drain `watch` does on every launch — only for one read live,
    /// off a running watch.
    var onSessionCleared: ((UUID, String?) -> Void)?

    /// Reports the tab's transcript file, cached for the future chat renderer.
    var onTranscriptPathDiscovered: ((UUID, String) -> Void)?

    init(statusEngine: StatusEngine = .shared) {
        self.statusEngine = statusEngine
    }

    /// Starts watching a tab's events file and drains anything already in it.
    func watch(taskID: UUID, tabID: UUID) {
        let url = AppPaths.eventsFile(taskID: taskID, tabID: tabID)
        drain(url: url, taskID: taskID, tabID: tabID, isReplay: true)

        guard watchers[tabID] == nil else { return }
        let watcher = FileWatcher(url: url) { [weak self] in
            self?.drain(url: url, taskID: taskID, tabID: tabID, isReplay: false)
        }
        watcher.start()
        watchers[tabID] = watcher
    }

    func stopWatching(tabID: UUID) {
        watchers.removeValue(forKey: tabID)?.stop()
    }

    func stopAll() {
        for watcher in watchers.values { watcher.stop() }
        watchers.removeAll()
    }

    private func drain(url: URL, taskID: UUID, tabID: UUID, isReplay: Bool) {
        let events = ingester.readNewEvents(at: url)
        guard !events.isEmpty else { return }

        for event in events {
            statusEngine.apply(event, taskID: taskID, tabID: tabID)
            if event.endsClearedSession {
                // A launch replays a tab's whole unread backlog in one drain,
                // which can include a `/clear` from long before this process
                // started. Reporting that here would apply it against
                // whatever session the tab is on now rather than the one it
                // was for — so only a clear read live, off a running watch,
                // is ever reported. Either way the `SessionStart` that
                // follows brings the replacement session ID on its own.
                if !isReplay {
                    onSessionCleared?(tabID, event.sessionID)
                }
                continue
            }
            if let sessionID = event.sessionID, !sessionID.isEmpty {
                onSessionIDDiscovered?(tabID, sessionID)
            }
            if let transcript = SessionJSONLReader.resolveTranscriptPath(
                hookProvided: event.transcriptPath,
                workingDirectory: event.cwd,
                sessionID: event.sessionID
            ) {
                onTranscriptPathDiscovered?(tabID, transcript)
            }
        }
        ingester.rotateIfNeeded(at: url)

        let status = statusEngine.status(forTask: taskID)
        Log.agent.info(
            "Ingested \(events.count) event(s) for tab \(tabID, privacy: .public); task status \(status.rawValue, privacy: .public)"
        )
    }
}
