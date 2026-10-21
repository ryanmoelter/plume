import Foundation
import Observation

/// Remembers when Plume first saw each of a task's Linear issues become
/// mentioned, so it can linger among the working issues before folding into
/// the Mentioned section.
///
/// Follows `SubagentCompletionTracker`: the clock starts from the observation,
/// and an issue already mentioned on a task's first observation folds away at
/// once, so reopening a conversation never floods the list.
@MainActor
@Observable
final class LinearMentionTracker {
    static let shared = LinearMentionTracker()

    nonisolated static let lingerDuration: Duration = .seconds(30)

    private struct Key: Hashable {
        let taskID: UUID
        let identifier: String
    }

    private var mentionedAt: [Key: ContinuousClock.Instant] = [:]
    private var timers: [Key: Task<Void, Never>] = [:]
    private var preMentioned: Set<Key> = []
    private var observedTasks: Set<UUID> = []
    /// Bumped when a linger elapses, so a view reading `hasSettled` re-renders.
    private var settledGeneration = 0
    private let linger: Duration

    init(linger: Duration = LinearMentionTracker.lingerDuration) {
        self.linger = linger
    }

    /// Call from `.onChange`/`.task` — never from `body`.
    func observe(mentioned identifiers: Set<String>, taskID: UUID) {
        let mentioned = Set(identifiers.map { Key(taskID: taskID, identifier: $0) })

        if observedTasks.insert(taskID).inserted {
            preMentioned.formUnion(mentioned)
            return
        }

        for key in mentioned where mentionedAt[key] == nil && !preMentioned.contains(key) {
            mentionedAt[key] = .now
            timers[key] = Task { [weak self, linger] in
                try? await Task.sleep(for: linger)
                guard !Task.isCancelled else { return }
                self?.expire(key)
            }
        }

        for key in mentionedAt.keys where key.taskID == taskID && !mentioned.contains(key) {
            mentionedAt.removeValue(forKey: key)
            timers.removeValue(forKey: key)?.cancel()
        }
        preMentioned.subtract(preMentioned.filter { $0.taskID == taskID && !mentioned.contains($0) })
    }

    /// True for a task not yet observed, so its first render doesn't flash
    /// every old mention among the working issues.
    func hasSettled(_ identifier: String, taskID: UUID) -> Bool {
        _ = settledGeneration
        guard observedTasks.contains(taskID) else { return true }
        let key = Key(taskID: taskID, identifier: identifier)
        if preMentioned.contains(key) { return true }
        guard let since = mentionedAt[key] else { return false }
        return since.duration(to: .now) >= linger
    }

    /// Ends the issue's linger early.
    func settle(_ identifier: String, taskID: UUID) {
        let key = Key(taskID: taskID, identifier: identifier)
        mentionedAt.removeValue(forKey: key)
        timers.removeValue(forKey: key)?.cancel()
        preMentioned.insert(key)
        settledGeneration += 1
    }

    func forget(taskID: UUID) {
        for key in mentionedAt.keys where key.taskID == taskID {
            mentionedAt.removeValue(forKey: key)
            timers.removeValue(forKey: key)?.cancel()
        }
        preMentioned.subtract(preMentioned.filter { $0.taskID == taskID })
        observedTasks.remove(taskID)
    }

    private func expire(_ key: Key) {
        timers.removeValue(forKey: key)
        settledGeneration += 1
    }
}
