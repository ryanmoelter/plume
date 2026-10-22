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
    private var inFlight: Set<UUID> = []
    private var rereadRequested: Set<UUID> = []
    /// Bumped when a watch stops, so a read still in flight from before it
    /// cannot report into the next watch.
    private var watchGeneration: [UUID: Int] = [:]
    private let debounce: Duration

    /// Fires after every read settles, whether or not it reported a title.
    /// Tests await this rather than a clock.
    var didRead: ((UUID) -> Void)?

    /// The last title reported for each tab, so a re-read that finds the
    /// same value again stays quiet. A transcript is written many times over
    /// one turn, and its title does not change nearly as often; this is
    /// dedup within one continuous watch, cleared on `stopWatching`/`stopAll`.
    /// It is not what keeps a stale re-read from overwriting a newer title —
    /// that guard is `TitleStore`'s source ranking.
    private var lastReported: [UUID: DiscoveredTitle] = [:]

    private nonisolated struct DiscoveredTitle: Equatable, Sendable {
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

        let watcher = FileWatcher(url: URL(fileURLWithPath: transcriptPath), createsFile: false) { [weak self] in
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
        rereadRequested.remove(tabID)
        inFlight.remove(tabID)
        watchGeneration[tabID, default: 0] += 1
    }

    func stopAll() {
        for watcher in watchers.values { watcher.stop() }
        for task in pending.values { task.cancel() }
        watchers.removeAll()
        pending.removeAll()
        paths.removeAll()
        lastReported.removeAll()
        rereadRequested.removeAll()
        for tabID in inFlight { watchGeneration[tabID, default: 0] += 1 }
        inFlight.removeAll()
    }

    private func scheduleRead(tabID: UUID) {
        pending[tabID]?.cancel()
        pending[tabID] = Task { [debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            read(tabID: tabID)
        }
    }

    /// Reads and scans off the main actor: a transcript can be tens of
    /// megabytes, and this runs for every agent tab at launch and whenever a
    /// chat tab mounts. One read per tab at a time; a request that lands
    /// mid-read runs once more after it, so a title written meanwhile is not
    /// missed.
    private func read(tabID: UUID) {
        guard onTitleDiscovered != nil, let path = paths[tabID] else { return }
        guard !inFlight.contains(tabID) else {
            rereadRequested.insert(tabID)
            return
        }
        inFlight.insert(tabID)
        let generation = watchGeneration[tabID, default: 0]
        Task.detached(priority: .utility) {
            let discovered = Self.discoverTitle(atPath: path)
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard self.watchGeneration[tabID, default: 0] == generation else {
                    self.didRead?(tabID)
                    return
                }
                self.inFlight.remove(tabID)
                defer {
                    if self.rereadRequested.remove(tabID) != nil { self.read(tabID: tabID) }
                    self.didRead?(tabID)
                }
                guard self.paths[tabID] == path,
                      let discovered,
                      let onTitleDiscovered = self.onTitleDiscovered,
                      self.lastReported[tabID] != discovered
                else { return }
                self.lastReported[tabID] = discovered
                onTitleDiscovered(tabID, discovered.title, discovered.source)
            }
        }
    }

    private nonisolated static func discoverTitle(atPath path: String) -> DiscoveredTitle? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        if let title = SessionJSONLReader.latestAITitle(in: data) {
            return DiscoveredTitle(title: title, source: .transcript)
        }
        if let title = SessionJSONLReader.firstUserMessage(in: data) {
            return DiscoveredTitle(title: title, source: .fallback)
        }
        return nil
    }
}
