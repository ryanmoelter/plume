import Foundation

/// The folders tasks have run in, most recent first, so a picker can offer
/// them and a new task can default to the last one.
///
/// A worktree never belongs here. They are often made for one piece of work
/// and removed after, so remembering one fills the list with directories that
/// no longer exist. Callers pass the project it belongs to instead — see
/// `CheckoutFacts.projectRoot`.
enum RecentFolders {
    private static let key = "recentRepositories"
    private static let limit = 8

    /// Where the list is stored. Tests pass a suite of their own: the list is
    /// one key, and a test that wrote the shared defaults would race both the
    /// other tests reading it and the migration the app runs at launch.
    static func load(from defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: key) ?? []
    }

    static func remember(_ path: String, in defaults: UserDefaults = .standard) {
        var paths = load(from: defaults).filter { $0 != path }
        paths.insert(path, at: 0)
        defaults.set(Array(paths.prefix(limit)), forKey: key)
    }

    /// Skips folders that have since been deleted or unmounted, so a stale
    /// entry never becomes a new task's working directory.
    static func mostRecent(in defaults: UserDefaults = .standard) -> String? {
        load(from: defaults).first { FileManager.default.fileExists(atPath: $0) }
    }

    private static let migratedKey = "recentRepositoriesMigratedToProjects"

    /// Runs the migration once per machine. It costs a `git` call per
    /// remembered folder, and the rule it applies is enforced from here on by
    /// `remember` — so a second run has nothing to find.
    static func migrateWorktreesToProjectsOnce(in defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: migratedKey) else { return }
        migrateWorktreesToProjects(in: defaults)
        defaults.set(true, forKey: migratedKey)
    }

    /// Replaces worktrees already in the list with the project they belong to,
    /// for lists written before that was the rule. A worktree `git` no longer
    /// knows is dropped rather than kept under its own name — it is exactly
    /// the ephemeral entry this list should not hold.
    static func migrateWorktreesToProjects(
        in defaults: UserDefaults = .standard,
        projectRoot: (String) -> String? = { GitRunner.checkoutFacts(containing: $0)?.projectRoot }
    ) {
        let stored = load(from: defaults)
        var migrated: [String] = []
        for path in stored {
            guard let root = projectRoot(path) else { continue }
            if !migrated.contains(root) { migrated.append(root) }
        }
        guard migrated != stored else { return }
        defaults.set(Array(migrated.prefix(limit)), forKey: key)
    }
}
