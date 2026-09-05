import Foundation
import Observation

/// Remembers when Plume first saw each subagent finish, so a finished row can
/// linger in the live list before folding into the completed section.
///
/// The clock starts from the observation, never from the transcript's mtime:
/// a relaunch re-reads files that finished days ago, and dating them by their
/// own timestamps would collapse every row the instant the list appeared.
/// Nothing here is persisted for the same reason.
@MainActor
@Observable
final class SubagentCompletionTracker {
    /// How long a finished subagent stays among the live rows, long enough to
    /// see it land.
    static let lingerDuration: Duration = .seconds(30)

    private var completedAt: [String: ContinuousClock.Instant] = [:]
    private var timers: [String: Task<Void, Never>] = [:]
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
    func observe(_ subagents: [SubagentTranscript]) {
        let finished = Set(subagents.filter { isFinished($0.status) }.map(\.id))

        for id in finished where completedAt[id] == nil {
            completedAt[id] = .now
            timers[id] = Task { [weak self, linger] in
                try? await Task.sleep(for: linger)
                guard !Task.isCancelled else { return }
                // Republishes so the row moves once its linger elapses; the
                // value it reads is already stored.
                self?.expire(id)
            }
        }

        // A subagent that went back to work earns a fresh linger if it
        // finishes again.
        for id in completedAt.keys where !finished.contains(id) {
            completedAt.removeValue(forKey: id)
            timers.removeValue(forKey: id)?.cancel()
        }
    }

    /// Whether a finished subagent has lingered long enough to move into the
    /// completed section.
    func hasSettled(_ subagent: SubagentTranscript) -> Bool {
        _ = settledGeneration
        guard isFinished(subagent.status), let since = completedAt[subagent.id] else { return false }
        return since.duration(to: .now) >= linger
    }

    private func expire(_ id: String) {
        timers.removeValue(forKey: id)
        settledGeneration += 1
    }

    private func isFinished(_ status: TaskStatus) -> Bool {
        status == .done || status == .error
    }
}
