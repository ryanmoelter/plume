import Foundation
import os

/// Watches agent transcripts for the title Claude gives the session.
///
/// One watcher per agent tab, mirroring `AgentEventMonitor`. Transcripts are
/// written constantly but retitled rarely, so reads are debounced rather than
/// run on every write.
@MainActor
final class AgentTitleMonitor {
    static let shared = AgentTitleMonitor()

    private var watchers: [UUID: FileWatcher] = [:]
    private var paths: [UUID: String] = [:]
    private var pending: [UUID: Task<Void, Never>] = [:]
    private let debounce: Duration

    /// The last title reported for each tab, so a re-read that finds the
    /// same value again stays quiet. A transcript is written many times over
    /// one turn, and its title does not change nearly as often; this is
    /// dedup within one continuous watch, cleared on `stopWatching`/`stopAll`.
    /// It is not what keeps a stale re-read from overwriting a newer title —
    /// that guard is `TitleStore`'s source ranking.
    private var lastReported: [UUID: DiscoveredTitle] = [:]

    private struct DiscoveredTitle: Equatable {
        let title: String
        let source: TitleSource
    }

    /// Reports the title a tab's transcript carries, and its `TitleSource` —
    /// `.transcript` for a real `ai-title` line, `.fallback` for the
    /// first-message guess. `TitleStore.setTitle(_:forTab:source:)` uses the
    /// source to decide whether to accept it.
    var onTitleDiscovered: ((UUID, String, TitleSource) -> Void)?

    init(debounce: Duration = .seconds(1)) {
        self.debounce = debounce
    }

    /// Starts watching a tab's transcript and reads whatever title it already
    /// has. Re-pointing a tab at a different transcript replaces the watch.
    func watch(tabID: UUID, transcriptPath: String) {
        guard paths[tabID] != transcriptPath else {
            read(tabID: tabID)
            return
        }

        stopWatching(tabID: tabID)
        paths[tabID] = transcriptPath
        read(tabID: tabID)

        let watcher = FileWatcher(url: URL(fileURLWithPath: transcriptPath)) { [weak self] in
            self?.scheduleRead(tabID: tabID)
        }
        watcher.start()
        watchers[tabID] = watcher
    }

    func stopWatching(tabID: UUID) {
        watchers.removeValue(forKey: tabID)?.stop()
        pending.removeValue(forKey: tabID)?.cancel()
        paths.removeValue(forKey: tabID)
        lastReported.removeValue(forKey: tabID)
    }

    func stopAll() {
        for watcher in watchers.values { watcher.stop() }
        for task in pending.values { task.cancel() }
        watchers.removeAll()
        pending.removeAll()
        paths.removeAll()
        lastReported.removeAll()
    }

    private func scheduleRead(tabID: UUID) {
        pending[tabID]?.cancel()
        pending[tabID] = Task { [debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            read(tabID: tabID)
        }
    }

    private func read(tabID: UUID) {
        guard let onTitleDiscovered else { return }
        guard let path = paths[tabID], let data = FileManager.default.contents(atPath: path) else { return }
        let discovered: DiscoveredTitle
        if let title = SessionJSONLReader.latestAITitle(in: data) {
            discovered = DiscoveredTitle(title: title, source: .transcript)
        } else if let title = SessionJSONLReader.firstUserMessage(in: data) {
            discovered = DiscoveredTitle(title: title, source: .fallback)
        } else {
            return
        }
        guard lastReported[tabID] != discovered else { return }
        lastReported[tabID] = discovered
        onTitleDiscovered(tabID, discovered.title, discovered.source)
    }
}
