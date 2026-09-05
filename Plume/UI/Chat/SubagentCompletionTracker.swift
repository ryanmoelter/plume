import Foundation
import Observation

/// Remembers when Plume first saw each subagent finish, so a finished row can
/// linger in the live list before folding into the completed section.
///
/// Keyed by tab then by subagent id, and shared, because the chat view is
/// unmounted whenever the user selects another task: held in the view, both
/// the memory of when a row finished and the timer that moves it would be
/// thrown away, and coming back would restart every countdown.
///
/// The clock starts from the observation, never from the transcript's mtime:
/// a relaunch re-reads files that finished days ago, and dating them by their
/// own timestamps would collapse every row the instant the list appeared.
/// Nothing here is persisted for the same reason.
@MainActor
@Observable
final class SubagentCompletionTracker {
    static let shared = SubagentCompletionTracker()

    /// How long a finished subagent stays among the live rows, long enough to
    /// see it land.
    static let lingerDuration: Duration = .seconds(30)

    private struct Key: Hashable {
        let tabID: UUID
        let subagentID: String
    }

    private var completedAt: [Key: ContinuousClock.Instant] = [:]
    private var timers: [Key: Task<Void, Never>] = [:]
    /// Bumped when a linger elapses. `hasSettled` reads a clock rather than
    /// stored state, so without an observable change to depend on, SwiftUI
    /// would have no reason to re-render when the moment arrives.
    private var settledGeneration = 0
    private let linger: Duration

    init(linger: Duration = SubagentCompletionTracker.lingerDuration) {
        self.linger = linger
    }

    /// Records the current statuses and starts a timer for each newly
    /// finished subagent. Call from `.onChange`/`.task` — never from `body`,
    /// which would make the render invalidate itself.
    func observe(_ subagents: [SubagentTranscript], tabID: UUID) {
        let finished = Set(subagents.filter { isFinished($0.status) }.map { Key(tabID: tabID, subagentID: $0.id) })

        for key in finished where completedAt[key] == nil {
            completedAt[key] = .now
            // The timer lives here rather than in the view for the same reason
            // the instants do: a view's `.task` is cancelled on unmount, so a
            // row whose linger elapsed off screen would never move.
            timers[key] = Task { [weak self, linger] in
                try? await Task.sleep(for: linger)
                guard !Task.isCancelled else { return }
                // Republishes so the row moves once its linger elapses; the
                // value it reads is already stored.
                self?.expire(key)
            }
        }

        // A subagent that went back to work earns a fresh linger if it
        // finishes again.
        for key in completedAt.keys where key.tabID == tabID && !finished.contains(key) {
            completedAt.removeValue(forKey: key)
            timers.removeValue(forKey: key)?.cancel()
        }
    }

    /// Whether a finished subagent has lingered long enough to move into the
    /// completed section.
    func hasSettled(_ subagent: SubagentTranscript, tabID: UUID) -> Bool {
        _ = settledGeneration
        let key = Key(tabID: tabID, subagentID: subagent.id)
        guard isFinished(subagent.status), let since = completedAt[key] else { return false }
        return since.duration(to: .now) >= linger
    }

    /// Drops a closed tab's rows, alongside the other per-tab stores a delete
    /// clears.
    func forget(tabID: UUID) {
        for key in completedAt.keys where key.tabID == tabID {
            completedAt.removeValue(forKey: key)
            timers.removeValue(forKey: key)?.cancel()
        }
    }

    private func expire(_ key: Key) {
        timers.removeValue(forKey: key)
        settledGeneration += 1
    }

    private func isFinished(_ status: TaskStatus) -> Bool {
        status == .done || status == .error
    }
}
