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

    static func load() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func remember(_ path: String) {
        var paths = load().filter { $0 != path }
        paths.insert(path, at: 0)
        UserDefaults.standard.set(Array(paths.prefix(limit)), forKey: key)
    }

    /// Skips folders that have since been deleted or unmounted, so a stale
    /// entry never becomes a new task's working directory.
    static var mostRecent: String? {
        load().first { FileManager.default.fileExists(atPath: $0) }
    }
}
