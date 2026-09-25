import Foundation

/// Resolves the set of CI check names whose perpetual PENDING state should be
/// ignored when folding a PR's check rollup — a real pass/fail from an
/// ignored check still counts, only its "pending" is masked.
///
/// The list is the union of Ryan's existing `wt`/`stack` git config
/// (`wt.ignoredPendingChecks` and the shared
/// `ryanmoelter-cli-tools.ignoredPendingChecks`, both repeatable keys) and a
/// Plume-level setting that applies across every repo. This deliberately
/// departs from the CLIs' own tool-key-wins-outright rule
/// (`config_get_all(tool) or config_get_all(shared)`): a name added in
/// Plume's Settings must never silently discard the repo's list, nor vice
/// versa, so every source is unioned instead.
///
/// Matching against a check's name/context is exact string equality — no
/// substring, no glob, no case folding.
nonisolated enum IgnoredChecksResolver {
    private static let toolKey = "wt.ignoredPendingChecks"
    private static let sharedKey = "ryanmoelter-cli-tools.ignoredPendingChecks"

    /// Pure union of every source. Testable without a real repo or
    /// `UserDefaults`.
    static func union(_ sources: [String]...) -> Set<String> {
        Set(sources.flatMap { $0 })
    }

    /// The full ignore list for a repository: its git config plus the
    /// Plume-level setting. Blocks on `git config`, so call this off the
    /// main actor.
    static func resolve(repository: String, plumeSetting: [String]) -> Set<String> {
        union(gitConfigNames(inRepository: repository), plumeSetting)
    }

    /// Every value of both git config keys, repo then shared, in config
    /// order — not deduplicated here; `union` handles that.
    static func gitConfigNames(inRepository repository: String) -> [String] {
        configGetAll(toolKey, in: repository) + configGetAll(sharedKey, in: repository)
    }

    /// Both keys outside any repository, which is the global and system
    /// config. Blocks on `git config`, so call this off the main actor.
    static func globalGitConfigNames() -> [String] {
        let home = NSHomeDirectory()
        return configGetAll(toolKey, in: home) + configGetAll(sharedKey, in: home)
    }

    private static func configGetAll(_ key: String, in repository: String) -> [String] {
        (try? GitRunner.run(["config", "--get-all", key], in: repository))
            .map { $0.split(separator: "\n").map(String.init) } ?? []
    }
}
