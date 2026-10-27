import Foundation

/// Resolves the set of CI check names whose perpetual PENDING state should be
/// ignored when folding a PR's check rollup — a real pass/fail from an
/// ignored check still counts, only its "pending" is masked.
///
/// The list is the project's from Settings ▸ Projects, which inherits the
/// defaults row's. The app and `plume wt` both resolve it here.
///
/// Matching against a check's name/context is exact string equality — no
/// substring, no glob, no case folding.
nonisolated enum IgnoredChecksResolver {
    /// `settings` are the project's, already resolved over the defaults row.
    static func resolve(settings: ProjectSettings) -> Set<String> {
        Set(settings.ignoredPendingChecks ?? [])
    }
}
