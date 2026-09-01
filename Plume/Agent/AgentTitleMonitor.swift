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

    /// Reports the title a tab's transcript carries.
    var onTitleDiscovered: ((UUID, String) -> Void)?

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
    }

    func stopAll() {
        for watcher in watchers.values { watcher.stop() }
        for task in pending.values { task.cancel() }
        watchers.removeAll()
        pending.removeAll()
        paths.removeAll()
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
        guard let path = paths[tabID],
              let title = SessionJSONLReader.latestAITitle(atPath: path)
        else { return }
        onTitleDiscovered?(tabID, title)
    }
}
