import Foundation
import os

nonisolated extension IgnoredChecksResolver {
    /// The full ignore list for the repository containing `repository`.
    /// Blocks on `git` the first time it sees a path, so call this off the
    /// main actor.
    static func resolve(repository: String, configuration: ProjectsConfiguration) -> Set<String> {
        let root = ProjectRootCache.shared.root(containing: repository)
        let settings = root.map(configuration.settings(forRepository:)) ?? configuration.defaults
        return resolve(settings: settings)
    }
}

/// `ProjectRoot.containing` per path, since every PR poll asks again and
/// each lookup runs `git`. Only a found root is kept, so a folder that
/// becomes a repository is found on a later ask.
nonisolated final class ProjectRootCache: Sendable {
    static let shared = ProjectRootCache(lookup: ProjectRoot.containing)

    private let lookup: @Sendable (String) -> String?
    private let roots = OSAllocatedUnfairLock<[String: String]>(initialState: [:])

    init(lookup: @escaping @Sendable (String) -> String?) {
        self.lookup = lookup
    }

    func root(containing path: String) -> String? {
        if let cached = roots.withLock({ $0[path] }) { return cached }
        guard let root = lookup(path) else { return nil }
        roots.withLock { $0[path] = root }
        return root
    }
}
