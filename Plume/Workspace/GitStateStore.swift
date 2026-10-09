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

    /// Every tick runs one `git status` per watched directory, and a sidebar
    /// of worktrees watches dozens, so the sweep is priced per minute. The
    /// `.git` watcher still reports everything but working-tree edits promptly.
    static let pollInterval: TimeInterval = 60

    /// Long enough to collapse the burst of `.git` writes a single commit,
    /// checkout or fetch makes, short enough to feel immediate.
    static let debounce: Duration = .milliseconds(250)

    private struct Watch {
        var watcher: FileWatcher?
        var refCount: Int
    }

    /// Bookkeeping, deliberately not what rows read: `@Observable` tracks a
    /// whole dictionary, so a refcount or watcher write here would invalidate
    /// every row even when its answer is unchanged.
    @ObservationIgnored private var watches: [String: Watch] = [:]
    /// What the rows read, written only when the answer actually changes.
    ///
    /// Outlives a directory's watch. A sidebar row releases its watch when it
    /// scrolls out of the lazy list or its task is deselected, and it remounts
    /// often; dropping the answer there would blank the branch on every switch
    /// until a `git` call refilled it.
    private var states: [String: GitState] = [:]
    @ObservationIgnored private var pollTimer: Timer?
#if DEBUG
    /// Seeded states, for directories that have no repository on disk — a
    /// real `git` call there fails and would clear the fixture's branch.
    @ObservationIgnored private var fixtureStates: [String: GitState] = [:]
#endif
    @ObservationIgnored private var pending: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var inFlight: Set<String> = []

    init() {}

    func state(for directory: String?) -> GitState? {
        guard let directory else { return nil }
        return states[directory]
    }

    /// Begins watching a directory, or takes another reference to one already
    /// watched. Balance every call with `release(_:)`.
    func watch(_ directory: String) {
        if var existing = watches[directory] {
            existing.refCount += 1
            watches[directory] = existing
            return
        }

#if DEBUG
        if let seeded = fixtureStates[directory] {
            watches[directory] = Watch(watcher: nil, refCount: 1)
            publish(seeded, for: directory)
            return
        }
#endif
        watches[directory] = Watch(watcher: nil, refCount: 1)
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
#if DEBUG
        guard fixtureStates[directory] == nil else { return }
#endif
        // One `git` process per directory at a time. Without this a slow
        // repository would queue a subprocess per event behind the debounce.
        guard !inFlight.contains(directory) else { return }
        inFlight.insert(directory)
        Task {
            let state = await GitService.shared.state(in: directory)
            inFlight.remove(directory)
            guard watches[directory] != nil else { return }
            publish(state, for: directory)
        }
    }

    /// The `.git` watcher fires on every write inside `.git`, and an agent
    /// working in the repo makes many that leave the answer unchanged.
    /// Assigning anyway would invalidate every view reading `states`.
    private func publish(_ state: GitState?, for directory: String) {
        guard states[directory] != state else { return }
        states[directory] = state
    }

#if DEBUG
    /// Publishes `state` for `directory` with no `git` call, for the sidebar
    /// fixture catalog. Seeding before the row watches is what keeps the
    /// branch stable; `refresh` skips these directories thereafter.
    func seedFixture(directory: String, state: GitState) {
        fixtureStates[directory] = state
        if watches[directory] != nil { publish(state, for: directory) }
    }
#endif

    /// Drops a directory's watch whatever its refcount, and its last-known
    /// state, for a task being deleted out from under the row (and the
    /// startup warm pass) that took it.
    func forget(directory: String) {
        watches.removeValue(forKey: directory)?.watcher?.stop()
        pending.removeValue(forKey: directory)?.cancel()
        states.removeValue(forKey: directory)
        if watches.isEmpty {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }

    /// Drops every watch. For tests.
    func reset() {
        for watch in watches.values { watch.watcher?.stop() }
        for task in pending.values { task.cancel() }
        pending.removeAll()
        inFlight.removeAll()
        watches.removeAll()
        states.removeAll()
#if DEBUG
        fixtureStates.removeAll()
#endif
        pollTimer?.invalidate()
        pollTimer = nil
    }
}
