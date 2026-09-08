import Foundation

/// A pull request's checks folded to one verdict.
nonisolated enum CheckRollup: Sendable, Equatable {
    case success
    case failure
    case pending
    /// No checks are configured at all, which is a different fact from
    /// checks that have not finished.
    case none
}

extension CheckRollup {
    private static let failing: Set<String> = ["FAILURE", "ERROR", "TIMED_OUT", "ACTION_REQUIRED"]
    /// CANCELLED sits here to match GitHub's own PR page: an auto-superseded
    /// duplicate run neither fails nor blocks a merge.
    private static let settled: Set<String> = ["SUCCESS", "NEUTRAL", "SKIPPED", "CANCELLED"]

    /// Folds a rollup, suppressing the pending signal of any check named in
    /// `ignoredWhenPending`.
    ///
    /// The failure scan runs over every context, the pending scan only over
    /// the ones not ignored. That asymmetry is the point: ignoring a check
    /// silences its perpetual pending without hiding a real pass or fail.
    static func folding(
        _ contexts: [CheckContext],
        ignoredWhenPending: Set<String> = []
    ) -> CheckRollup {
        if contexts.isEmpty { return .none }
        if contexts.contains(where: { failing.contains($0.status) }) { return .failure }
        let counted = contexts.filter { !ignoredWhenPending.contains($0.name) }
        if counted.contains(where: { !settled.contains($0.status) }) { return .pending }
        return .success
    }
}

extension PullRequest {
    func checkRollup(ignoredWhenPending: Set<String> = []) -> CheckRollup {
        CheckRollup.folding(checkContexts, ignoredWhenPending: ignoredWhenPending)
    }
}
