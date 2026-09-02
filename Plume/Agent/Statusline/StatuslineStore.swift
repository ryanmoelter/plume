import Foundation

/// Watches each tab's captured statusline payload and publishes the latest
/// decode, mirroring `AgentTitleMonitor`'s one-watcher-per-tab shape.
///
/// The file only exists, and only updates, while statusline capture is
/// installed and Claude Code is actively rendering a statusline — so a tab
/// with no payload yet is a normal, expected state, not an error.
@MainActor
@Observable
final class StatuslineStore {
    static let shared = StatuslineStore()

    private var watchers: [UUID: FileWatcher] = [:]
    private var paths: [UUID: URL] = [:]
    private var pending: [UUID: Task<Void, Never>] = [:]
    private var payloads: [UUID: StatuslinePayload] = [:]
    private let debounce: Duration

    init(debounce: Duration = .milliseconds(300)) {
        self.debounce = debounce
    }

    /// Starts watching a tab's capture file and reads whatever it already
    /// holds. Safe to call repeatedly for the same tab.
    func watch(tabID: UUID, taskID: UUID) {
        let url = AppPaths.statuslineFile(taskID: taskID, tabID: tabID)
        guard paths[tabID] != url else { return }

        stopWatching(tabID: tabID)
        paths[tabID] = url
        read(tabID: tabID)

        let watcher = FileWatcher(url: url) { [weak self] in
            self?.scheduleRead(tabID: tabID)
        }
        watcher.start()
        watchers[tabID] = watcher
    }

    func stopWatching(tabID: UUID) {
        watchers.removeValue(forKey: tabID)?.stop()
        pending.removeValue(forKey: tabID)?.cancel()
        paths.removeValue(forKey: tabID)
        payloads.removeValue(forKey: tabID)
    }

    func stopAll() {
        for watcher in watchers.values { watcher.stop() }
        for task in pending.values { task.cancel() }
        watchers.removeAll()
        pending.removeAll()
        paths.removeAll()
        payloads.removeAll()
    }

    func payload(forTab tabID: UUID) -> StatuslinePayload? {
        payloads[tabID]
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
        guard let url = paths[tabID],
              let data = try? Data(contentsOf: url),
              !data.isEmpty,
              let payload = try? JSONDecoder().decode(StatuslinePayload.self, from: data)
        else { return }
        guard payloads[tabID] != payload else { return }
        payloads[tabID] = payload
    }
}
