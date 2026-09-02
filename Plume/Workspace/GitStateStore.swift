import Foundation
import Observation

/// Keeps each watched directory's `GitState` current.
///
/// The answer changes from outside Plume — commits, fetches and edits all
/// happen in a terminal — so neither a watcher nor a poll is enough alone. A
/// watcher on `.git` catches commits, branch switches and fetches promptly;
/// a slow poll underneath catches working-tree edits, which touch no file
/// inside `.git`.
@MainActor
@Observable
final class GitStateStore {
    static let shared = GitStateStore()

    /// Slow enough to stay off the critical path, fast enough that a stale
    /// dirty flag is never surprising.
    static let pollInterval: TimeInterval = 15

    private struct Watch {
        var state: GitState?
        var watcher: FileWatcher?
        var refCount: Int
    }

    private var watches: [String: Watch] = [:]
    private var pollTimer: Timer?

    init() {}

    func state(for directory: String?) -> GitState? {
        guard let directory else { return nil }
        return watches[directory]?.state
    }

    /// Begins watching a directory, or takes another reference to one already
    /// watched. Balance every call with `release(_:)`.
    func watch(_ directory: String) {
        if var existing = watches[directory] {
            existing.refCount += 1
            watches[directory] = existing
            return
        }

        watches[directory] = Watch(state: nil, watcher: nil, refCount: 1)
        refresh(directory)
        startWatching(directory)
        startPollingIfNeeded()
    }

    func release(_ directory: String) {
        guard var existing = watches[directory] else { return }
        existing.refCount -= 1
        if existing.refCount <= 0 {
            existing.watcher?.stop()
            watches.removeValue(forKey: directory)
        } else {
            watches[directory] = existing
        }
        if watches.isEmpty {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }

    /// Watching `.git` itself catches the ref and index writes a commit,
    /// checkout or fetch makes. Working-tree edits touch none of them, which
    /// is what the poll is for.
    private func startWatching(_ directory: String) {
        guard let root = GitRunner.repositoryRoot(containing: directory) else { return }
        let gitDirectory = URL(fileURLWithPath: root).appendingPathComponent(".git")
        guard FileManager.default.fileExists(atPath: gitDirectory.path) else { return }

        let watcher = FileWatcher(url: gitDirectory) { [weak self] in
            Task { @MainActor in self?.refresh(directory) }
        }
        watcher.start()
        watches[directory]?.watcher = watcher
    }

    private func startPollingIfNeeded() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAll() }
        }
    }

    private func refreshAll() {
        for directory in watches.keys { refresh(directory) }
    }

    /// Runs `git` off the main actor, then publishes on it.
    private func refresh(_ directory: String) {
        Task.detached(priority: .utility) {
            let state = GitRunner.state(in: directory)
            await MainActor.run { [weak self] in
                guard let self, let existing = self.watches[directory] else { return }
                // The `.git` watcher fires on every write inside `.git`, and
                // an agent working in the repo makes many that leave this
                // answer unchanged. Assigning anyway would publish an
                // observable change and invalidate every view reading it.
                guard existing.state != state else { return }
                self.watches[directory]?.state = state
            }
        }
    }

    /// Drops every watch. For tests.
    func reset() {
        for watch in watches.values { watch.watcher?.stop() }
        watches.removeAll()
        pollTimer?.invalidate()
        pollTimer = nil
    }
}
