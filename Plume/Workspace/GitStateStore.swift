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

    /// Long enough to collapse the burst of `.git` writes a single commit,
    /// checkout or fetch makes, short enough to feel immediate.
    static let debounce: Duration = .milliseconds(250)

    private struct Watch {
        var state: GitState?
        var watcher: FileWatcher?
        var refCount: Int
    }

    private var watches: [String: Watch] = [:]
    private var pollTimer: Timer?
    private var pending: [String: Task<Void, Never>] = [:]
    private var inFlight: Set<String> = []

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
            pending.removeValue(forKey: directory)?.cancel()
            watches.removeValue(forKey: directory)
        } else {
            watches[directory] = existing
        }
        if watches.isEmpty {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }

    /// Watching the git directory catches the ref and index writes a commit,
    /// checkout or fetch makes. Working-tree edits touch none of them, which
    /// is what the poll is for.
    ///
    /// It comes from `rev-parse --absolute-git-dir` rather than
    /// `<root>/.git`: in a linked worktree that path is a pointer file that
    /// never changes, so watching it would leave the worktree's state as
    /// stale as the poll.
    private func startWatching(_ directory: String) {
        Task {
            guard let resolved = await GitService.shared.gitDirectory(containing: directory) else {
                return
            }
            let gitDirectory = URL(fileURLWithPath: resolved)
            guard FileManager.default.fileExists(atPath: gitDirectory.path) else { return }
            // The watch may have been dropped while the probe was running.
            guard watches[directory] != nil else { return }

            // Debounced: an agent working in the repo writes to `.git` — index,
            // lock files, refs, logs — many times a second, and each write would
            // otherwise spawn its own `git status`.
            let watcher = FileWatcher(url: gitDirectory) { [weak self] in
                Task { @MainActor in self?.scheduleRefresh(directory) }
            }
            watcher.start()
            watches[directory]?.watcher = watcher
        }
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

    private func scheduleRefresh(_ directory: String) {
        pending[directory]?.cancel()
        pending[directory] = Task { [debounce = Self.debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            refresh(directory)
        }
    }

    /// Runs `git` on `GitService`, then publishes on the main actor.
    private func refresh(_ directory: String) {
        // One `git` process per directory at a time. Without this a slow
        // repository would queue a subprocess per event behind the debounce.
        guard !inFlight.contains(directory) else { return }
        inFlight.insert(directory)
        Task {
            let state = await GitService.shared.state(in: directory)
            inFlight.remove(directory)
            guard let existing = watches[directory] else { return }
            // The `.git` watcher fires on every write inside `.git`, and an
            // agent working in the repo makes many that leave this answer
            // unchanged. Assigning anyway would publish an observable change
            // and invalidate every view reading it.
            guard existing.state != state else { return }
            watches[directory]?.state = state
        }
    }

    /// Drops every watch. For tests.
    func reset() {
        for watch in watches.values { watch.watcher?.stop() }
        for task in pending.values { task.cancel() }
        pending.removeAll()
        inFlight.removeAll()
        watches.removeAll()
        pollTimer?.invalidate()
        pollTimer = nil
    }
}
