import Foundation

/// Resolves the set of CI check names whose perpetual PENDING state should be
/// ignored when folding a PR's check rollup — a real pass/fail from an
/// ignored check still counts, only its "pending" is masked.
///
/// The list is the union of the project's list from Settings ▸ Projects and
/// the Plume-level list from Settings ▸ Integrations, which applies across
/// every repository. The app and `plume wt` both resolve it here.
///
/// Matching against a check's name/context is exact string equality — no
/// substring, no glob, no case folding.
nonisolated enum IgnoredChecksResolver {
    /// The UserDefaults key, in the app's domain, holding the Settings ▸
    /// Integrations list.
    static let plumeSettingDefaultsKey = "ignoredPendingChecks"

    /// Pure union of every source. Testable without a real repo or
    /// `UserDefaults`.
    static func union(_ sources: [String]...) -> Set<String> {
        Set(sources.flatMap { $0 })
    }

    /// `settings` are the project's, already resolved over the defaults row.
    static func resolve(settings: ProjectSettings, plumeSetting: [String]) -> Set<String> {
        union(settings.ignoredPendingChecks ?? [], plumeSetting)
    }
}
