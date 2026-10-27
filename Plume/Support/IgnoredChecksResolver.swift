import Foundation

/// Resolves the set of CI check names whose perpetual PENDING state should be
/// ignored when folding a PR's check rollup — a real pass/fail from an
/// ignored check still counts, only its "pending" is masked.
///
/// The list is the union of the project's list from Settings ▸ Projects,
/// resolved the way `plume wt` resolves it, and the Plume-level list from
/// Settings ▸ Integrations, which applies across every repository.
///
/// Matching against a check's name/context is exact string equality — no
/// substring, no glob, no case folding.
nonisolated enum IgnoredChecksResolver {
    /// Pure union of every source. Testable without a real repo or
    /// `UserDefaults`.
    static func union(_ sources: [String]...) -> Set<String> {
        Set(sources.flatMap { $0 })
    }

    /// The full ignore list for the repository containing `repository`.
    /// Blocks on `git` to find the project, so call this off the main actor.
    static func resolve(repository: String, plumeSetting: [String], configuration: ProjectsConfiguration) -> Set<String> {
        let settings = ProjectRoot.containing(repository).map(configuration.settings(forRepository:)) ?? configuration.defaults
        return union(settings.ignoredPendingChecks ?? [], plumeSetting)
    }
}
